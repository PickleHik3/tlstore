# tests/phosh

phoc and phosh run headless on the host against a fake launcherctl (`docs/PHOSH.md`, "Testing").
`run-headless.sh` builds both with the recipes' patch sets, starts everything and runs every
`test-*.sh` here; `run-headless.sh --self-test` checks only the fake (no build needed).

Writing a bridge test, in three lines:

1. Add `tests/phosh/test-NN-name.sh` that starts with `. "$TL_SCRIPT_DIR/lib.sh"`; it runs under `set -e` with phosh up and the fake's endpoint and token in `~/.launcherctl/`.
2. Drive the bridge with `fake_push battery '{"percentage":9,...}'` (an SSE event on `/v1/watch`) or `fake_control_post /state/rotation '{...}'`, and check what phosh did with `wait_for 10 "what" <command>`, `on_bus <name>` and `gdbus`.
3. Check what phosh sent back with `fake_calls`, `fake_call_count POST /v1/vibrate` and `fake_unexpected`; call `fake_reset` first to start from an empty log.

## Test hooks

`tl_get` and `tl_tile` (lib.sh) call two methods on `mobi.phosh.Shell.DebugControl`, `TlState`
and `TlTile` (recipes/cross/phosh/0023). They exist only in a phosh configured with
`-Dtl-debug=true` (recipes/cross/phosh/0033), which `run-headless.sh` passes; `build-phosh.sh`
leaves the option off and checks that the phone's binary does not have them, so no other client of
the launcher's shared session bus can read the managers or press a quick setting through them.

## Dependencies below noble's versions

phoc 0.58.0, its wlroots 0.20.2 subproject and phosh 0.58.0 (with the recipes' patches applied, the
options `run-headless.sh` passes) need newer libraries and tools than Ubuntu 24.04 ships. The ones
below are built from pinned tarballs into `$TL_TEST_DIR/prefix` by `build_dep` before phoc
(`run-headless.sh --deps-only[=name,...]` builds only these); the prefix comes first on
`PKG_CONFIG_PATH`, `PATH` and `LD_LIBRARY_PATH`. Versions as checked on 2026-10-26.

| name | required (by) | noble has | action |
|---|---|---|---|
| wayland (server, client, scanner) | >= 1.24.0 (wlroots), >= 1.23.1 (phoc) | 1.22.0 | build 1.24.0 |
| wayland-protocols | >= 1.49 (text-input v3 version 2, as the Termux sysroot has) | 1.34 (1.45 in -updates) | build 1.49 |
| glib | >= 2.84 (phosh links g_variant_builder_init_static, g_clear_dbus_signal_subscription) | 2.80.0 | build 2.84.4 |
| pixman | >= 0.46.0 (wlroots pixman renderer), >= 0.43.4 (phoc) | 0.42.2 | build 0.46.4 |
| libdrm | >= 2.4.129 (wlroots) | 2.4.120 (2.4.125 in -updates) | build 2.4.129, no drivers |
| libxkbcommon | >= 1.8.0 (wlroots) | 1.6.0 | build 1.8.1, keymaps from /usr/share/X11 |
| gsettings-desktop-schemas | >= 47 (phosh) | 46.0 (46.1 in -updates) | build 47.1; its schemas replace the system's in the test schema dir |
| libsoup-3.0 | >= 3.6 (phosh) | 3.4.4 | build 3.6.5 (no gssapi, ntlm, brotli, TLS check) |
| meson | >= 1.7.0 (phosh), >= 1.3 (wlroots) | 1.3.2 | CI installs meson 1.7.2 with pip in a venv |
| libinput | >= 1.27.0 (phoc) | 1.25 | not needed: recipes/cross/phoc/0001 removes the dependency |
| libdisplay-info, hwdata, libliftoff, libseat, libudev | wlroots DRM and session backends | n/a | not needed: the harness builds only the x11 and headless backends with `session=disabled` |
| libhandy-1 | >= 1.1.90 | 1.8.3 | ok |
| gcr-3 | >= 3.7.5 | 3.41.2 | ok |
| gnome-desktop-3.0 | >= 3.26 | 44 | ok |
| glib / gio | >= 2.80 (phoc, phosh) | 2.80.0 | ok |
| appstream | >= 1.0.0 | 1.0.2 | ok (`libappstream-dev` added to apt) |
| upower-glib | >= 1.90 | 1.90.3 | ok |
| gtk+-3.0 | >= 3.22 | 3.24 | ok |
| libpulse | >= 12.99.3 (libgvc) | 16.1 | ok |
| vulkan, glslang | wlroots' Vulkan renderer | libvulkan-dev, glslang-tools | installed by CI (`ci.yml` apt list) and `glslangValidator` is one of the tools `run-headless.sh` checks for, but nothing here compiles against them: `renderers=` is empty |
| lcms2, gbm, egl | wlroots renderers, color management | n/a | not needed: `renderers=` is empty, color-management disabled |
| sysprof-capture-4 | >= 48 (phoc) | n/a | optional, not requested |
| gmobile (v0.6.0_beta1), gvdb, libfeedback (v0.8.1), gvc | meson subprojects | n/a | built by meson, static; need only glib >= 2.78, json-glib >= 1.6.2 |

Not in the table: everything the recipes' options compile out (NetworkManager, ModemManager,
polkit, logind, bluetooth, EDS, gudev, calls, the lock screen).

The three `meson.build` files and wraps were read at the pinned tags; wlroots' own wraps (wayland,
libdrm, libxkbcommon, pixman, wayland-protocols) are never used, because phoc itself looks for
pixman and wayland without a fallback, so a subproject build would not satisfy it.

## Status

The `phosh-headless` job in `.github/workflows/ci.yml` was seen green on 2026-10-26 (run
40335453739) and is a required job since then: it has no `continue-on-error`. The `phoc-xvfb` job
beside it (`recipes/cross/phoc-xvfb-test.sh`, phoc following the X root window's size and scale
on Xvfb) reuses `run-headless.sh --deps-only` for the libraries noble lacks; it keeps
`continue-on-error: true` until it has been seen green.
