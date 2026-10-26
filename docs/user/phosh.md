# Phosh

`phosh` puts a phone desktop on the launcher's display: the Phosh shell and its compositor, built
for Termux, with your Termux apps in its grid. It is a launcher item (not offered in plain
Termux), and it needs a launcher recent enough for the display and its bridges; the store checks
that for you. The item page in the store has the short version of everything below.

## Install

```sh
tlstore install phosh
```

The store first says what it brings along: Termux's GTK, Mesa and the other libraries Phosh needs,
about 87 MB to download and 535 MB on disk, beside the item itself, about 4 MB. It asks before it
installs. On 64-bit ARM it also installs Termux's Freedreno Vulkan driver, which Phosh uses for
drawing on Adreno phones.

## First start

Open the app drawer and look under **Desktops** for **Phosh**. One tap opens the **Display**
window and starts Phosh in it; the app grid shows up after a few seconds (the first start is the
slowest). Phosh starts unlocked and has no lock screen.

Inside Phosh:

- the top bar and quick settings sit at the top, the app grid and the overview behind the home bar
  at the bottom; swipe up from it to see them
- every Termux app with a desktop file is in the grid; tap one to open it as a window
- text goes in through Android's keyboard; there is no Phosh on-screen keyboard
- **Mobile Settings** is in the grid and changes Phosh's own options, in four panels: overview,
  top bar, feedback and compositor

What is not there: the lock screen, an on-screen keyboard, calls and SMS, Bluetooth, VPN, location
and the hotspot. Wi-Fi and mobile tiles show state and do not switch anything. See the item page
for why.

## Scale

Phosh works out a scale from the width of the display. If it is wrong for your phone:

1. Open **Mobile Settings**, then the compositor panel, and set **Display scale**. Zero means
   automatic; a number from 1 to 10 sets it.
2. Stop Phosh and start it again.

To try a scale for one start from a terminal, with the Display window already open:

```sh
PHOSH_SCALE=2 phosh-session
```

The environment variable wins over the setting.

## Stop

Close the Display window, or from a terminal:

```sh
phosh-session stop
```

Everything Phosh started ends with it.

## Update, roll back, remove

```sh
tlstore upgrade phosh      # newer Phosh, phoc and Mobile Settings, always together
tlstore rollback phosh     # one version back, and hold it there
tlstore remove phosh       # the item, its Desktops entry and the part it brought
```

Your own settings (what you changed in Mobile Settings, and any dconf values) are kept in your
home directory, so they survive an update or a removal. Termux packages that other things also
need stay.

## When it does not start

- **From a terminal, "open Display in the launcher first".** The display belongs to the launcher
  and a shell cannot open it. Open **Display** first, or use the Phosh entry under Desktops, which
  does it for you.
- **It will not start after phoc crashed.** A crashed compositor can leave its socket and lock
  behind. `phosh-session` clears them itself when no phoc is running; if it still fails, run
  `phosh-session stop` and start again.
- **"Settings schema … is not installed", or Phosh dies at once.** The session script points
  `GSETTINGS_SCHEMA_DIR` and `XDG_DATA_DIRS` at the item's own `share/`. If you start phosh, phoc or
  Mobile Settings by hand instead, those variables are unset and GLib cannot find the schemas;
  start through `phosh-session`, or tap the Desktops entry.
- **The screen is black or slow.** On an Adreno phone Phosh draws with Vulkan; if the driver
  misbehaves, force the CPU renderer for one start: `WLR_RENDERER=pixman phosh-session`. Phoc's
  log says which renderer it chose.
- **Everything is too big or too small.** See Scale.
- **An app does not open.** Apps that only speak X11 run through Xwayland, which comes with the
  Termux packages Phosh installs. Run the app from a terminal inside Phosh to see what it says.
