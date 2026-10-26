# Phosh

The phone shell from the GNOME and Nura (formerly postmarketOS) world, running on the launcher's
display as a full Linux desktop. Open it from **Desktops** and you get Phosh's top bar, quick
settings, app grid and overview, with every Termux app that has a `.desktop` file listed in the
grid. Tap one and it opens as a window; apps that only speak X11 run through Xwayland.

This is a native build for Termux, not a proot. Three programs make it up: **phoc**, the compositor,
**phosh**, the shell, and **phosh-mobile-settings**, the settings app. They are pinned to one
upstream version and move together.

## What works

- **A phone shell on the display.** Phosh starts unlocked, fills the display and follows it when
  you rotate the phone or the keyboard comes and goes.
- **Your Termux apps in the grid.** No filter hides desktop-only apps.
- **Android's keyboard.** Text goes in through the display, as in any other Linux app here.
- **Vibration.** Phosh and GTK apps ask for haptics through `org.sigxcpu.Feedback`; a small daemon
  of ours turns that into a vibration of the phone.
- **Mobile Settings.** Four panels: the overview, the top bar and quick settings, feedback, and the
  compositor, which holds the display scale.

## What is compiled out, and why

Phosh upstream expects a whole Linux system under it. This build keeps the shell and drops what
Android already does or what Termux cannot provide:

- the lock screen, its PIN and PAM: the phone is already locked by Android
- the on-screen keyboard: Android's keyboard is used
- calls, SMS and the modem, NetworkManager, ModemManager: the phone's telephony stays with Android
- Bluetooth, VPN, location and the hotspot tile
- logind, polkit and udev: there is no system bus and no login session here

In Mobile Settings the panels for language, emergency alerts, lock screen, keyboard, OS updates and
the like are out for the same reasons.

## Known limits

- **No lock screen and no on-screen keyboard.** See above.
- **Wi-Fi and mobile tiles show state only**, when the launcher provides it; they cannot switch
  anything. Battery and rotation follow the phone.
- **No Bluetooth, VPN, location or hotspot** tiles.
- **The quick-settings page cannot reorder tiles**, because phosh's plugins are not built.
- **The display has to be open.** From a terminal, open **Display** in the launcher first, or just
  use the Desktops entry, which opens it.
- Needs a launcher recent enough for the display and the bridges; the store checks this.

## The Termux packages it needs

Installing Phosh also installs one hidden part, `phosh-deps`: Termux's GTK 3 and 4, Mesa, the
Wayland and X libraries, libadwaita and the rest, 123 packages in all, about **87 MB to download and
535 MB on disk** on a phone, far more than the item itself, about 4 MB. The store tells you the
numbers before it asks. The part includes the Vulkan loader, and on 64-bit ARM Termux's Freedreno
(Turnip) Vulkan driver.

## The display scale

Phosh picks a scale from the display's width (the width divided by 360, rounded down, at least 1).
If everything looks too big or too small, set one yourself:

- in Mobile Settings, under the compositor panel, set **Display scale** (0 means automatic; 1 to
  10 sets it), then stop and start Phosh again; or
- for one start, from a terminal: `PHOSH_SCALE=2 phosh-session`.

The environment variable wins over the setting.

## The GPU

On phones with an Adreno GPU, phoc draws with Vulkan and copies each frame to the display. On
anything else (an emulator, a Surface, Mali phones) or when the driver does not start, it falls back
to drawing with the CPU, and says so in its log. `WLR_RENDERER=pixman` or `WLR_RENDERER=vulkan`
forces one; a forced Vulkan that fails does not fall back. Apps draw with the CPU either way.

## Stopping it

Close the Display window in the launcher, or from a terminal:

```sh
phosh-session stop
```

Both end phoc and everything it started.

## Where it comes from

[Phosh](https://gitlab.gnome.org/World/Phosh/phosh), [phoc](https://gitlab.gnome.org/World/Phosh/phoc)
and [phosh-mobile-settings](https://gitlab.gnome.org/World/Phosh/phosh-mobile-settings) are
GPL-3.0-or-later, made by Guido Günther and the Phosh developers. The patches that make them build
and run here are in this store's `recipes/cross`.
