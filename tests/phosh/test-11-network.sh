#!/bin/bash
# Network (docs/PHOSH.md, "Bridges"): the Wi-Fi and mobile managers show the stream's network
# events and nothing more (read-only), their quick settings are bound to them, and the long-press
# of each opens Android's Wi-Fi or mobile-network settings. State comes from mobi.phosh.Shell.
# DebugControl TlState (lib.sh tl_get): wifi.* and wwan.* are the managers', tiles.* the quick settings'.
set -euo pipefail
# shellcheck source=tests/phosh/lib.sh
# shellcheck source=./lib.sh
. "$TL_SCRIPT_DIR/lib.sh"

wait_for 60 "phosh owns org.gnome.Shell on the session bus" on_bus org.gnome.Shell
wait_for 30 "phosh exports mobi.phosh.Shell.DebugControl" on_bus mobi.phosh.Shell.DebugControl

# The opening state: Wi-Fi "Home" at level 3, LTE at level 4 with mobile data on.
wait_for 30 "Wi-Fi is connected to Home" tl_is wifi.ssid Home
wait_for 10 "Wi-Fi at level 3 is the good icon" tl_is wifi.icon network-wireless-signal-good-symbolic
wait_for 10 "the Wi-Fi quick setting is sensitive" tl_is tiles.wifi.sensitive true
wait_for 10 "the modem is present, LTE is 4G" tl_is wwan.tec 4G
wait_for 10 "level 4 is full signal" tl_is wwan.signal 100
wait_for 10 "mobile data is on" tl_is wwan.data true
wait_for 10 "the mobile quick setting is sensitive" tl_is tiles.wwan.sensitive true

# Wi-Fi switched off in Android.
fake_push network '{"ok":true,"wifi":{"enabled":false,"connected":false,"ssid":"","signal_level":0},"cellular":{"present":true,"signal_level":4,"network_type":"LTE","data_enabled":true},"reasons":{}}'
wait_for 10 "Wi-Fi off" tl_is wifi.enabled false
wait_for 10 "the Wi-Fi icon is the disabled one" tl_is wifi.icon network-wireless-disabled-symbolic
wait_for 10 "no SSID without a connection" tl_is wifi.ssid null

# Connected to another network, weak signal.
fake_push network '{"ok":true,"wifi":{"enabled":true,"connected":true,"ssid":"Cafe","signal_level":1},"cellular":{"present":true,"signal_level":4,"network_type":"LTE","data_enabled":true},"reasons":{}}'
wait_for 10 "Wi-Fi shows Cafe" tl_is wifi.ssid Cafe
wait_for 10 "level 1 is the weak icon" tl_is wifi.icon network-wireless-signal-weak-symbolic

# Mobile: 5G, level 2, data off.
fake_push network '{"ok":true,"wifi":{"enabled":true,"connected":true,"ssid":"Cafe","signal_level":1},"cellular":{"present":true,"signal_level":2,"network_type":"NR","data_enabled":false},"reasons":{}}'
wait_for 10 "NR is 5G" tl_is wwan.tec 5G
wait_for 10 "level 2 is 50" tl_is wwan.signal 50
wait_for 10 "mobile data is off" tl_is wwan.data false

# No modem.
fake_push network '{"ok":true,"wifi":{"enabled":true,"connected":true,"ssid":"Cafe","signal_level":1},"cellular":{"present":false,"signal_level":0,"network_type":"UNKNOWN","data_enabled":false},"reasons":{}}'
wait_for 10 "the modem is gone" tl_is wwan.present false
wait_for 10 "the mobile quick setting is insensitive" tl_is tiles.wwan.sensitive false

# Read-only: a tap on either quick setting posts nothing.
fake_reset
tl_tile wifi click
tl_tile wwan click
sleep 1
n=$(fake_calls | python3 -I -c 'import json, sys; print(sum(1 for c in json.load(sys.stdin) if c["method"] == "POST"))')
[ "$n" = 0 ] || die "tapping the Wi-Fi and mobile quick settings posted $n calls, wanted none"
pass "tapping the Wi-Fi and mobile quick settings posts nothing"

# Long-press: Android's pages, through POST /v1/settings/open.
tl_tile wifi long-press
wait_for 10 "the Wi-Fi long-press posts /v1/settings/open wifi" \
    fake_body_is POST /v1/settings/open '{"page":"wifi"}'
tl_tile wwan long-press
wait_for 10 "the mobile long-press posts /v1/settings/open mobile" \
    fake_body_is POST /v1/settings/open '{"page":"mobile"}'
n=$(fake_call_count POST /v1/settings/open)
[ "$n" = 2 ] || die "settings/open was posted $n times, wanted 2"

n=$(fake_call_count GET /v1/network)
[ "$n" = 0 ] || die "phosh polled GET /v1/network ($n times)"

if bad=$(fake_unexpected); then
    pass "the fake received no unexpected call"
else
    die "unexpected calls at the fake: $bad"
fi
