# herdr

A terminal workspace for coding agents. Run Claude Code, Codex, opencode or any other agent in
herdr's panes, walk away, and come back to find them still working. A sidebar marks every agent
as working, blocked, done or idle, so the one waiting for an answer is never hard to find.

## What it does

- **Keeps working when you leave.** The panes run in a background server: close the terminal or
  lose the connection and the agents carry on. Run `herdr` again to pick up where you were.
- **Shows which agent needs you.** Every pane is marked working, blocked or idle, across all your
  projects, and herdr says so when an agent stops to ask something.
- **Runs the agents you already use.** It does not wrap or replace them; it owns their terminals.
  The agents in this store work in it as they are.
- **Brings other machines in.** Saved SSH machines sit beside the phone's own work in one window,
  with one combined list of agents.
- **Lets agents drive it.** Agents can open panes, prompt each other and wait on one another
  through herdr's command line and socket API.

## Getting started

Start it in the directory you want to work in:

```sh
herdr
```

The first time, it opens a workspace for you. Start an agent in the pane (`claude`, `codex`,
`opencode`) and herdr picks it up on its own.

Keys start with the prefix, `ctrl+b`, then one more key:

- `ctrl+b` `v` splits to the right, `ctrl+b` `-` splits downwards
- `ctrl+b` `c` opens a tab; `ctrl+b` `n` and `ctrl+b` `p` move to the next and previous one
- `ctrl+b` `w` moves between workspaces; `ctrl+b` `shift+n` starts a new one
- `ctrl+b` `[` is copy mode, to select text with the keyboard
- `ctrl+b` `?` lists every key herdr knows
- `ctrl+b` `q` detaches: you leave, and everything keeps running

To end the session and stop everything in it:

```sh
herdr server stop
```

## Other machines

Add a machine you already reach with `ssh` (it needs `pkg install openssh`), then open herdr on
it from the phone:

```sh
herdr machine add myserver --label server
herdr --remote myserver
```

## Good to know

- Its settings live in `~/.config/herdr/config.toml`; the full list is at
  [herdr.dev/docs/configuration](https://herdr.dev/docs/configuration/).
- Keep it current with `tlstore update`, like everything else from the store. herdr tells you
  when a new version is out; `herdr update` also works, but then the store no longer knows which
  version you have.
- This is herdr's own Linux build, unchanged. Started from an SSH session into the phone, it can
  fail with `unexpected e_type: 2`; run `export TERMUX_EXEC__SYSTEM_LINKER_EXEC__MODE=disable`
  in that session first. In the launcher's own terminal it just runs.
- The full documentation is at [herdr.dev/docs](https://herdr.dev/docs/).
