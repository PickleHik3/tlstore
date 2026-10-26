---
status: accepted
date: 2026-10-26
---

# The Phosh session file is a `file` part with a `$PREFIX` target

The launcher lists whole desktops under Desktops from `$PREFIX/share/xsessions` and
`$PREFIX/local/share/xsessions` only (`ProotDistro.sessionDirs()`). The `phosh` archive unpacks
under `~/.local/lib/phosh`, so `phosh.desktop` needs one more step to land in
`$PREFIX/local/share/xsessions` ([PHOSH.md](../PHOSH.md), open question 1).

Decided: a hidden `file` part, `phosh-session-file`, that `phosh` requires, with the target
`$PREFIX/local/share/xsessions/phosh.desktop`. The engine's `expand_path` (and the snapshot's
awk copy of it) now takes a leading `$PREFIX` the way it takes `~`; nothing else changed.

Why not the archive's `post=`:

- The engine has no `post=` today. Adding one means running a script from a download at install,
  update, rollback and remove, with its own failure and undo rules; a `file` part already has
  all four, and the engine's tests for them.
- A `file` part is recorded in the state and shown by `doctor`, so a removed or edited session
  file is seen and put back. A script's side effect is invisible to both.
- The file is data (a `.desktop`), kept in this repository
  (`recipes/cross/phosh-session.desktop`) and digested in `SHA256SUMS` like any pinned file.

Cost: an engine from before this change would take `$PREFIX` for a directory name. The part
carries `min-launcher=` as `phosh` does, and the launcher installs its own engine on every start,
so a launcher new enough to be offered Phosh has an engine that knows `$PREFIX`.

The compiled schemas are not a `post=` job either: the archive ships `gschemas.compiled`, and
`phosh-session` points `GSETTINGS_SCHEMA_DIR` at it.
