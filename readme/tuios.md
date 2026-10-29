# tuios

A window manager for the terminal that knows what your coding agents are doing. Tile several
terminal panes in one window, run Claude Code, Codex, opencode or any other agent in them, and
tuios marks each one as working, waiting for you, done or errored, so the one that needs an answer
is never hard to find.

## What it does

- **Tiles your terminals.** New panes split the screen on their own, in workspaces you can switch
  between, with a command palette for everything else.
- **Shows what every agent is doing.** A sidebar lists your sessions, terminals and agents, with
  the state of each. Agents report in through `tuios integration install`, and tuios also
  recognises many of them by what they run and show.
- **Keeps sessions alive.** A background server holds your panes: detach, close the terminal and
  come back to the same session later.
- **Gathers what agents wait on.** Approvals, questions and errors from every agent go to one
  inbox, where you can read an agent's changes and send notes back to it.
- **Brings other machines in.** Sessions on machines you reach by `ssh` open from the same window.

## Getting started

```sh
tuios
```

It starts in Window Management mode, where each key is a command:

- `n` opens a new pane; `i` or `Enter` types into the focused one
- `ctrl+p` opens the command palette, which searches every action
- `z` zooms the focused pane
- `ctrl+b` is the prefix: `ctrl+b` `esc` goes back to Window Management mode, `ctrl+b` `d`
  detaches and leaves everything running, `ctrl+b` `?` lists every key, `ctrl+b` `q` quits

To keep a named session you can come back to:

```sh
tuios new work
tuios attach work
```

`tuios --show-keys` shows the keys you press on screen while you learn them.

## CPU and RAM in the dock

tuios leaves both meters off until you turn them on: switch on "CPU meter" and "RAM meter" in the
settings page (`ctrl+b` `,`), or add this to `~/.config/tuios/config.toml`:

```toml
[appearance]
show_cpu = true
show_ram = true
```

The RAM meter then works as it is. Android keeps `/proc/stat` from apps, so the CPU meter reads it
through the launcher instead, and shows `CPU: n/a` without that. In Termux Launcher it needs
Shizuku running and permission granted to Termux:Launcher; the store installs a small helper,
`tuios-cpu`, for this alongside tuios. It is started when the CPU meter first needs it and stops
when tuios does. In plain Termux there is no helper, and the meter stays `n/a`.

## Good to know

- Keep it current with `tlstore upgrade tuios`, like everything else from the store. The store
  builds tuios for Android from upstream's source. `tuios update` is not for this copy: it would
  fetch upstream's Linux build, which Android stops on some phones and tablets, so it refuses and
  says it does not know where this build came from.
- It needs a terminal with true colour, as the launcher's terminal is.
- Its settings live in `~/.config/tuios/config.toml`; press `ctrl+b` `,` for a settings page, and
  `tuios keybinds list` shows every key.
- The full documentation is at [tuios.dev](https://tuios.dev).
