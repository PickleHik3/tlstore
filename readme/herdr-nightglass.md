# herdr-nightglass

Nightglass is a glass look for the Herdr desktop app: a wallpaper behind everything, see-through
panels and a tint per machine. It comes as two layouts, `nightglass` for a desktop window and
`nightglass-phone`, an inbox of your agents, for a phone held upright, with ten colour themes to
pick from.

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

## The desktop layout

- **Sidebar**: every machine as a tile (its icon on its colour), each machine's spaces and agents
  below, cpu, memory and disk bars at the bottom.
- **Needs you bar**: under the tabs, one chip per agent that waits or finished; click one to open
  it. It keeps one height, so the terminal never jumps.
- **Board**: the Board pill before the tabs shows every agent in four columns, Needs you, Working,
  Done and Idle, with the question each waiting agent asks. A tab takes you back.

## The phone layout

It opens on an inbox of the agents that need you.

- **Header**: usage pills, a search button and a `+` button. `+` offers a new space, terminal,
  files, changes, settings and one chip per agent you have installed.
- **Machine tiles**: tap one to show only that machine, All machines for everything. Tap the
  selected one again to pick its colour. Each shows cpu, memory and disk rings.
- **Needs you / All agents**: two tabs with counts. Needs you lists agents that wait or finished.
- **Cards**: answer a permission prompt with Yes, Always or No, or a question with one tap on an
  option. Open shows that terminal full height; Dismiss clears a finished one.
- **Open**: the terminal with a message box under it that sends to that terminal, and Files and
  Changes buttons in the bar. Inbox goes back.

## Good to know

- Toasts at the top of the terminal need the store's build of the Herdr app; elsewhere toasts stay
  bottom right.
- An AI-usage widget is off by default. Add `"usage": "<machine>"` to the props of the sidebar
  block in `layouts/nightglass.json`, or of the `inbox` block in `layouts/nightglass-phone.json`,
  naming the machine that has `ai-usage-tui`. An update of this item writes its files again, so
  add it back after one.
- The layouts no longer replace Herdr's own toast mod: they use their own, `mods/nightglass-toast`.
  An edited copy of the old one that Herdr moved to `mods/toast-edited` is deleted by
  `herdr-nightglass` when it is unchanged.
- `herdr-nightglass remove` takes out only the files it put there; switch to another layout first.
  Removing the store item leaves the copied files in place, so run `herdr-nightglass remove`
  before `tlstore remove herdr-nightglass` if you want them gone.
- It used to be called tokyo-night. Old `tokyo-night` layouts, mods and themes are left where they
  are: delete them from `~/.config/herdr-app` by hand.
- The source is [PickleHik3/herdr-nightglass](https://github.com/PickleHik3/herdr-nightglass).
