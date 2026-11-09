# herdr-gui

The Herdr desktop app: your terminals and coding agents in one window, in spaces, tabs and panes,
with a sidebar that lists every agent. Close the window and the terminals keep running; open it
again and everything is where you left it.

## What it does

- **Keeps working when you close it.** The window only arranges terminals. herdr-core (`hc`),
  which the store installs with it, runs them in the background.
- **Shows which agent needs you.** The agents sidebar marks each one working, blocked, done or
  idle, across all your spaces, including workers another agent started.
- **Lets you peek.** Click an agent without a pane and it opens over your tab; keep it as a tab
  if you want it beside your other work.
- **Keeps work in spaces.** A space holds work in one folder, with its own tabs. An unnamed space
  follows its first terminal's folder.

## Opening it

It draws through the GPU, so it needs a graphics driver first. In Termux Launcher, open
Settings > Linux apps > Graphics acceleration and run the benchmark once; Herdr then uses the
driver it sets up. After that, open **Herdr** from the app drawer, or run it from a terminal:

```sh
herdr-app
```

On stock Termux it needs a driver and an X server. Install the Termux:X11 app first, then:

```sh
pkg install mesa-vulkan-icd-freedreno   # an Adreno GPU; on any other: pkg install vulkan-icd
pkg install termux-x11-nightly
termux-x11 :0 &
DISPLAY=:0 herdr-app
```

and switch to the Termux:X11 app to see the window.

## Good to know

- It needs Android 10 or newer. Started without a graphics driver, it says how to get one
  instead of opening.
- Keep it current with `tlstore upgrade herdr-gui`, like everything else from the store. The app's
  own updater and core installer are switched off here: the store installs and updates both.
- It is separate from the store's `herdr` item, the terminal version. They run on different
  cores, so install either or both.
- The store builds it for Android from upstream's source, with changes so it runs there.
- The full documentation is at [herdr.dev](https://herdr.dev/).
