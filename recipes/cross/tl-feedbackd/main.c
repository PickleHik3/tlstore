/* tl-feedbackd - owns org.sigxcpu.Feedback on the session bus and turns feedback events into
 * launcherctl vibrate calls (docs/PHOSH.md, "Bridges"; issue #13). It answers what libfeedback
 * 0.8.1 asks of feedbackd, so phosh, phosh-mobile-settings and GTK apps need no change:
 *
 *   org.sigxcpu.Feedback         property Profile (rw: full, quiet, silent), TriggerFeedback,
 *                                EndFeedback, signal FeedbackEnded
 *   org.sigxcpu.Feedback.Haptic  Vibrate(app_id, a(du))
 *
 * Both on /org/sigxcpu/Feedback, as feedbackd has them. There is no sound and no LED here, so
 * "full" and "quiet" both mean haptics and "silent" means none. Without launcherctl (no
 * ~/.launcherctl/endpoint, or it does not answer) events still run their course and end; the
 * first failure is logged, once per kind. Nothing polls: steps are timers, calls are async.
 *
 * Only GLib and GIO. The HTTP call is a hand-written POST on a GSocketClient connection to the
 * endpoint in ~/.launcherctl/endpoint with the bearer token in ~/.launcherctl/token, read again
 * for every call so a restarted launcher (new port, new token) is picked up. */
#include <gio/gio.h>
#include <glib-unix.h>
#include <string.h>
#include "feedback-theme.h"

#define BUS_NAME "org.sigxcpu.Feedback"
#define OBJ_PATH "/org/sigxcpu/Feedback"
#define IFACE "org.sigxcpu.Feedback"
#define IFACE_HAPTIC "org.sigxcpu.Feedback.Haptic"
#define MAX_STEPS 16

/* The interfaces as in subprojects/feedbackd/data/org.sigxcpu.Feedback{,.Haptic}.xml (0.8.1),
 * without the documentation comments. */
static const char introspection_xml[] =
  "<node>"
  "  <interface name='" IFACE "'>"
  "    <property name='Profile' type='s' access='readwrite'/>"
  "    <method name='TriggerFeedback'>"
  "      <arg direction='in' name='app_id' type='s'/>"
  "      <arg direction='in' name='event' type='s'/>"
  "      <arg direction='in' name='hints' type='a{sv}'/>"
  "      <arg direction='in' name='timeout' type='i'/>"
  "      <arg direction='out' name='id' type='u'/>"
  "    </method>"
  "    <method name='EndFeedback'>"
  "      <arg direction='in' name='id' type='u'/>"
  "    </method>"
  "    <signal name='FeedbackEnded'>"
  "      <arg name='id' type='u'/>"
  "      <arg name='reason' type='u'/>"
  "    </signal>"
  "  </interface>"
  "  <interface name='" IFACE_HAPTIC "'>"
  "    <method name='Vibrate'>"
  "      <arg direction='in' name='app_id' type='s'/>"
  "      <arg direction='in' name='pattern' type='a(du)'/>"
  "      <arg direction='out' name='success' type='b'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GMainLoop *loop;
static GDBusConnection *bus;
static GHashTable *events;      /* guint id -> Event */
static guint next_id = 1;
static char *profile;

/* --- launcherctl ----------------------------------------------------------------------------- */

/* launcherctl allows 30 vibrate calls a minute. A bucket of 28 keeps below it; the tiny taps
 * (button feedback, under 30 ms) are only sent while 10 tokens are left, so a burst of taps never
 * starves a notification pattern. */
#define BUCKET_MAX 28.0
#define BUCKET_PER_SEC (28.0 / 60.0)
#define TAP_MS 30
#define TAP_RESERVE 10.0

static double tokens = BUCKET_MAX;
static gint64 tokens_at;

static gboolean
take_token (int ms)
{
  gint64 now = g_get_monotonic_time ();

  if (tokens_at)
    tokens = MIN (BUCKET_MAX, tokens + (now - tokens_at) / 1e6 * BUCKET_PER_SEC);
  tokens_at = now;
  if (tokens < (ms < TAP_MS ? TAP_RESERVE : 1.0))
    return FALSE;
  tokens -= 1.0;
  return TRUE;
}

static void
log_once (const char *kind, const char *msg)
{
  static GHashTable *seen;

  if (!seen)
    seen = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
  if (g_hash_table_contains (seen, kind))
    return;
  g_hash_table_add (seen, g_strdup (kind));
  g_message ("%s (not logged again)", msg);
}

typedef struct {
  GSocketConnection *conn;
  char *request;
} Post;

static void
post_done (Post *p)
{
  if (p->conn) {
    g_io_stream_close_async (G_IO_STREAM (p->conn), G_PRIORITY_DEFAULT, NULL, NULL, NULL);
    g_object_unref (p->conn);
  }
  g_free (p->request);
  g_free (p);
}

static void
on_response (GObject *src, GAsyncResult *res, gpointer data)
{
  Post *p = data;
  GBytes *bytes = g_input_stream_read_bytes_finish (G_INPUT_STREAM (src), res, NULL);

  if (bytes) {
    gsize len;
    const char *buf = g_bytes_get_data (bytes, &len);
    /* "HTTP/1.1 200 OK" */
    if (len >= 12 && memcmp (buf, "HTTP/1.", 7) == 0 && memcmp (buf + 9, "200", 3) != 0) {
      char *code = g_strndup (buf + 9, 3), *msg = g_strdup_printf ("launcherctl answered %s to vibrate", code);
      log_once (code, msg);
      g_free (msg);
      g_free (code);
    }
    g_bytes_unref (bytes);
  }
  post_done (p);
}

static void
on_written (GObject *src, GAsyncResult *res, gpointer data)
{
  Post *p = data;
  GError *err = NULL;

  if (!g_output_stream_write_all_finish (G_OUTPUT_STREAM (src), res, NULL, &err)) {
    log_once ("write", "writing to launcherctl failed");
    g_clear_error (&err);
    post_done (p);
    return;
  }
  g_input_stream_read_bytes_async (g_io_stream_get_input_stream (G_IO_STREAM (p->conn)), 256,
                                   G_PRIORITY_DEFAULT, NULL, on_response, p);
}

static void
on_connected (GObject *src, GAsyncResult *res, gpointer data)
{
  Post *p = data;
  GError *err = NULL;

  p->conn = g_socket_client_connect_to_host_finish (G_SOCKET_CLIENT (src), res, &err);
  g_object_unref (src);
  if (!p->conn) {
    log_once ("connect", "launcherctl is not answering; haptics are off until it does");
    g_clear_error (&err);
    post_done (p);
    return;
  }
  g_output_stream_write_all_async (g_io_stream_get_output_stream (G_IO_STREAM (p->conn)),
                                   p->request, strlen (p->request), G_PRIORITY_DEFAULT, NULL,
                                   on_written, p);
}

static char *
read_launcherctl_file (const char *name)
{
  char *path = g_build_filename (g_get_home_dir (), ".launcherctl", name, NULL);
  char *text = NULL;

  if (g_file_get_contents (path, &text, NULL, NULL))
    g_strstrip (text);
  g_free (path);
  return text;
}

/* POST /v1/vibrate {"duration_ms": ms}; the answer is read only for its status line. */
static void
post_vibrate (int ms)
{
  char *endpoint = read_launcherctl_file ("endpoint");
  char *token = read_launcherctl_file ("token");
  GUri *uri = endpoint ? g_uri_parse (endpoint, G_URI_FLAGS_NONE, NULL) : NULL;

  if (!uri || !token || !g_uri_get_host (uri) || g_uri_get_port (uri) <= 0) {
    log_once ("no-launcherctl", "no launcherctl endpoint in ~/.launcherctl; events end without haptics");
  } else if (take_token (ms)) {
    Post *p = g_new0 (Post, 1);
    GSocketClient *client = g_socket_client_new ();
    char *hostport = g_strdup_printf ("%s:%d", g_uri_get_host (uri), g_uri_get_port (uri));
    char *body = g_strdup_printf ("{\"duration_ms\":%d}", ms);

    p->request = g_strdup_printf ("POST /v1/vibrate HTTP/1.1\r\nHost: %s\r\n"
                                  "Authorization: Bearer %s\r\nContent-Type: application/json\r\n"
                                  "Content-Length: %zu\r\nConnection: close\r\n\r\n%s",
                                  hostport, token, strlen (body), body);
    g_socket_client_set_timeout (client, 3);
    g_socket_client_connect_to_host_async (client, hostport, 0, NULL, on_connected, p);
    g_free (body);
    g_free (hostport);
  }
  g_clear_pointer (&uri, g_uri_unref);
  g_free (endpoint);
  g_free (token);
}

/* --- events ---------------------------------------------------------------------------------- */

typedef struct {
  guint id;
  int steps[MAX_STEPS + 1];     /* 0 ends the list */
  int idx;
  gboolean loop;
  gboolean signal_end;          /* Haptic.Vibrate has no id the caller knows */
  guint step_source;
  guint timeout_source;
} Event;

static void
emit_ended (guint id)
{
  g_dbus_connection_emit_signal (bus, NULL, OBJ_PATH, IFACE, "FeedbackEnded",
                                 g_variant_new ("(uu)", id, 0u), NULL);
}

static void
event_free (Event *ev)
{
  g_clear_handle_id (&ev->step_source, g_source_remove);
  g_clear_handle_id (&ev->timeout_source, g_source_remove);
  g_free (ev);
}

static void
event_end (Event *ev)
{
  guint id = ev->id;
  gboolean sig = ev->signal_end;

  g_hash_table_steal (events, GUINT_TO_POINTER (id));
  event_free (ev);
  if (sig)
    emit_ended (id);
}

static void event_advance (Event *ev);

static gboolean
on_step_timer (gpointer data)
{
  Event *ev = data;

  ev->step_source = 0;
  event_advance (ev);
  return G_SOURCE_REMOVE;
}

/* Run the step at idx: a vibrate call for a positive one, then wait that long (the motor runs
 * for it) or the pause before the next. At the end of the list the event ends, or starts over
 * when it loops. */
static void
event_advance (Event *ev)
{
  int step = ev->steps[ev->idx];

  if (step == 0) {
    if (!ev->loop || ev->steps[0] == 0) {
      event_end (ev);
      return;
    }
    ev->idx = 0;
    step = ev->steps[0];
  }
  if (step > 0)
    post_vibrate (step);
  ev->idx++;
  ev->step_source = g_timeout_add (step > 0 ? step : -step, on_step_timer, ev);
}

static gboolean
on_event_timeout (gpointer data)
{
  Event *ev = data;

  ev->timeout_source = 0;
  event_end (ev);
  return G_SOURCE_REMOVE;
}

static gboolean
end_later (gpointer data)
{
  emit_ended (GPOINTER_TO_UINT (data));
  return G_SOURCE_REMOVE;
}

/* Start an event: a new id, its steps (NULL or empty: nothing to do, it ends at once) and, for a
 * looping one, its timeout in seconds (0: until EndFeedback; negative: once through). */
static guint
event_start (const int *steps, int nsteps, gboolean loop_it, int timeout, gboolean signal_end)
{
  guint id = next_id++;
  Event *ev;

  if (next_id == 0)
    next_id = 1;
  if (!steps || nsteps <= 0) {
    if (signal_end)
      g_idle_add (end_later, GUINT_TO_POINTER (id));
    return id;
  }
  ev = g_new0 (Event, 1);
  ev->id = id;
  ev->signal_end = signal_end;
  memcpy (ev->steps, steps, MIN (nsteps, MAX_STEPS) * sizeof (int));
  ev->loop = loop_it && timeout >= 0;
  g_hash_table_insert (events, GUINT_TO_POINTER (id), ev);
  if (ev->loop && timeout > 0)
    ev->timeout_source = g_timeout_add_seconds (timeout, on_event_timeout, ev);
  event_advance (ev);
  return id;
}

/* --- D-Bus ----------------------------------------------------------------------------------- */

static void
trigger_feedback (GVariant *params, GDBusMethodInvocation *inv)
{
  const char *app_id, *event;
  GVariant *hints;
  gint32 timeout;
  const char *use = profile, *hint_profile = NULL;
  const TlTheme *entry;
  guint id;

  g_variant_get (params, "(&s&s@a{sv}i)", &app_id, &event, &hints, &timeout);
  if (g_variant_lookup (hints, "profile", "&s", &hint_profile) && tl_profile_valid (hint_profile))
    use = hint_profile;
  entry = tl_profile_has_haptics (use) ? tl_theme_lookup (event) : NULL;
  id = event_start (entry ? entry->steps : NULL, entry ? (int) G_N_ELEMENTS (entry->steps) : 0, entry && entry->loop,
                    timeout, TRUE);
  g_variant_unref (hints);
  g_dbus_method_invocation_return_value (inv, g_variant_new ("(u)", id));
}

static void
vibrate (GVariant *params, GDBusMethodInvocation *inv)
{
  const char *app_id;
  GVariantIter *iter;
  double amp, dur;
  int steps[MAX_STEPS + 1] = { 0 }, n = 0;

  g_variant_get (params, "(&sa(du))", &app_id, &iter);
  /* A zero amplitude is a pause; the route takes a duration only, so any other is a vibration. */
  while (n < MAX_STEPS && g_variant_iter_next (iter, "(du)", &amp, &dur)) {
    int ms = (int) CLAMP (dur, 0, 10000);

    if (ms > 0)
      steps[n++] = amp > 0.0 ? ms : -ms;
  }
  g_variant_iter_free (iter);
  event_start (steps, n, FALSE, -1, FALSE);
  g_dbus_method_invocation_return_value (inv, g_variant_new ("(b)", TRUE));
}

static void
on_method_call (GDBusConnection *c, const char *sender, const char *path, const char *iface,
                const char *method, GVariant *params, GDBusMethodInvocation *inv, gpointer data)
{
  if (!strcmp (method, "TriggerFeedback")) {
    trigger_feedback (params, inv);
  } else if (!strcmp (method, "EndFeedback")) {
    guint id;
    Event *ev;

    g_variant_get (params, "(u)", &id);
    ev = g_hash_table_lookup (events, GUINT_TO_POINTER (id));
    if (ev)
      event_end (ev);
    g_dbus_method_invocation_return_value (inv, NULL);
  } else if (!strcmp (method, "Vibrate")) {
    vibrate (params, inv);
  } else {
    g_dbus_method_invocation_return_error (inv, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
                                           "no method %s", method);
  }
}

static GVariant *
on_get_property (GDBusConnection *c, const char *sender, const char *path, const char *iface,
                 const char *prop, GError **error, gpointer data)
{
  return g_variant_new_string (profile);
}

static gboolean
on_set_property (GDBusConnection *c, const char *sender, const char *path, const char *iface,
                 const char *prop, GVariant *value, GError **error, gpointer data)
{
  const char *name = g_variant_get_string (value, NULL);
  GVariantBuilder changed;

  if (!tl_profile_valid (name)) {
    g_set_error (error, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS, "unknown profile %s", name);
    return FALSE;
  }
  if (strcmp (name, profile) == 0)
    return TRUE;
  g_free (profile);
  profile = g_strdup (name);
  g_variant_builder_init (&changed, G_VARIANT_TYPE ("a{sv}"));
  g_variant_builder_add (&changed, "{sv}", "Profile", g_variant_new_string (profile));
  g_dbus_connection_emit_signal (c, NULL, OBJ_PATH, "org.freedesktop.DBus.Properties",
                                 "PropertiesChanged",
                                 g_variant_new ("(sa{sv}as)", IFACE, &changed, NULL), NULL);
  return TRUE;
}

static const GDBusInterfaceVTable vtable = { on_method_call, on_get_property, on_set_property };

static void
on_bus_acquired (GDBusConnection *c, const char *name, gpointer data)
{
  GDBusNodeInfo *info = g_dbus_node_info_new_for_xml (introspection_xml, NULL);
  GError *err = NULL;

  bus = g_object_ref (c);
  for (int i = 0; info->interfaces[i]; i++) {
    if (!g_dbus_connection_register_object (c, OBJ_PATH, info->interfaces[i], &vtable, NULL, NULL,
                                            &err)) {
      g_printerr ("tl-feedbackd: cannot register %s: %s\n", info->interfaces[i]->name, err->message);
      exit (1);
    }
  }
  g_dbus_node_info_unref (info);
}

static void
on_name_lost (GDBusConnection *c, const char *name, gpointer data)
{
  /* Another feedbackd owns the name, or the bus went away: nothing left to do. */
  g_message ("lost %s, exiting", name);
  g_main_loop_quit (loop);
}

static gboolean
on_signal (gpointer data)
{
  g_main_loop_quit (loop);
  return G_SOURCE_REMOVE;
}

int
main (void)
{
  loop = g_main_loop_new (NULL, FALSE);
  events = g_hash_table_new (g_direct_hash, g_direct_equal);
  profile = g_strdup ("full");
  g_unix_signal_add (SIGTERM, on_signal, NULL);
  g_unix_signal_add (SIGINT, on_signal, NULL);
  g_bus_own_name (G_BUS_TYPE_SESSION, BUS_NAME, G_BUS_NAME_OWNER_FLAGS_NONE, on_bus_acquired, NULL,
                  on_name_lost, NULL, NULL);
  g_main_loop_run (loop);
  return 0;
}
