---
status: accepted
date: 2026-10-25
---

# Phosh ships as a native, compiled-down desktop item, with launcherctl bridges

We want Phosh, the phone shell Nura (formerly postmarketOS) ships, on the launcher's X11 display
as a Linux desktop. The design is in [PHOSH.md](../PHOSH.md). This records why it is built the way
it is.

What we tried first: Nura's own phosh 0.58.0 (Alpine edge) in an Alpine proot on Pong, phoc nested
on the display with the X11 backend and pixman. It worked: phosh came up, ran Alpine's GTK apps
and resized with the display once a watcher drove it. It also showed the limits: it sees only the
container's apps (Termux's binaries do not run inside Alpine), every system service phosh asks for
is missing so half its quick settings are empty tiles, the lock screen needs PAM, glycin's
bubblewrap sandbox had to be shimmed out, and anything polled through proot costs real CPU.

Decided:

- **Native, not proot.** phosh and phoc are built for the `com.termux` prefix, so the app grid
  lists and runs Termux's own GUI apps, with no rootfs to download or keep current.
- **com.termux only.** The edition most users run. `io.vaj.tl` (which already carries most of the
  dependencies) is not built for now.
- **A tlstore archive plus Termux packages as parts,** not our own apt repository and not a fully
  self-contained bundle. Termux's repositories already have 30 of the 45 libraries phosh, phoc and
  their tools need (gtk3, libhandy, gcr, gnome-desktop3, upower, xwayland and more). The archive
  carries only what Termux lacks: phosh, phoc with its bundled wlroots 0.20 (Termux has 0.18.2),
  gmobile, libfeedback, phosh-mobile-settings and our small services. This uses the store's
  existing `archive` kind and parts, and needs no second signing pipeline.
- **Compile features out, do not fake them.** The missing system pieces (logind, udev/gudev,
  libinput, NetworkManager, ModemManager, polkit, PAM, evolution-data-server, gnome-bluetooth,
  callaudiod) are removed with meson options and `#if` guards in a tl patch set, not replaced by
  stub libraries or fake system D-Bus services. A stub that answers "no Wi-Fi" is a feature that
  pretends; an option that leaves the feature out is honest and cannot drift into half-working.
  The cost is a large patch set to keep rebased; upstream-watch's trial builds catch drift, as
  they did for btop 1.4.8.
- **Bridge what the phone already knows, through launcherctl.** Battery, Wi-Fi and mobile status,
  rotation, torch, notifications and vibration come from Android through tl backends inside phosh
  (and a feedbackd-compatible `tl-feedbackd`, so GTK apps' haptics work too). Settings pages that
  phosh cannot change open Android's. The launcher gains the missing routes and one watch stream,
  so no bridge polls.
- **phoc follows the display itself.** Its X11 output tracks the X root's size and scale, instead
  of an external xev/xdotool/wlr-randr watcher.
- **GPU in v1, with a fallback.** Vulkan on Adreno through kgsl (the approach of
  phosh-termux-gpu), pixman everywhere else, picked automatically. The developer chose the GPU in
  v1 over shipping pixman first.

Alternatives not taken:

- Proot with Nura's packages (the trial): no Termux apps, empty tiles, a rootfs to maintain.
- The `io.vaj.tl` repository as `.deb`s: fewer missing dependencies, but not the edition most
  users have.
- Our own apt repository for `com.termux`: cleaner dependency handling, a second repository and
  signing pipeline to run.
- Stub libraries and fake UPower/NetworkManager/SensorProxy services: phosh's source would stay
  upstream, but the system would claim services it does not have, and the fakes would have to
  track those services' D-Bus APIs.
- Replacing the launcher's home with phosh: needs Android apps, calls and notifications bridged
  into phosh; out of scope.

Revisit if: upstream phosh grows build options for running without these services (then our patch
set shrinks to the bridges); Termux starts packaging phosh or phoc; the launcher gains a Wayland
display (phoc's X11 nesting and the frame copy for the GPU would go); or the patch set's rebase
cost proves larger than a release cycle's work.
