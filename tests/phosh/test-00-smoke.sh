#!/bin/bash
# The smoke test: phosh starts unlocked against the fake and stays up; its D-Bus name is on the
# session bus; the fake saw nothing unexpected. Top-bar state comes with the bridge tests.
# (There is no lock screen in this build, -Dlockscreen=false, so "unlocked" is the only state.)
set -euo pipefail
# shellcheck source=tests/phosh/lib.sh
# shellcheck source=./lib.sh
. "$TL_SCRIPT_DIR/lib.sh"

settle=${TL_HEADLESS_SECONDS:-10}

wait_for 60 "phosh owns sm.puri.Phosh on the session bus" on_bus sm.puri.Phosh
pid=$(phosh_pid) || die "phosh is not a child of phoc"
pass "phosh is running (pid $pid)"

sleep "$settle"
kill -0 "$PHOC_PID" 2>/dev/null || die "phoc died within ${settle}s"
kill -0 "$pid" 2>/dev/null || die "phosh died within ${settle}s"
on_bus sm.puri.Phosh || die "sm.puri.Phosh left the bus"
pass "phoc and phosh alive after ${settle}s"

if bad=$(fake_unexpected); then
    pass "the fake received no unexpected call"
else
    die "unexpected calls at the fake: $bad"
fi
