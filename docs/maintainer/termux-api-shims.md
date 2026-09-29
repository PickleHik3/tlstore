# termux-api-shims

The catalog item that gives termux-launcher the Termux:API commands without the Termux:API
companion app. Decision (2026-09-29): unify it at tlstore — the shims ship through the store, not
inside the launcher APK.

## What it is

Eleven POSIX `sh` scripts in `shims/termux-api/`, each a thin wrapper over the launcher's
`launcherctl` CLI (which the app installs into `$PREFIX/bin` and which talks HTTP to the app with
the token in `~/.launcherctl`). Each header names the upstream script it mirrors, in
`termux/termux-api-package`, `scripts/<name>.in`.

| shim | launcherctl | supported | accepted and ignored, with a warning | notes |
|---|---|---|---|---|
| `termux-clipboard-get` | `clipboard paste` | (none) | | plain text, no JSON, no newline added; needs the launcher on screen |
| `termux-clipboard-set` | `clipboard copy` | text as arguments or stdin | | |
| `termux-notification` | `notify` | `-t/--title`, `-c/--content` (else stdin), `-i/--id`, `--priority` (min/low to low, default to normal, high/max to critical); also `--opt=value` and `-tVALUE` | `--action`, `--alert-once`, `--button1..3`, `--button1..3-action`, `--channel`, `--group`, `--icon`, `--image-path`, `--led-color/-on/-off`, `--media-*`, `--on-delete`, `--ongoing`, `--sound`, `--type` (other than `default`), `--vibrate` | an unknown option fails, as upstream's getopt does; `--help-actions` prints the usage |
| `termux-notification-remove` | `notify --close ID` | `ID` | | |
| `termux-notification-list` | `notifications active --json` | (none) | | JSON array: `id`, `tag` (both from the key), `key`, `group` (always `""`), `packageName`, `title`, `content`, `when` (`YYYY-MM-DD HH:MM:SS` local). Only apps enabled in the launcher's notification history settings are listed |
| `termux-toast` | `toast` | `-s`, text as arguments or stdin | `-g`, `-b`, `-c` | |
| `termux-vibrate` | `vibrate` | `-d MS`, `-f` | | |
| `termux-torch` | `torch` | `on`, `off` | | |
| `termux-battery-status` | `battery` | (none) | | upstream's object and field order, two-space indent |
| `termux-volume` | `volume` | no arguments (list), `STREAM VOLUME` (set) | | list is a top-level JSON array (`streams` unwrapped) |
| `termux-wallpaper` | `wallpaper set FILE --home\|--lock` | `-f FILE`, `-l`, `-u URL` (needs curl, else it says so and stops) | | **needs a launcher build newer than 2026-09-29's dev**, the one that adds `launcherctl wallpaper`; an older one gets "update the app" |

A missing `launcherctl`, or an API that is not up (the app not started, no token), makes every
shim exit 1 with `<name>: launcherctl not found; ...` or `<name>: launcherctl <cmd> failed: <what
launcherctl said>`. Nothing is written to stdout on failure. On success the setters print nothing,
as upstream's do.

The JSON reshaping (battery, volume, notification-list) and the clipboard decoding are done in
`awk`, so nothing needs `jq`. They assume launcherctl's flat objects; a shape change on the
launcher side (a nested value inside a notification row, say) needs the shims looked at.

## How it installs

Nothing new in the engine's install path: each shim is a hidden `file` item
(`termux-api-shim-<command>`, `mode=755`, target `~/.local/bin/<command>`), the source is
`binaries:shims/termux-api/<command>@<ref>` (a path in this repository, digest from `SHA256SUMS`),
and the visible item `termux-api-shims` is a `bundle` of them. `tlstore remove termux-api-shims`
removes the whole set; `update` refreshes a shim whose file moved on and, as for any `file` item,
asks before replacing one the user edited.

They land in `~/.local/bin`, not `$PREFIX/bin`: that is where tlstore puts everything (see
`docs/user/Tlstore.md`, "Where things go"), so a bootstrap reinstall does not take them away.
tlstore's `doctor` checks that `~/.local/bin` is found before Termux's own `bin`.

### Conflict with the real Termux:API

The apt package `termux-api` owns the same names in `$PREFIX/bin`. Nothing would be overwritten,
but the shims would silently shadow the real commands. So this is the one thing the engine gained
(tlstore 0.8): the `conflicts=` option (`docs/SPEC.md`, Revision 10). The bundle and each part
carry `conflicts=termux-api`, and `tlstore install termux-api-shims` while the package is
installed stops before asking or fetching anything:

    termux-api-shims cannot be installed while the termux-api package is: both provide the same
    commands. Remove it first (pkg uninstall termux-api), then install termux-api-shims again.

An engine older than 0.8 ignores the option. If the package is installed afterwards, nothing
notices; `~/.local/bin` wins on PATH, and `tlstore remove termux-api-shims` restores the real ones.

## Releasing it

The rows and the files must reach a tag together, because a `binaries:` path source is fetched
from `raw.githubusercontent.com/PickleHik3/tlstore/<ref>/<path>`:

1. The shim files, `readme/termux-api-shims.md` and their `SHA256SUMS` lines are on `main` (merge
   the branch). Any change to a shim changes its digest: re-record the line with
   `sha256sum shims/termux-api/<name>` and update every item row's `<ref>`.
2. The `items.tsv` rows pin `<ref>`. Today that is the commit that added the files; a tag cut
   from a later commit is better, so once the release tag is known, point the rows at it (the
   `binaries:` sources and the `readme`) and rebuild.
3. `scripts/test.sh` must end `failed 0`.
4. `scripts/release.sh <tag> --prepare` (builds the engine copy and `dist/catalog.tsv`; the engine
   has moved to 0.8, and `tlstore-ui` needs no rebuild for this).
5. The developer runs `bash scripts/sign.sh` (passphrase), then `scripts/release.sh <tag>`, commits
   `dist/` and `SHA256SUMS`, tags and pushes; or `gh workflow run release.yml`, which does the
   same on a runner.
6. `termux-wallpaper` only works once a launcher build with `launcherctl wallpaper` is out; the
   store item can ship before it, and the shim says so until then.

Editing a shim later: change the file, update its `SHA256SUMS` line, point its row's `<ref>` at the
new tag **and change its version column** (the first 8 characters of the ref, like the launcher's
`file` items): `update` and `install` compare versions, not digests, so a row whose version did
not move is "already installed". Release as above.
