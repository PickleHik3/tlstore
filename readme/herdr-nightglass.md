# herdr-nightglass

Nightglass is a glass look for the Herdr desktop app: a wallpaper behind everything, see-through
panels and a tint per machine. It comes as two layouts, `nightglass` for a desktop window and
`nightglass-phone` for a phone held upright, with ten colour themes to pick from.

## Using it

The store installs it next to the Herdr app (`herdr-gui`). The next time Herdr starts, the
layouts are in its home (`~/.config/herdr-app`); to put them there now, run:

```sh
herdr-nightglass
```

Then switch to one, with the app open:

```sh
herdr-nightglass phone      # or: herdr-nightglass desktop
```

or press `ctrl-shift-l` in the app and pick it. `herdr-nightglass --help` lists the rest.

## The phone layout

- **Panel button**, the last one in the top bar: opens the panel with your machines, actions and
  spaces with their agents. Picking an agent closes it again.
- **Grip** at the bottom of the panel: a tap switches it between normal and full height.
- **Finished count**, the green button in the top bar: shows the agents that are done as chips;
  tap one to open it, or Clear.
- **Keyboard button**, at the start of the tab row (a red chat bubble while the agent in front
  waits on you): opens a message box that sends to that terminal.
- **Stats rings**: cpu, memory and disk of the machine in front; tap them for the numbers.
- A tab closes with two taps on the x of the active tab.

## Good to know

- Toasts at the top of the terminal and popups that fit a narrow window need the store's build of
  the Herdr app; elsewhere toasts stay bottom right and popups can run past the edge.
- An AI-usage widget is off by default: add `"usage": true` to the top bar's `props` in
  `layouts/nightglass-phone.json`. An update of this item writes its files again, so add it back
  after one.
- It replaces the app's toast mod (`mods/toast`) for every layout. `herdr-nightglass remove` takes
  out only the files it put there; switch to another layout first. Removing the store item
  leaves the copied files in place, so run `herdr-nightglass remove` before
  `tlstore remove herdr-nightglass` if you want them gone.
- It used to be called tokyo-night. Old `tokyo-night` layouts, mods and themes are left where they
  are: delete them from `~/.config/herdr-app` by hand.
- The source is [PickleHik3/herdr-nightglass](https://github.com/PickleHik3/herdr-nightglass).
