#!/bin/bash
# Torch (docs/PHOSH.md, "Bridges"): the torch quick setting switches the torch through
# POST /v1/torch. The launcher reports no torch state on the stream, so the manager shows what
# the launcher answered to the last switch. State comes from mobi.phosh.Shell.DebugControl
# TlState (lib.sh tl_get): torch.* is the manager's, tiles.torch.* the quick setting's.
set -euo pipefail
# shellcheck source=tests/phosh/lib.sh
# shellcheck source=./lib.sh
. "$TL_SCRIPT_DIR/lib.sh"

wait_for 60 "phosh owns org.gnome.Shell on the session bus" on_bus org.gnome.Shell
wait_for 30 "phosh exports mobi.phosh.Shell.DebugControl" on_bus mobi.phosh.Shell.DebugControl

wait_for 30 "a torch is present while the launcher is there" tl_is torch.present true
wait_for 10 "the torch quick setting is visible" tl_is tiles.torch.visible true
tl_is torch.enabled false || die "the torch is not off at the start"

fake_reset
tl_tile torch click
wait_for 10 "the tap posts /v1/torch on" fake_body_is POST /v1/torch '{"on":true}'
wait_for 10 "the torch is on" tl_is torch.enabled true
wait_for 10 "the torch quick setting is active" tl_is tiles.torch.active true

tl_tile torch click
wait_for 10 "the second tap posts /v1/torch off" fake_body_is POST /v1/torch '{"on":false}'
wait_for 10 "the torch is off" tl_is torch.enabled false
n=$(fake_call_count POST /v1/torch)
[ "$n" = 2 ] || die "/v1/torch was posted $n times, wanted 2; the calls, in order:
$(fake_calls_for POST /v1/torch)"

if bad=$(fake_unexpected); then
    pass "the fake received no unexpected call"
else
    die "unexpected calls at the fake: $bad"
fi
