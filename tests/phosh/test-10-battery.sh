#!/bin/bash
# Battery (docs/PHOSH.md, "Bridges"): the battery manager takes its state from the watch stream
# only, the top bar's battery indicator and the battery quick setting are bound to it, and the
# quick setting's long-press opens Android's battery settings. State is read through
# mobi.phosh.Shell.DebugControl TlState (lib.sh tl_get): battery.* is what the manager says, the
# tiles.battery.* what the quick setting shows.
set -euo pipefail
# shellcheck source=tests/phosh/lib.sh
# shellcheck source=./lib.sh
. "$TL_SCRIPT_DIR/lib.sh"

wait_for 60 "phosh owns org.gnome.Shell on the session bus" on_bus org.gnome.Shell
wait_for 30 "phosh exports mobi.phosh.Shell.DebugControl" on_bus mobi.phosh.Shell.DebugControl

# The stream opens with the state of every topic: 87%, discharging.
wait_for 30 "phosh shows the opening battery state (87%)" tl_is battery.percent 87
wait_for 10 "the battery icon is the 80% one" tl_is battery.icon battery-level-80-symbolic
wait_for 10 "the battery quick setting is sensitive" tl_is tiles.battery.sensitive true

# Nothing polls: one stream, and no GET of the routes it carries. (Before any fake_reset.)
for topic in battery network rotation; do
    n=$(fake_call_count GET "/v1/$topic")
    [ "$n" = 0 ] || die "phosh polled GET /v1/$topic ($n times)"
done
n=$(fake_call_count GET /v1/watch)
[ "$n" = 1 ] || die "phosh opened the watch stream $n times, wanted 1"
pass "one watch stream, no GET of battery, network or rotation"

fake_push battery '{"health":"GOOD","percentage":9,"plugged":"AC","status":"CHARGING","temperature":30.5,"current":500000}'
wait_for 10 "the top bar follows a pushed event (9%)" tl_is battery.percent 9
wait_for 10 "the icon is the charging one" tl_is battery.icon battery-level-0-charging-symbolic

fake_push battery '{"health":"GOOD","percentage":100,"plugged":"AC","status":"FULL","temperature":30.5,"current":0}'
wait_for 10 "full is 100%" tl_is battery.percent 100
wait_for 10 "the icon is the charged one" tl_is battery.icon battery-level-100-charged-symbolic

# Long-press: Android's battery page, through POST /v1/settings/open.
fake_reset
tl_tile battery long-press
wait_for 10 "the battery long-press posts /v1/settings/open battery" \
    fake_body_is POST /v1/settings/open '{"page":"battery"}'
n=$(fake_call_count POST /v1/settings/open)
[ "$n" = 1 ] || die "settings/open was posted $n times, wanted 1"

if bad=$(fake_unexpected); then
    pass "the fake received no unexpected call"
else
    die "unexpected calls at the fake: $bad"
fi
