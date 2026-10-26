/* feedback-theme.c - the table is the "quiet" (haptics only) profile of feedbackd's default theme
 * (subprojects/feedbackd/data/default.json, libfeedback 0.8.1), with each VibraRumble/Pattern/
 * Periodic turned into steps. launcherctl's POST /v1/vibrate takes one duration (no amplitude), so
 * magnitudes are dropped and a multi-pulse event is several calls, spaced by its pauses. The
 * button-pressed 7 ms is raised to 10 ms: Android's vibrator does little below that. */
#include "feedback-theme.h"
#include <string.h>

static const TlTheme theme[] = {
  { "alarm-clock-elapsed",         { 1000, -1000 }, TRUE },
  { "bell-terminal",               { 100 }, FALSE },
  { "button-pressed",              { 10 }, FALSE },
  { "button-released",             { 12 }, FALSE },
  { "message-new-cellbroadcast",   { 200 }, FALSE },
  { "message-new-email",           { 750, -100, 750, -100, 750 }, FALSE },
  { "message-new-instant",         { 150 }, FALSE },
  { "message-new-sms",             { 500, -100, 500 }, FALSE },
  { "message-sent-instant",        { 150 }, FALSE },
  { "notification-new-generic",    { 50, -250, 50 }, FALSE },
  { "phone-incoming-call",         { 1000, -1000 }, TRUE },
  { "theme-demo",                  { 1000, -1000 }, TRUE },
  { "timeout-completed",           { 100 }, FALSE },
  { "window-close",                { 25 }, FALSE },
};

const TlTheme *
tl_theme_lookup (const char *event)
{
  if (!event)
    return NULL;
  for (gsize i = 0; i < G_N_ELEMENTS (theme); i++) {
    if (strcmp (theme[i].event, event) == 0)
      return &theme[i];
  }
  if (g_str_has_prefix (event, "notification-new-"))
    return tl_theme_lookup ("notification-new-generic");
  return NULL;
}

gboolean
tl_profile_valid (const char *profile)
{
  return profile && (!strcmp (profile, "full") || !strcmp (profile, "quiet") ||
                     !strcmp (profile, "silent"));
}

gboolean
tl_profile_has_haptics (const char *profile)
{
  return profile && (!strcmp (profile, "full") || !strcmp (profile, "quiet"));
}
