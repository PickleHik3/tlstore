---
status: proposed
date: 2026-10-28
---

# A failed job says why, in the store and in a transcript

A person on an Infinix Hot 10 Play (Android 11) saw only "Could not install opencode. Try again
later." in the store. The terminal run showed the cause at once: pacman refused `pcre2` and
`ripgrep` because files no package owned were already in the prefix, so the one package
transaction aborted, `patchelf` never arrived, and opencode was dropped for want of ripgrep.

None of that reached the store. The engine's `err()` writes to stderr, which the TUI discards
(`ui/src/store/proc.rs`); only the `--progress` stream on stdout arrives, and its row reasons
("needs ripgrep, which did not install") vanish when the Installing screen swaps its rows for a
summary that names only the requested items (`ui/src/store/mod.rs`, `summary()`). The package
manager's transcript sits in `~/.cache/tlstore/last-update.log`, which the store never mentions.

Decided 2026-10-28 (grilled, confirmed):

## Engine

- Under `--progress`, every `err()` not scoped to a row also prints an `error` line on stdout.
  Row-scoped errors keep travelling in the row's `done` line. This covers a refused plan before
  any row starts as well as apply-phase failures (build tools, the package manager, a fetch).
- A job transcript, `~/.cache/tlstore/last-job.log`, is truncated at the start of each
  `--progress` run and holds the say/err sentences and the package manager's output in order, as
  a terminal run shows them: no curl percent frames, no status-line redraws. Capped at 256 KB,
  the tail kept behind an "earlier lines dropped" marker. `last-update.log` stays as it is.
  Terminal runs write no transcript; they show it.
- Five package-manager failures get a plain sentence in place of "the package manager could not
  install X": a pacman file conflict (names the files), a locked database, a mirror unreachable
  or 404, out of space, no network. Everything else keeps today's wording.
- Tell only. The pacman conflict case puts its command (`pacman -S --overwrite '*' <packages>`)
  in the transcript under "To fix:"; the engine does not retry with `--overwrite` and does not
  ask. (Rejected: a retry limited to the named paths, and a question through the stream.)

## TUI

- Installing, running: an `error` line replaces the dim `then …` row under the window as it
  arrives, in failed ink, and stays into the done screen.
- Installing, done: the failed rows with their reasons (wrapped), then the job-level error
  lines, then one dim fold line "N ready". A job with no failure looks as today. A cancelled job
  keeps its single "Stopped before … was done." sentence and the rows fold away.
- Front notice: "Could not install opencode: <reason>", the job-level error preferred over a
  "needs X, which did not install" chain. It may take two lines, growing upward into the body's
  last row while it shows; one-line notices leave the grid as it is. It clears on the next key
  or tap as today.
- `d details`, offered only after a failed job, on the done screen and beside the failure
  notice: the transcript in the readme pager. `c copy` there puts the "To fix:" command on the
  clipboard (`termux-clipboard-set`, else OSC 52).
- Refresh, catalog, GitHub and self-update notices are untouched.

## Shipping

Engine and TUI ship in one release. The TUI ignores stream lines it does not know, so an older
store with a newer engine loses nothing. CONTRACT.md (the stream, the Installing screen, the keys)
and SPEC.md (`--progress`, the transcript) are updated with the change.
