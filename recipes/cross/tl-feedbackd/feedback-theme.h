/* feedback-theme.h - the haptic theme: feedbackd event name -> vibration steps. */
#pragma once
#include <glib.h>

/* A theme entry: steps in milliseconds, positive = vibrate, negative = pause, 0 ends the list.
 * `loop`: repeated until the event is ended or its timeout passes (feedbackd's VibraPeriodic). */
typedef struct {
  const char *event;
  int steps[8];
  gboolean loop;
} TlTheme;

/* The entry for an event name (exact, then notification-new-* falls back to
 * notification-new-generic), or NULL: the event has no haptic feedback. */
const TlTheme *tl_theme_lookup (const char *event);

/* The profiles feedbackd knows. Haptics are in "full" and "quiet", not in "silent". */
gboolean tl_profile_valid (const char *profile);
gboolean tl_profile_has_haptics (const char *profile);
