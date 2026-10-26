# Phosh on the launcher's display — design

Status: agreed design (2026-10-25, decisions Q1–Q26 taken with the developer in a grilling
session), build not started. The choice of approach is recorded in
[ADR 0005](adr/0005-phosh-as-a-native-desktop-item.md). This document says what the `phosh` item
is, what it keeps and drops of upstream phosh, how each kept feature reaches Android, what the
launcher has to add, how it is built and shipped, and in what order the work is done.

## Goal

A tlstore item that puts [Phosh](https://gitlab.gnome.org/World/Phosh/phosh), the GNOME-based
phone shell that Nura (formerly postmarketOS) ships, on the launcher's X11 display as a Linux
desktop. Termux's own GUI apps open as phosh windows; phosh's top bar and quick settings show the
phone's real battery, network and rotation state; its notifications reach Android's shade.

Built natively against the `com.termux` prefix. Shipped as one tlstore `archive` plus Termux
packages as parts. aarch64 and x86_64.

Not goals:

- Replacing the launcher's home. The launcher stays the phone's home; phosh is a desktop opened
  from **Desktops** like xfce (Q1).
- Other editions. `io.vaj.tl` and the Nix edition are not built for (Q2).
- Phone telephony. Calls, SMS and the modem stay with Android.
- Android apps in phosh's grid. Possible later as hand-picked `.desktop` entries (below).

## What the user sees

1. `tlstore install phosh` installs the archive and its Termux packages.
2. **Phosh** appears under **Desktops** in the launcher's app drawer. A tap opens the display
   with phosh full-size on it, unlocked.
3. The app grid lists every Termux app that ships a `.desktop` file, without the mobile-only
   filter (Q15). Tapping one opens it as a phosh window; X11-only apps run through Xwayland
   inside phoc (Q7).
4. The top bar shows battery, Wi-Fi and mobile signal from Android (Q5). Quick settings has
   Wi-Fi and mobile status, battery, rotation lock, torch, dark style, screenshot and docked mode
   (Q23). Long-pressing Wi-Fi, mobile or battery opens that Android Settings page (Q19).
5. Text input uses Android's keyboard, through the display (Q6).
6. A Linux app's notification shows in phosh and in Android's shade; tapping the Android one
   brings the display, with phosh, to the front (Q16).
7. Haptics in phosh and in GTK apps vibrate the phone (Q14, Q21).
8. Rotating the phone, or showing and hiding the keyboard, resizes phosh with the display (Q12).
9. **Mobile Settings** (phosh-mobile-settings) changes phosh's own options (Q13, Q17).

## Shape at run time

```
launcher (Android)
 ├─ termux-x11 :0 ─────────── the display window
 │    └─ phoc (X11 backend, one window = the X root, follows its size)
 │         ├─ phosh ── tl backends ── launcherctl (battery, network, rotation, torch,
 │         │                                       notify, open settings page, watch stream)
 │         ├─ Xwayland (X11-only apps)
 │         └─ Wayland apps from $PREFIX/share/applications
 ├─ tl-feedbackd ─── org.sigxcpu.Feedback ── launcherctl vibrate
 └─ termux-launcher-bus ─── the D-Bus session bus phosh, its apps and the launcher share (Q22)
```

phosh needs no system bus: everything that used one (logind, NetworkManager, ModemManager,
UPower, iio-sensor-proxy, BlueZ, geoclue, polkit) is either compiled out or replaced by a tl
backend reading launcherctl.

## Upstream components and versions

Pinned to the versions Nura ships at the time of writing (Alpine edge `community/phosh`,
`community/phoc`): 0.58.0. upstream-watch tracks all three (Q20).

| Component | Upstream | Our changes |
|---|---|---|
| phosh | 0.58.0 tarball, sources.phosh.mobi | the tl patch set: meson options that compile out the dropped managers, tl backends for the bridges, `app-filter-mode` default `[]`, start unlocked with no lock screen |
| phoc | 0.58.0 tarball, built with its bundled wlroots 0.20 subproject (Termux ships wlroots 0.18.2, too old) | follow the X root's size and scale; Vulkan on kgsl (below); no libinput, no udev, X11 backend only |
| phosh-mobile-settings | 0.58.0 | panels kept: overview and apps, compositor and scale, quick-settings layout, feedback and alerts (Q17); accountsservice, libnm, polkit, cell broadcast, lock-screen and OSK panels compiled out |
| gmobile | phosh's subproject or its own tarball | none expected |
| libfeedback | from feedbackd's tree, library only | none expected; the daemon is ours (`tl-feedbackd`) |
| libcall-ui, libgvc | phosh's subprojects | libcall-ui compiled out with calls; libgvc kept (volume over PulseAudio) |

From Termux's repositories, installed as `pkg` parts. Checked present in the official main and
x11 indexes on 2026-10-25: gtk3 3.24.52, libhandy 1.8.3, libadwaita 1.10.0, gcr 3.41.2,
gnome-desktop3 51.0, glib 2.90.1, json-glib, libsecret, libsoup3, fribidi, appstream, upower
(client library only), pulseaudio, libwayland 1.26.0, libwayland-protocols 1.49, libpixman,
libdrm, mesa 26.2.5, xwayland 24.1.14, libxkbcommon, xkeyboard-config,
gsettings-desktop-schemas, adwaita-icon-theme, dbus, qrcodegen, hwdata, libdisplay-info, libseat.
Not yet checked, needed by phosh-mobile-settings: gtk4, gnome-desktop4, libyaml, gsound,
libportal. The exact list is fixed in milestone M1, from what the build actually links.

Not in Termux and not ported, because the features that need them are dropped: elogind/libsystemd,
libudev/libgudev, libinput, NetworkManager/libnm, ModemManager/mm-glib, polkit, linux-pam,
evolution-data-server, gnome-bluetooth, callaudiod, accountsservice, libcbd.

## Keep, drop, bridge

Dropped features are compiled out through new meson options in the tl patch set (Q10). No stub
libraries and no fake system services.

| Feature | Decision | How |
|---|---|---|
| Lock screen, PIN unlock, lock-screen plugins | drop (Q3) | `-Dlockscreen=false`; phosh starts unlocked; screensaver lock off |
| PAM | drop (Q3) | goes with the lock screen |
| polkit agent | drop (Q3) | `-Dpolkit=false` |
| logind sessions, idle/suspend inhibit through logind | drop (Q4) | `-Dlogind=false`; the session is phoc's child |
| On-screen keyboard (squeekboard / stevia) | drop (Q6) | not shipped; OSK manager compiled out; Android's keyboard comes in through termux-x11 (and fcitx5 where installed) |
| Calendar on lock screen and quick settings (evolution-data-server) | drop (Q8) | `-Deds=false` |
| Search daemon | drop (Q8) | upstream `-Dsearchd=false`; app search in the overview stays |
| Calls, SMS, modem, emergency calls, call UI | drop (Q4) | `-Dcalls=false` (callaudiod, libcall-ui, wwan-mm, emergency-calls) |
| Bluetooth, VPN, location, hotspot | drop (Q4) | `-Dbluetooth=false`, VPN and location managers out; their tiles are not offered |
| Wi-Fi status, mobile status | bridge, read-only (Q5) | tl network backend; tiles show state only, long-press opens Android Settings (Q19) |
| Battery | bridge (Q5) | tl battery backend in place of UPower |
| Rotation and rotation lock | bridge (Q5) | tl rotation backend in place of iio-sensor-proxy |
| Notifications | keep and bridge (Q16) | phosh stays the notification server; each notification is also posted through launcherctl |
| Haptics and event feedback | bridge (Q14, Q21) | libfeedback kept; `tl-feedbackd` answers `org.sigxcpu.Feedback` and vibrates through launcherctl |
| Torch | bridge (Q23) | tl torch backend → launcherctl's torch route |
| Volume, media-player widget | keep | libgvc over the launcher's PulseAudio; MPRIS on the shared session bus (Q22) |
| Screenshot | keep (Q23) | phosh's own; saved under `~/Pictures` |
| Docked mode | keep (Q23) | phosh's convergence mode; matters most on the Surface |
| Dark style tile | keep (Q23) | gsettings `color-scheme`, independent of Android's theme |
| Xwayland | keep (Q7) | from Termux's x11 repository |
| Settings app | port phosh-mobile-settings (Q13) | panels in Q17; gnome-control-center does not exist in Termux |
| App filter | change (Q15) | `app-filter-mode` default `[]` in our build |

## Bridges

Each bridge is a backend inside phosh (or `tl-feedbackd`) that talks to launcherctl's HTTP API
(`~/.launcherctl/endpoint`, `~/.launcherctl/token`; `docs/en/LauncherCtl_API.md` in the launcher).
State comes from one watch stream (below), read once at start and then pushed. Nothing polls.

| Bridge | launcherctl today (2026-10-25) | Needed from the launcher | phosh side |
|---|---|---|---|
| Battery | `GET /v1/battery`: percentage, status, plugged, health, temperature, current; poll only | battery changes on the watch stream | battery manager reads the tl backend instead of UPower; time remaining is not shown |
| Wi-Fi status | none | `GET /v1/network`: Wi-Fi on/off, connected, SSID, signal level; changes on the watch stream | wifi-manager tl backend, read-only; long-press → Android Wi-Fi settings |
| Mobile status | none | the same route: cellular present, signal level, network type, data on/off | wwan-manager tl backend, read-only; long-press → Android mobile-network settings |
| Rotation | none | `GET /v1/rotation`: current orientation, rotation lock; set rotation lock; changes on the watch stream | rotation manager tl backend; the rotation-lock tile sets Android's lock |
| Torch | torch route (mapped by termux-api-shims) | — | torch tile tl backend |
| Notifications → Android | `launcherctl notify` / `POST` signal routes, OSC 99 | an action that opens the display when the notification is tapped | notify manager posts each notification; closing in phosh withdraws it in Android (by id) |
| Vibration | vibrate route (mapped by termux-api-shims) | — | `tl-feedbackd` maps feedback events to vibrate patterns |
| Open a Settings page | none for Android Settings pages | `POST /v1/settings/open` with `wifi`, `mobile`, `battery` | tile long-press |

The display's size is not bridged through launcherctl: phoc reads it from the X server (below).

## Launcher changes

Done in the launcher repository (`PickleHik3/termux-launcher`), in its own worktree, merged into
its `dev` only with the developer's OK (Q11). Each new route is documented in
`docs/en/LauncherCtl_API.md` and `docs/en/LauncherCtl.md`.

1. `GET /v1/network`: Wi-Fi and cellular status as in the bridge table. Read-only.
2. `GET /v1/rotation` and `POST /v1/rotation` (lock on or off).
3. `GET /v1/watch`: one long-lived stream (newline-delimited JSON or server-sent events, picked
   in M2) carrying `battery`, `network` and `rotation` changes, starting with one event of each.
   The API has no event routes today (`LauncherCtl_API.md:79`); this is the first.
4. Notifications posted with an "open the display" action.
5. `POST /v1/settings/open` for the Wi-Fi, mobile-network and battery pages.

The `phosh` row carries `min-launcher=` set to the first launcher release with all five.

## phoc on the X11 display

- **Size and scale.** The X11 output follows the X root window: phoc watches the root's
  ConfigureNotify (RandR) and resizes its window and output to match, from the first frame. The
  scale is the width divided by 360, rounded down, at least 1. phosh-mobile-settings'
  compositor panel can override it, and so can `PHOSH_SCALE`. This replaces the trial's
  `xev` + `xdotool` + `wlr-randr` watcher (Q12).
- **Input.** Keyboard, pointer and touch arrive as X11 events on phoc's window. No libinput, no
  udev, no libseat session.
- **Rendering (Q25, Q26).** Vulkan through Mesa's Turnip on Adreno's kgsl kernel interface,
  carried to the screen the way [phosh-termux-gpu](https://github.com/Azkali/phosh-termux-gpu)
  does it, since the display offers no DRI3: wlroots' Vulkan renderer (built in, `renderers=vulkan`,
  with pixman beside it) renders each frame into an internal device-local image, the same command
  buffer copies it into a host-visible staging buffer, and once the GPU is done the CPU copies that
  into the shm buffer the X11 backend already presents as an xcb shm pixmap (`recipes/cross/phoc/0005`,
  a wlroots patch file). The Vulkan device is the first hardware one; a CPU device (llvmpipe) is
  skipped. At start `wlr_renderer_autocreate` tries it and falls back to pixman when the loader, the
  ICD or the device does not initialise (Surface, the emulator, Mali and others), and logs one line
  either way (`Renderer: vulkan, presenting through shared memory (no DRM node)` or `Renderer: pixman
  (fallback, the GPU renderer did not start)`). `WLR_RENDERER=pixman|vulkan` forces one (a forced
  Vulkan that fails does not fall back); the compositor panel sets it later. Termux's own
  `mesa-vulkan-icd-freedreno` carries the kgsl Turnip, so the archive ships no driver (Q3, settled
  2026-10-26): version 26.2.5 (main repository, aarch64, 1.6 MB; `libvulkan_freedreno.so` is 13.9 MB
  unpacked) holds `tu_knl_kgsl.cc` and opens `/dev/kgsl-3d0`, and installs
  `share/vulkan/icd.d/freedreno_icd.aarch64.json`; it depends on `vulkan-loader-generic` (1.4.366),
  which supplies the `libvulkan.so.1` phoc links. Both are hidden parts of the archive's package
  (they must be installed for phoc to start, phoc links the loader). The ICD's "DRI3" strings are
  its window-system code, which wlroots does not use. Cost per frame: the whole frame is read back
  and copied once (about 10 MB on a 1080x2400 screen), on a path the pixman renderer pays in CPU
  blending instead.
- **Apps' renderer.** GTK apps keep `GSK_RENDERER=cairo`. M5 did not try the GL path: with no DRI3
  and no DMA-BUF between the display and phoc, phoc advertises no `linux-dmabuf` (the Vulkan
  renderer hides its DMA-BUF formats in this mode), so a GTK app has no way to hand it a GPU
  buffer and its GL renderer would copy through shm anyway.

## Session

- `phosh-session` (the archive's `exe=`, wrapper `~/.local/bin/phosh-session`) starts the
  display if it is not running, starts `tl-feedbackd`, then execs `phoc -E phosh`. It joins the
  launcher's session bus (`termux-launcher-bus`, Q22) instead of starting a private one.
- **Desktops entry.** The launcher reads whole-desktop sessions from `$PREFIX/share/xsessions`
  and `$PREFIX/local/share/xsessions` (`ProotDistro.sessionDirs()`), not from `~/.local/share`.
  An archive unpacks under `~/.local/lib/phosh`, so the item needs one more step to put
  `phosh.desktop` (`Exec=phosh-session`) into `$PREFIX/local/share/xsessions`: a hidden `file` part,
  `phosh-session-file`, with a `$PREFIX` target (ADR 0006).
- **Stopping.** Closing the display window from the launcher stops phoc, and phoc's children
  with it. `phosh-session stop` does the same from a terminal.
- **Settings defaults.** Our build's gschema overrides: `app-filter-mode []`, screensaver lock
  off, no OSK. Users' own dconf settings win.

## Packaging

- One `archive` row, `phosh`, `prefixes com.termux`, `source binaries:phosh@bins-…`,
  `x86_64:digest=` for the x86_64 build, `exe=bin/phosh-session`, version
  `0.58.0+<commit>.<N>` as for other store-built archives (`docs/maintainer/catalog.md`).
- `requires`: a hidden `pkg` part, `phosh-deps`, naming the Termux packages above, with
  `pkg-size=` computed by `scripts/pkg-weight.py` and `repo=1` handling for `x11-repo`. Plus the
  session-file part (open question 1).
- `min-launcher=` as above. `host=launcher`: the bridges need launcherctl.
- The archive holds: `bin/` (phoc, phosh, phosh-session, tl-feedbackd, phosh-mobile-settings),
  `lib/` (gmobile, libfeedback, phoc's static wlroots needs nothing at run time), `libexec/`,
  `share/` (gschemas compiled at build, pointed at by `GSETTINGS_SCHEMA_DIR`; icons, the phosh and
  phosh-mobile-settings `.desktop` files, locale). The wrapper exports `XDG_DATA_DIRS` and
  `GSETTINGS_SCHEMA_DIR` to include the archive's `share/`.
- Size, measured in M1 (2026-10-26): the archive is 1.34 MB (aarch64) and 1.39 MB (x86_64) as a
  `.tar.gz`, about 4 MB unpacked. The Termux packages `phosh-deps` pulls in beyond a stock Termux
  are 123 packages, 87 MB to download and 535 MB on disk (`pkg-size=87,535`; the libllvm that mesa
  needs is 174 MB of that, gtk4 for the settings app 42 MB). The trial's Alpine install is not a guide (it pulled GNOME's whole
  session stack).

## Build

- `recipes/cross/build-phosh.sh`, one script for the three upstream trees and `tl-feedbackd`,
  like the other `build-*.sh`: fetch the pinned tarballs, apply `recipes/cross/phosh/*.patch`,
  `phoc/*.patch`, `phosh-mobile-settings/*.patch` in order, and build with meson against a Termux
  sysroot (`recipes/cross/termux-sysroot.sh`, populated from Termux's `.deb`s for the parts list),
  NDK clang, a meson cross file per processor.
- `build.yml` builds `phosh-aarch64` and `phosh-x86_64` and publishes them as `bins-…` assets,
  as for every other tool. `bins-record.sh` records them.
- `scripts/upstream-watch.sh` gains phosh, phoc and phosh-mobile-settings (Q20). They move
  together: a bump of one is a bump of all three at the same version, trial-built, and a patch
  that stops applying fails the trial and is reported in the "Upstream watch" issue. Patches are
  rebased with git (apply the stack as commits on the old tag, `git rebase <new tag>`,
  regenerate), as done for btop 1.4.8 on 2026-10-25.

## Testing

Tests check behaviour seen from outside, at the highest seam available, not internals.

- **Bridges: one seam, the launcherctl API.** A fake launcherctl serves the HTTP routes and the
  watch stream (battery, network and rotation events). phoc runs headless with phosh against it,
  using upstream phosh's own headless test fixtures. The tests check what phosh shows (tile and
  top-bar state) and what it sends back to the fake (notify, vibrate through `tl-feedbackd`,
  torch, rotation lock, opening a Settings page). Runs on the host in CI; no phone.
- **Catalog row, archive and session file: tlstore's engine suite** (`scripts/test.sh`), as for
  the other archive items: install, update, rollback and remove of `phosh` and its parts.
- **phoc following the display: Xvfb.** Resize an Xvfb screen through RandR and check that phoc's
  output size and scale follow.
- **Launcher routes: the launcher repository's own tests**, written there. Agents don't run
  Gradle builds; the developer does.
- **Device checks** on the emulator (and on Pong for Adreno and GPU) close each milestone.

## Milestones

Each milestone ends with something that runs on the emulator (and Pong where it needs Adreno).

| | Milestone | Done when |
|---|---|---|
| M0 | Build skeleton | `build-phosh.sh` builds unpatched phoc (X11 only, pixman, bundled wlroots) for both processors against the Termux sysroot; phoc runs nested on the display on the emulator |
| M1 | phosh compiled down | the tl patch set's meson options build phosh with every dropped feature out; `phosh-session` runs it on the display, unlocked, app grid showing all Termux apps; parts list, archive layout, session-file step and size settled; `phosh` row installable from a dev catalog |
| M2 | Launcher routes | network, rotation, watch stream, notification action and settings-page routes in the launcher, merged with the developer's OK; `min-launcher` known |
| M3 | Bridges | battery, network, rotation, torch and notification backends in phosh; `tl-feedbackd`; tile long-press to Android Settings; all on the watch stream |
| M4 | phoc follows the display; settings app | phoc's size-and-scale patch; phosh-mobile-settings with the four panels |
| M5 | GPU | Vulkan on kgsl on Adreno with the fallback to pixman; the Mesa question settled; checked on Pong |
| M6 | Ship | upstream-watch entries, `build.yml` assets, catalog row with readme and hero picture, user doc in `docs/user/`, store release |

M2 can run alongside M0–M1. M5 can start after M0.

## Later

- Hand-picked Android apps in phosh's grid: a `.desktop` file in
  `~/.local/share/applications` with `Exec=launcherctl launch <package>` and the app's icon shows
  up like any app, live. A small helper to create and remove these is all it needs.
- Other editions (`io.vaj.tl` from its own repository, Nix), if wanted.

## Open questions

1. ~~How the session file reaches `$PREFIX/local/share/xsessions`.~~ Settled in M1 (2026-10-26): a
   hidden `file` part with a `$PREFIX` target; the engine's target column takes `$PREFIX` now
   (`docs/adr/0006-phosh-session-file.md`). No `post=`.
2. The watch stream's wire format (NDJSON over a held HTTP response, or SSE). Decided in M2 with
   the launcher's API conventions.
3. ~~Whether Termux's mesa has a kgsl-enabled Turnip or the archive ships its own Vulkan
   driver.~~ Settled in M5 (2026-10-26): Termux's `mesa-vulkan-icd-freedreno` 26.2.5 (main,
   aarch64) is built with the kgsl backend, so the archive ships no driver. Should that package
   ever lose kgsl, building Mesa here would take `-Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl`
   (about 14 MB for `libvulkan_freedreno.so`, as Termux builds it), as a separate hidden part of the package.
4. Where `tl-feedbackd` lives if other Linux desktops on the display want haptics too: inside the
   phosh archive (now) or as its own hidden item (later).

## Background: the proot trial (2026-10-25)

Nura's phosh 0.58.0 ran on Pong in an Alpine edge proot, nested on the display with
`WLR_BACKENDS=x11` and pixman. It reached "Phosh ready" in 1–3.5 s. Lessons that carry over:

- A fresh termux-x11 sits at its default 1280×1024 until its window attaches, and only attaches
  when the display is looked at. Sizing phoc once at start is wrong; following the root is right.
- Polling the display size once a second through proot cost about a third of a core; event-driven
  is the only acceptable shape.
- phosh locks at start unless told `--unlocked`, and the lock screen needs PAM.
- Every system service phosh asks for (NetworkManager, ModemManager, UPower, BlueZ, geoclue,
  sensor-proxy, logind, hostname1, gnome-session) is absent, and phosh carries on without each.
  Its quick settings then have empty tiles, which this design replaces with bridges or removes.
- Processes started over `ssh termux` run in another SELinux context; the launcher terminal can
  neither see nor signal them. Device checks start sessions from the launcher terminal.
