#!/bin/bash
# Notifications (docs/PHOSH.md, "Bridges"): phosh stays the notification server; each notification
# it receives is also posted with POST /v1/notify ("phosh-<id>", open-display), and closing it in
# phosh (CloseNotification, expiry of a transient one) withdraws it with {"close": "phosh-<id>"}.
set -euo pipefail
# shellcheck source=tests/phosh/lib.sh
# shellcheck source=./lib.sh
. "$TL_SCRIPT_DIR/lib.sh"

wait_for 60 "phosh owns org.gnome.Shell on the session bus" on_bus org.gnome.Shell
wait_for 30 "phosh owns org.freedesktop.Notifications" on_bus org.freedesktop.Notifications
wait_for 30 "the launcher watch stream is open" watcher_open

# A notification, then CloseNotification by the app.
fake_reset
id=$(notify_send "Build" "42 tests passed" 0 "{}")
[ -n "$id" ] || die "Notify returned no id"
pass "Notify answered id $id"
wait_for 10 "the notification is posted with its title, body, id and open-display" \
    fake_has_body POST /v1/notify \
    "{\"id\":\"phosh-$id\",\"title\":\"Build\",\"body\":\"42 tests passed\",\"urgency\":\"normal\",\"action\":\"open-display\"}"

gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
    --method org.freedesktop.Notifications.CloseNotification "$id" >/dev/null
wait_for 10 "closing it in phosh withdraws it by id" fake_has_body POST /v1/notify "{\"close\":\"phosh-$id\"}"

# A critical one with markup in the body; the Android text is plain.
fake_reset
cid=$(notify_send "Disk" "<b>full</b> &amp; sad" 0 "{'urgency': <byte 2>}")
[ "$cid" != "$id" ] || die "two notifications got the id $id"
wait_for 10 "a critical notification is posted, markup stripped" \
    fake_has_body POST /v1/notify \
    "{\"id\":\"phosh-$cid\",\"title\":\"Disk\",\"body\":\"full & sad\",\"urgency\":\"critical\",\"action\":\"open-display\"}"

# A transient one that expires: phosh closes it, so the Android one goes too.
fake_reset
eid=$(notify_send "Tick" "gone soon" 1500 "{'transient': <true>}")
wait_for 10 "the transient notification is posted" fake_has_body POST /v1/notify \
    "{\"id\":\"phosh-$eid\",\"title\":\"Tick\",\"body\":\"gone soon\",\"urgency\":\"normal\",\"action\":\"open-display\"}"
wait_for 15 "its expiry withdraws it by id" fake_has_body POST /v1/notify "{\"close\":\"phosh-$eid\"}"

if bad=$(fake_unexpected); then
    pass "the fake received no unexpected call"
else
    die "unexpected calls at the fake: $bad"
fi
