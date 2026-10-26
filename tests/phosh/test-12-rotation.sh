#!/bin/bash
# Rotation (docs/PHOSH.md, "Bridges"): the rotation manager shows the stream's rotation events
# (orientation, lock), and the rotation-lock quick setting sets Android's lock with
# POST /v1/rotation. State comes from mobi.phosh.Shell.DebugControl TlState (lib.sh tl_get):
# rotation.* is the manager's. Android turns the display, so phosh applies no transform.
set -euo pipefail
# shellcheck source=tests/phosh/lib.sh
# shellcheck source=./lib.sh
. "$TL_SCRIPT_DIR/lib.sh"

wait_for 60 "phosh owns org.gnome.Shell on the session bus" on_bus org.gnome.Shell
wait_for 30 "phosh exports mobi.phosh.Shell.DebugControl" on_bus mobi.phosh.Shell.DebugControl

# Start from a known state, whatever the fake held before: portrait, not locked.
fake_push rotation '{"ok":true,"orientation":"portrait","rotation":0,"lock":false}'
wait_for 30 "the rotation manager is in sensor mode" tl_is rotation.mode sensor
wait_for 10 "the orientation is portrait" tl_is rotation.orientation portrait
wait_for 10 "the rotation is not locked" tl_is rotation.locked false

# Android turns the phone.
fake_push rotation '{"ok":true,"orientation":"landscape","rotation":1,"lock":false}'
wait_for 10 "the orientation follows a pushed event (landscape)" tl_is rotation.orientation landscape

# A tap on the rotation-lock quick setting sets Android's lock, and the manager shows what
# Android answers.
fake_reset
tl_tile rotation click
wait_for 10 "the tap posts /v1/rotation lock true" fake_body_is POST /v1/rotation '{"lock":true}'
wait_for 10 "the rotation is locked" tl_is rotation.locked true

tl_tile rotation click
wait_for 10 "the second tap posts /v1/rotation lock false" fake_body_is POST /v1/rotation '{"lock":false}'
wait_for 10 "the rotation is unlocked" tl_is rotation.locked false
n=$(fake_call_count POST /v1/rotation)
[ "$n" = 2 ] || die "/v1/rotation was posted $n times, wanted 2"

# The lock changed in Android's own quick settings.
fake_push rotation '{"ok":true,"orientation":"landscape","rotation":1,"lock":true}'
wait_for 10 "the lock follows Android" tl_is rotation.locked true

n=$(fake_call_count GET /v1/rotation)
[ "$n" = 0 ] || die "phosh polled GET /v1/rotation ($n times)"

if bad=$(fake_unexpected); then
    pass "the fake received no unexpected call"
else
    die "unexpected calls at the fake: $bad"
fi
