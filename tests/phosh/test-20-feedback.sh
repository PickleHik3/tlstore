#!/bin/bash
# tl-feedbackd (#13): it owns org.sigxcpu.Feedback; a button-pressed event is a POST /v1/vibrate
# at the fake; the "silent" profile suppresses it; a profile hint overrides the global profile.
# (feedbackd's "quiet" profile is haptics only, so it still vibrates; "silent" is LEDs only.)
set -euo pipefail
# shellcheck source=./lib.sh
. "$TL_SCRIPT_DIR/lib.sh"

fb() { # fb <method> <args...>: a call on the Feedback object
    local m="$1"
    shift
    gdbus call --session --dest org.sigxcpu.Feedback --object-path /org/sigxcpu/Feedback \
        --method "$m" -- "$@"
}
vibrates() { fake_call_count POST /v1/vibrate; }
vibrates_is() { [ "$(vibrates)" = "$1" ]; }

wait_for 20 "tl-feedbackd owns org.sigxcpu.Feedback" on_bus org.sigxcpu.Feedback

fb org.freedesktop.DBus.Properties.Get org.sigxcpu.Feedback Profile | grep -q "'full'" ||
    die "the Profile property is not full"
pass "Profile is full"

# A touch in a GTK app: button-pressed.
fake_reset
fb org.sigxcpu.Feedback.TriggerFeedback test.app button-pressed '{}' -1 | grep -q '^(uint32 [0-9]*,)$' ||
    die "TriggerFeedback did not return an id"
wait_for 5 "button-pressed is a POST /v1/vibrate" vibrates_is 1
if bad=$(fake_unexpected); then pass "the vibrate call was accepted"; else die "unexpected calls: $bad"; fi
fake_calls | python3 -I -c '
import json, sys
c = [c for c in json.load(sys.stdin) if c["path"] == "/v1/vibrate"][0]
sys.exit(0 if c["body"] == {"duration_ms": 10} else 1)' || die "the vibrate body is not {duration_ms: 10}"
pass "button-pressed vibrates 10 ms"

# A notification pattern: three calls for the email event (750 ms x 3, 100 ms apart).
fake_reset
fb org.sigxcpu.Feedback.TriggerFeedback test.app message-new-email '{}' -1 >/dev/null
wait_for 5 "message-new-email is three vibrate calls" vibrates_is 3

# An event the theme does not know ends without a call.
fake_reset
fb org.sigxcpu.Feedback.TriggerFeedback test.app no-such-event '{}' -1 >/dev/null
sleep 0.5
vibrates_is 0 || die "an unknown event vibrated"
pass "an unknown event does not vibrate"

# Silent: no haptics.
fb org.freedesktop.DBus.Properties.Set org.sigxcpu.Feedback Profile "<'silent'>" >/dev/null
fb org.freedesktop.DBus.Properties.Get org.sigxcpu.Feedback Profile | grep -q "'silent'" ||
    die "Profile did not become silent"
fake_reset
fb org.sigxcpu.Feedback.TriggerFeedback test.app button-pressed '{}' -1 >/dev/null
sleep 1
vibrates_is 0 || die "silent profile vibrated"
pass "profile silent: no vibrate call"

# The profile hint wins for one event.
fb org.sigxcpu.Feedback.TriggerFeedback test.app button-pressed "{'profile': <'full'>}" -1 >/dev/null
wait_for 5 "a profile=full hint vibrates under silent" vibrates_is 1

fb org.freedesktop.DBus.Properties.Set org.sigxcpu.Feedback Profile "<'full'>" >/dev/null
if bad=$(fake_unexpected); then pass "the fake received no unexpected call"; else die "unexpected calls: $bad"; fi
