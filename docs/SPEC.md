# tlstore — the launcher's tool store

`tlstore` (aliases `tl`, `tls`) is a small package-manager-style CLI shipped inside the launcher
APK. It installs, lists, updates and removes the tools and configs the launcher shows off but does
not ship: the showcase binaries from `PickleHik3/tlstore`, the opinionated shell
configs from `docs/en/examples`, apt/pacman packages, and Claude Code. It replaces the interactive
`setup-launcher` script (which stays, but points here).

Written 2026-09-06. Decisions here are settled; raise, do not silently change.

## Shape

- One POSIX `sh` program, `app/src/main/assets/tlstore/tlstore`, no bash-isms (Termux `sh` is dash).
  Runtime needs only the bootstrap: `curl`, `tar`, `sha256sum`, `sha512sum`, `base64`, `od`, `sed`,
  `awk`. Optional: `fzf` (picker), `patchelf` (npm-musl), `minisign` (catalog refresh).
- The app writes it on every start (`TlstoreInstaller`, modelled on `app/x11/X11CliInstaller`):
  `$PREFIX/bin/tlstore`, symlinks `$PREFIX/bin/tl` and `$PREFIX/bin/tls`,
  `$PREFIX/libexec/termux-launcher/tlstore/{catalog.tsv,trusted.pub,.installed}`. Marker comment
  `# written by termux-launcher` in the script's first lines; a foreign `tlstore`/`tl`/`tls` is left
  alone and reported, never overwritten.
- User state: `~/.local/share/tlstore/installed.tsv` (what tlstore installed, with files),
  `~/.local/share/tlstore/catalog.tsv` (verified refreshed catalog, optional),
  `~/.cache/tlstore/` (downloads). Payloads go to `~/.local/bin/<name>` and `~/.local/lib/<name>/`,
  never `$PREFIX/bin` (a bootstrap reinstall wipes it; apt owns names there). Replaced user files
  get a timestamped `.bak` beside them, as setup-launcher does today.
- Edition/prefix is read from `$PREFIX` (`/data/data/<app package>/files/usr`); env override
  `TLSTORE_PREFIX` for tests on a Linux host.

## Catalog

Tab-separated, UTF-8, `#` comment lines, one header comment carrying the serial:

```
# tlstore catalog	serial=2026090601
# name	kind	version	prefixes	source	digest	target	requires	options	summary
```

Columns:

| column | meaning |
|---|---|
| `name` | `[a-z0-9][a-z0-9-]*`, unique per prefix set |
| `kind` | `pkg` \| `binary` \| `file` \| `file-once` \| `script` \| `npm-musl` \| `npm-android` \| `bundle` |
| `version` | `-` for pkg/bundle; upstream version for binary/file/script; `latest` or pinned for npm-musl |
| `prefixes` | `*` or comma list of app packages (`com.termux`, `io.vaj.tl`, `com.termux.launcher.nix`) |
| `source` | `pkg`: space-separated package names. `binary`/`file`/`file-once`/`script`: a URL, or `binaries:<asset>@<tag>` (→ `https://github.com/PickleHik3/tlstore/releases/download/<tag>/<asset>-aarch64`, a release asset; with a slash in the asset, `binaries:<path>@<tag>` → `https://raw.githubusercontent.com/PickleHik3/tlstore/<tag>/<path>`, a file in the repository) or `launcher:<path>@<tag>` (→ `https://raw.githubusercontent.com/PickleHik3/termux-launcher/<tag>/<path>`). `npm-musl`: `npm:<package>#<executable inside package/>`. `bundle`: `-` |
| `digest` | sha256 hex of the downloaded file; `-` for pkg, bundle, npm-musl (npm's registry sha512 is the check) |
| `target` | install path with `~`; `-` = default (`~/.local/bin/<name>` for binary, `~/.local/lib/tlstore/priv/<name>` for a binary with `priv=shizuku`, `~/.local/lib/<name>` for npm-musl, none for others) |
| `requires` | comma list of catalog names installed first; bundle members live here |
| `options` | `;`-separated `key=value`: `env=K=V` (wrapper exports, repeatable with `,`), `tz=1` (wrapper exports TZ from `persist.sys.timezone`), `mode=755`, `post=<catalog script name>`, `priv=shizuku` (binary only; Revision 5 below) |
| `summary` | one plain sentence, product copy |

Rules: one row per (name, prefix set) — per-edition builds are separate rows with their own
digest (fastfetch, musl-loader). tlstore uses the first row whose `prefixes` matches. Items whose
kind needs aarch64 (`binary`, `npm-musl`) are hidden on other CPUs.

Generated, never hand-edited: `scripts/tlstore/build-catalog.sh` reads `docs/en/examples/*`
(digests), the checked-out binaries repo (`PickleHik3/tlstore`) `SHA256SUMS` (path argument), the item
definitions in `scripts/tlstore/items.tsv` (hand-maintained: everything but digests), and writes
`app/src/main/assets/tlstore/catalog.tsv` with `serial=YYYYMMDDNN`.

Initial items: `fish`, `oh-my-posh`, `zoxide`, `eza`, `neovim`, `build-tools` (pkg); `config-fish`
(file), `personal-fish` (file-once), `omp-theme` (file), `setup-nvim` (script); `sigye`, `kitten`,
`fastfetch` ×2 rows, `musl-loader` ×2 rows (binary); `claude-code` (npm-musl, requires
`musl-loader,patchelf`; options `env=DISABLE_AUTOUPDATER=1;tz=1`); `patchelf` (pkg); bundles
`shell-setup` (fish, oh-my-posh, zoxide, eza, config-fish, omp-theme, personal-fish), `dev-tools`
(build-tools, neovim, setup-nvim), `showcase` (sigye, fastfetch, kitten).

### Trust

- Baseline catalog = the one in the APK. Payload digests come from it; `pkg` goes through apt/pacman;
  `npm-musl` verifies the registry's `dist.integrity` sha512 over TLS.
- Refresh: `https://github.com/PickleHik3/tlstore/releases/latest/download/catalog.tsv`
  and `catalog.tsv.minisig` (the assets of the store's latest GitHub Release; Revision 8 — before
  that, the raw `dist/catalog.tsv` on `main`), verified with
  `minisign -V -p $PREFIX/libexec/termux-launcher/tlstore/trusted.pub`.
  Accepted only when its serial is newer than the active one. No `minisign` → offer `pkg install
  minisign`; still none → refresh is off and the baseline is used, said in one line.
  `TLSTORE_CATALOG_URL` overrides the URL (tests use `file://`).
- The signing key lives with the maintainer (`~/.config/vaj-apt/tlstore-minisign.key`), never in
  a repo or an agent worktree. `scripts/tlstore/sign.sh` signs; the orchestrator runs it.

## Commands

```
tlstore                       the store in the launcher, else the list
tlstore list [-i|-a]          everything (installed marked), or installed only / available only
tlstore search <term>         name and summary match
tlstore info <name>           version, kind, source, digest, requires, files, summary
tlstore install [name...] [-y] [--dry-run]   no names → multi-select picker (fzf --multi, else numbered toggles)
tlstore remove <name...> [-y] [--dry-run]
tlstore update [name...] [--check|--dry-run] [--offline]   refresh catalog, then upgrade what is newer (--check changes nothing)
tlstore refresh               catalog only
tlstore self-update [--check] tlstore itself
tlstore help [command]        the command list, or one command's options (also: <command> -h)
tlstore doctor                prefix, PATH order, tools present, catalog serial, drift, loader check
tlstore version
```

Global `-y`/`--yes`, `-h`, `-v` go before the command. Strict arguments: `doctor`, `version`,
`refresh` and `self-update` reject stray words (exit 2). `tlstore shell` was removed and says
`install fish-shell`. Exit codes 0/1/2 (ok / failed / usage). `TLSTORE_ASSUME_YES=1` = `-y` everywhere. Output is plain
text, one line per action, product copy (no mechanism talk); errors start with `tlstore: `.
`update` for `pkg` items runs the package manager's own upgrade for exactly those names
(`apt install --only-upgrade` / `pacman -S --needed`).

## Build plan

| phase | branch | deliverable | model | depends on |
|---|---|---|---|---|
| P1 | `feat/tlstore-cli` | `app/src/main/assets/tlstore/tlstore`; `scripts/tlstore/{items.tsv,build-catalog.sh,test.sh}`; generated `catalog.tsv`; tests green under `sh`/`dash`/`busybox sh` on a Linux host with `file://` fixtures | opus | — |
| P2 | `feat/tlstore-installer` | `app/src/main/java/com/termux/app/store/TlstoreInstaller.java`, hook in `TermuxActivity` beside the X11 installer call, `TlstoreInstallerTest`; assets read by name only | sonnet | — |
| P3 | `feat/tlstore-docs` | `docs/en/Tlstore.md`, README section replacing the `setup-launcher` curl instructions, `setup-launcher` header pointing to tlstore, release-notes line | sonnet | P1 |
| P4 | orchestrator | minisign key, `trusted.pub` asset, `sign.sh` (named `sign-catalog.sh` at the time), signed catalog on `dev`; queue `minisign` for the VAJ apt repo | — | P1 |
| gate | — | debug APK on the emulator: tlstore written, `tlstore list/doctor` run; then pong by the developer | — | P1, P2 |

## As built (2026-09-06)

Deviations from the text above, all deliberate: an `args=` option passes arguments to a `script`
item (`setup-nvim`); a `fastfetch-libs` pkg item carries fastfetch's runtime libraries and both
fastfetch rows require it; the `npm-musl` wrapper is named after the executable in the source
(`claude`), its directory after the item; `musl-loader` targets `~/.local/lib/musl/` and the
npm-musl install copies it from there; `claude-code` is limited to the editions with a loader;
`update --check` asks the npm registry what a `latest`-pinned item's dist-tag points at and names it only when that differs from what is installed (offline or unreachable: not named); a refused refresh exits 1;
`remove` on a pkg item only stops tracking it; a bundle member with no row on this device is
skipped with a line; the picker lists only what is not installed; the CLI reads two test knobs,
`TLSTORE_ARCH` and `TLSTORE_PATCHELF`. The app installer stamps the marker with the app's
versionName as well, so every release rewrites the files.

Verified 2026-09-06 on the x86_64 emulator (debug build): the app writes `tlstore`, `tl`, `tls`,
the catalog and key; list, info, doctor, a real apt install, update, a failed refresh, the picker
and remove behave. Not yet run on a device: binary, npm-musl and refresh against the published
catalog (the binaries tag `2026.09.06` and the catalog on `main` are not pushed yet).

Side queue: publish `minisign` in the VAJ apt repo (needs the build VM).

## Revision 2 (2026-09-06)

The developer tried the store and asked for a much smaller catalog and stricter handling of config
files. What follows supersedes the item list and the `script` kind above.

### Seven visible items

`list`, `search` and the picker show exactly `claude-code`, `fastfetch`, `fish-shell`, `kitten`,
`nvim-theme`, `omp-theme`, `sigye`, alphabetically. Everything else carries `hidden=1` in `options`:
it is a part another item pulls in through `requires`, never listed, never searched, never offered
in the picker, and `install <hidden name>` is refused with "that is part of another item". `info` on
a hidden name still works, because names appear in `Needs` lines.

Gone: `neovim`, `build-tools`, `dev-tools`, `shell-setup`, `showcase`, `setup-nvim`, and the
standalone `patchelf` pkg item. `config-fish` and `personal-fish` became hidden parts of
`fish-shell`. `tlstore shell` was `install fish-shell`, and is now an error that says so.

`list` drops the `installed`/`-` column for a leading `*`, and prints
`needs while installing: <tools>` indented under an item that declares `build=`.

### New kinds and options

| addition | meaning |
|---|---|
| `hidden=1` | a part, not a choice (above) |
| `build=<pkgs>` | packages needed only while installing |
| kind `fisher` | `source` is a space-separated plugin list; install runs `fish -c 'fisher install …'`, remove the matching `fisher remove`, version `-`, and `update` leaves it alone — fisher updates are the user's (`fisher update`) |

Removed with them: kind `script` and its `args=` and `post=` options, which only `setup-nvim` used.
The dependency sort now reasons about `requires` alone.

### Config files are never replaced silently

For a `file` item (not `file-once`, not a binary) whose destination exists and differs, tlstore
downloads the new file to the cache, prints the item name, shows `diff -u` (a before/after of the
first 25 lines each where `diff` is missing) and asks `Replace your <basename>? [y/N]`. **`-y` and
`TLSTORE_ASSUME_YES` do not answer this question** — only the new `--configs` flag on `install` and
`update` does. With no tty and no `--configs` the file is kept and one line says so.

Either answer records the item at the catalog version, so declining is not asked again until the
shipped file itself moves; `update --check` reports those as
`<name> has a new version; update shows the change and asks`. Replacing still leaves the timestamped
`.bak`.

### Build tools

Before installing, tlstore notes which `build=` packages are missing (`pacman -Q`, else `dpkg -s`,
else "is the command there") and installs them. When the plan finishes it asks
`Remove the tools that were only needed for installing (<pkgs>)? [y/N]`, and on yes removes exactly
those (`pacman -R --noconfirm` / `apt remove -y`) and clears `~/.cache/tlstore`. `-y` may answer
this one. `info` shows a `Builds with` line. Only `claude-code` declares one, `patchelf`.

### `nvim-theme`

`docs/en/examples/nvim/lua/launcher/material_palette.lua` (lifted out of `setup-nvim` unchanged) and
`docs/en/examples/nvim/colors/launcher-material.lua` (a real colorscheme that paints the standard
groups, the `@` treesitter captures, diagnostics and git/diff groups from the palette's base16 and
base30 tables, keeps the glass default and falls back to a fixed dark palette when the launcher has
never written wallpaper colours). Both are hidden `file` items required by the visible `nvim-theme`
bundle; Neovim itself is not installed. The colorscheme overrides the palette module's `reload` so a
wallpaper change re-applies it rather than base46's, which only NvChad has.

Enabling it in each config — plain, lazy.nvim/LazyVim, AstroNvim, NvChad — is in `docs/en/Tlstore.md`
rather than the item summary, which stays one sentence.

### `tlstore display`

Runs `$PREFIX/bin/termux-x11-gpu-setup` (installed by the app) with whatever arguments it is given,
and says the app needs updating when the file is not there.

### Pinning

A file in this repository is pinned to a tag when it has not changed since one, otherwise to the
commit that added it (`launcher:<path>@<sha>`). `build-catalog.sh` now also hashes a plain `http(s)`
source by downloading it once, so `fisher` and the fastfetch logo GIF are pinned like everything
else; such a URL must name a tag or commit, never a branch.

### As built

`catalog.tsv` is regenerated at serial 2026090603 and **unsigned** — `catalog.tsv.minisig` was
deleted rather than left describing a file it no longer matches. The maintainer signs the new one
before it ships.

The test suite reads one more documented knob, `TLSTORE_ASSUME_TTY`, because it has no pty to answer
the two questions that are only asked of a person. 512 checks green under `sh`, `dash`, `busybox sh`
and `bash --posix`; `shellcheck -s sh` clean. The colorscheme was checked with `nvim --headless`
0.12, with a wallpaper palette and without one.

`docs/en/examples/fastfetch.jsonc` still names `/data/data/com.termux/files/home/Pictures/gif/skel.gif`
outright, so on the VAJ edition the logo path does not resolve. Left alone here: changing it would
need its own commit and a new pin, and fastfetch's handling of `~` in a logo source is not something
this phase verified.

**2026-09-06**: `docs/en/examples/setup-launcher`, `docs/en/examples/setup-nvim` and
`docs/en/examples/update-setup-launcher-digests.sh` — the scripts this store replaces — were
removed, along with every reference to them (P7).

## Revision 3 (2026-09-21) — hosts, a machine-readable face, a browser, upstream Termux

The developer wants to keep adding terminal tools (the fastfetch GIF patch is the model: special
work to run in Termux), a Pacsea-like browser, and the store on official Termux too. Decided
2026-09-21 without a review page ("not much for me to review, proceed"): TSV contract + fzf browser,
not a compiled TUI; CI signing is a later round.

### Hosts

Three environments run the store. `prefixes` already tells editions apart by `$PREFIX`; it cannot
tell the launcher built as `com.termux` from official Termux, which share a prefix. A second
dimension, the **host**:

| host | how tlstore knows | items that differ |
|---|---|---|
| `launcher` | `TERM_PROGRAM=termux-launcher`; when `TERM_PROGRAM` is unset (ssh), `$STORE_DIR/.installed` exists (the app writes it on every start, nothing else does) | everything |
| `termux` | `TERM_PROGRAM` set to anything else, or unset with no `.installed` | `fastfetch` is out (the GIF logo needs the launcher's kitty graphics); `sigye`, `claude-code`, `kitten`, `fish-shell` stay |

`TLSTORE_HOST=launcher|termux` overrides detection (tests, and a user who knows better). The nix
edition is out of scope: no apt/pacman, and nothing here targets it.

Catalog: new `options` key `host=<comma list of launcher|termux>`; absent means every host. A row
whose host does not match is filtered in `rows()` exactly like the arch filter — never listed,
searched, browsed or installable, `info` says "not in the list". Optional `min-launcher=X.Y.Z`
compares against `TERM_PROGRAM_VERSION` (the launcher's versionName) and passes when that is unset.
`items.tsv`: both `fastfetch` rows gain `host=launcher`. `doctor` prints an `App` line:
`Termux Launcher 0.2.40 (com.termux)` or `Termux (com.termux)`.

### TSV contract (`--tsv` on list, search, info, update --check)

Tab-separated, no header, no colour, stable column order; product copy stays in `summary` only.

```
list   --tsv [-i|-a]    name  state  version  installed  kind  summary      state: installed|available
search --tsv <query>    same columns as list
info   --tsv <name>     key  value   one row per line info prints (Kind, Version, From, Checksum,
                                     Needs, Builds with, Files, Installed, Summary)
update --check --tsv    name  installed  available  note   note: "" | config-asks | latest (available is then the resolved version)
```

Nothing else changes shape. The browser and any later front end read only these.

### `tlstore browse`

`tlstore browse` (and plain `tlstore` on a tty when fzf is present; otherwise usage as today) is
the Pacsea-shaped view built on fzf: the item list on top with `*` for installed, `tlstore info` as
the preview pane, a header line naming the keys. Portrait phones are ~45 columns: preview goes
`down` when `COLUMNS` < 80, `right` otherwise. Keys: Tab marks, Enter installs the marked items
(or the current one), Ctrl-R removes the current item, Ctrl-U updates everything, Ctrl-F refreshes
the list, ? shows the keys, Esc leaves. Actions run outside fzf (its `--expect` returns the key
and the selection; tlstore runs the plan in the terminal so prompts work, waits for Enter, reopens
the view). Without fzf: offer to install it through the package manager as `refresh` does for
minisign; declined → the numbered picker from `install`. Marked items that are already installed
are skipped with one line. `motd.sh` points at `tlstore browse`.

### Standalone install on official Termux

`scripts/tlstore/install.sh`, run as
`curl -fsSL https://raw.githubusercontent.com/PickleHik3/termux-launcher/main/scripts/tlstore/install.sh | sh`.
It refuses outside a Termux prefix (`$PREFIX` under `/data/data/*/files/usr`) and on non-aarch64
says so but continues (pkg items still work). Steps: `pkg install -y minisign` (asks first unless
`-y`/`TLSTORE_ASSUME_YES`); fetch `trusted.pub`, `tlstore` + `tlstore.minisig`, `catalog.tsv` +
`.minisig` from `$TLSTORE_RAW_BASE` (default the raw `main` URL above); verify both signatures
against the fetched key (TLS + GitHub is the trust root, the same as any curl-pipe installer) and
stop on any failure; write `$PREFIX/bin/tlstore` (keeps the `# written by termux-launcher` marker
so the app takes the file over if the launcher is installed later), symlinks `tl`/`tls` only when
those names are free, `$STORE_DIR/{catalog.tsv,trusted.pub}` and `$STORE_DIR/.standalone`
containing the raw base URL. When the launcher is already there (`TERM_PROGRAM=termux-launcher` or
`.installed` present) it says so and changes nothing; a `tlstore` it did not write is refused unless
`-y`. Ends with the doctor line and
`tlstore browse`'s name.

Self-update (as first designed here; Revision 8 changes it): on a standalone install
(`.standalone` present, `.installed` absent) `tlstore update`
also fetches `tlstore` + `.minisig` from the recorded base, verifies, and replaces itself when the
`TLSTORE_VERSION` line is newer — after the item work, and it re-executes nothing. On the launcher
the app rewrites the script, so self-update is skipped. `sign-catalog.sh` becomes `sign.sh`:
signs the catalog and the script (`tlstore.minisig`, trusted comment `tlstore <version>`).
Tests point `TLSTORE_RAW_BASE` at a `file://` tree.

### Build plan

| phase | branch / worktree | deliverable | depends on | model |
|---|---|---|---|---|
| core | `feat/tlstore-core` / `tl-wt-tlstore-core` | host gating, `--tsv`, `browse`, self-update hook, items.tsv, motd, docs for browse and hosts, tests | — | opus |
| installer | `feat/tlstore-installer` / `tl-wt-tlstore-installer` | `install.sh`, `sign.sh`, installer tests (own file), docs section "On official Termux" | spec only (marker + URL contract above) | sonnet |

Merge order: core, then installer; the orchestrator wires the installer test into `test.sh`, runs
the suite on the merged state, regenerates and signs the catalog. Gate: `scripts/tlstore/test.sh`
all shells green and shellcheck clean; `browse` smoke on Waydroid (pkg items only, x86_64).
Later rounds: CI in `PickleHik3/tlstore` (tag → build → SHA256SUMS) and catalog signing on
push; the catalog itself grows item by item.

## Revision 4 — more of musl than its libc (tlstore 0.3)

`npm-musl` was written for Claude Code, whose binary needs nothing but musl's libc. opencode's
needs `libstdc++.so.6` and `libgcc_s.so.1` as well, and Termux's own are Bionic-linked, so the musl
loader cannot use them.

| addition | meaning |
|---|---|
| `musl-libs=<items>` | comma list of hidden `binary` items copied into the item's directory beside the loader, before patchelf. They land under their target's basename, which is what the binary's `NEEDED` names |

The libraries cannot be ordinary `requires` alone: the install builds `<dir>.new` and moves it over
the item, so anything put there first is thrown away. They stay in `requires` too, so a standalone
copy exists under `~/.local/lib/musl/` and the install reuses it instead of downloading twice.

`item_targets` now names an npm-musl wrapper after the executable's basename: the package that
prompted this keeps its binary at `package/bin/opencode`, and the wrapper is `~/.local/bin/opencode`,
not `~/.local/bin/bin/opencode`.

The two libraries are GCC's, redistributed unchanged from Alpine's aarch64 packages by
`recipes/fetch-musl-runtime.sh` in `PickleHik3/tlstore`, under the GPL with the GCC Runtime
Library Exception.

## Revision 5 — the privileged lane (tlstore 0.5)

Some tools only make sense with the whole phone in view: btop wants every process, every mount,
every interface. A Termux uid sees its own. Termux:Launcher, when Shizuku is running and has
granted it, can start a program as the shell uid (2000) through a Shizuku `UserService`, and
tlstore learns to install items that run that way.

| addition | meaning |
|---|---|
| `priv=shizuku` | a `binary` option. The program lands at `~/.local/lib/tlstore/priv/<name>` (or the row's `target`), off PATH, and a wrapper at `~/.local/bin/<name>` — `#!$PREFIX/bin/sh`, the launcher marker, then `exec "~/.local/bin/tl-priv" run "<program>" "$@"` — is what the user runs. Both are recorded, both are removed, and `info` names both. `build-catalog.sh` refuses the option on any other kind |
| `tl-priv` | a hidden `binary` item, `host=launcher`, that every `priv=shizuku` row requires: the client of the lane, plain C against Bionic, static, edition-agnostic (`recipes/cross/tl-priv/`) |

How a run goes: the wrapper execs `tl-priv run <abs path> [args]`; tl-priv connects to the abstract
unix socket `\0<package>.priv` (the package from `$TERMUX_APP__PACKAGE_NAME`, else `$PREFIX`, else
`com.termux`), sends one tab-separated line `tlpriv1 run <path> <TERM> <rows> <cols> [args…]`, and
gets back `ok <pid>` with the pty master over `SCM_RIGHTS`, or `err <message>` (tl-priv prints it
and exits 126; 127 when nothing listens). The launcher's service copies the binary to
`/data/local/tmp/tl/bin/`, allowlisting it by the catalog digest, and spawns it there as uid 2000
with `HOME=/data/local/tmp/tl/home/<name>`, `LANG=C.UTF-8`, `PATH=/system/bin` — no prefix at all,
which is why such a binary must be fully static. tl-priv puts the local tty in raw mode, relays it,
forwards `SIGWINCH` as `TIOCSWINSZ`, and after `exit <code>` exits with that code; closing the
socket ends the child. The first such item is `btop` (`recipes/cross/build-btop.sh`, four patches:
`/proc/net/dev` when sysfs counters are refused, no kill/terminate/signal/renice, Android mounts,
Bionic threads). `TLSTORE_VERSION` moves to 0.5.

## Revision 7 — one snapshot, one prefetch, a cache that lasts (tlstore 0.5)

The store felt slow on the phone: every screen ran the script several times (`list`, `update
--check`, an `info` per item, a `picture`/`readme`/`readme-asset` per asset), each a full start
with dozens of forks, and the UI decoded pictures and pushed uploads on its drawing thread. Two
subcommands replace the per-item traffic, and the cache stops forgetting.

### `tlstore snapshot --tsv`

Everything tlstore-ui's screens need, in one run and one awk pass over the active catalog and
`installed.tsv` (`load_item` no longer forks per field either). Line-typed, tab-separated, `#`
comment lines skipped; each type carries the columns of the command it stands in for:

```
# tlstore snapshot	key=<key>
item    name  state  version  installed  kind  summary  category  featured      (= list --tsv)
field   name  key  value                                                        (= info --tsv <name>, same keys, same order)
update  name  installed  available  note                                        (= update --check --tsv --offline)
cached  name  picture|demo|readme  path                                         (a verified copy already on disk)
```

`item` and `field` lines cover the visible items; `update` lines every installed row, hidden or
not, as `update --check` does. A README's pictures never appear as `cached`: the UI learns those
from the prefetch. The answer is written to `$CACHE_DIR/snapshot.tsv` with its key on the first
line and served from there while the key holds. The key names everything the answer depends on:
tlstore's version, the catalog (path, serial, mtime, size), `installed.tsv` (mtime, size), the
cache stamp `$CACHE_DIR/.changed` (mtime, size), and what `rows()` filters on (host, processor,
app package, launcher version, `$HOME`, `$PREFIX`). A relaunch with nothing changed reads one
small file. `list`, `info`, `update --check` keep working for other callers.

### `tlstore prefetch`

Fetches every picture, demo, readme and readme header picture that is missing, for every visible
item — the featured items first, then in list order, three items at a time — and prints one line
per asset as it lands, flushed per line:

```
ready   name  picture|demo|readme  path
ready   name  asset                path  src        (the README's first image; src as written in it)
failed  name  kind                 reason  [src]
```

Nothing is said about an asset the item does not have. What is cached and verified costs no
network at all. Every curl the script runs now carries `--connect-timeout 5` and either
`--max-time 60` (catalog, registry documents, readmes and pictures) or `--speed-limit 1
--speed-time 30` (payloads, which may be large: they give up on a stall, not on a long
transfer). Part files carry the pid, so a prefetch lane and an item opened early may fetch the
same file at once and both verify their own copy.

The UI starts the prefetch once the first snapshot is in (and again after a catalog refresh),
reads its lines as they arrive and shows each asset as it lands; while it runs, the UI never asks
for a picture, demo or readme on its own — they are all on their way — and asks for anything the
prefetch did not answer once it ends. A README's other pictures are still fetched one by one as
they scroll into view.

### The asset cache

Under `$CACHE_DIR` (`$HOME/.cache/tlstore`: the Termux home, inside the app's `files` directory,
which Android does not clear — it is not the app's cache directory):

| path | what | key | fetched again when |
|---|---|---|---|
| `pictures/<digest>.<ext>` | a picture or demo | its catalog digest (the sha256 of its URL for an old catalog's demo without one) | the catalog names a new digest for it |
| `readme/pinned/<digest>.md` | a pinned readme | its catalog digest | the catalog names a new digest |
| `readme/<name>-<version>.md`, `.ref` | an upstream readme and the revision it was read at | the item's version | the catalog moves the item to a new version; else revalidated by the prefetch at most once a day (`curl -z`), never on the open path |
| `readme/<name>/<ref>/<urldigest>.<ext>` | a picture that readme refers to | its address, under the readme's revision (the pinned commit for a pinned readme) | the readme's revision changes; the header picture is revalidated with the readme |
| `snapshot.tsv` | the last snapshot with its key | see above | its key no longer holds |
| `.changed` | touched whenever anything above is fetched or removed | — | — |

Rules: a digest-keyed copy is final for as long as the catalog names that digest, with no TTL; the
open path (`picture`, `readme`, `readme-asset`) always serves a copy that is here, offline or not,
and fetches only what is missing; only the prefetch looks upstream again, and only for
version-keyed copies a day old. `prefetch` first throws away what the active catalog no longer
names: pictures and pinned readmes under other digests, upstream readmes of other versions, the
readme pictures of items or revisions that are gone (and any picture left from before pictures had
revision directories). Dropping build tools no longer empties the cache: pictures, readmes and
the snapshot stay.

### tlstore-ui

The UI never runs the script synchronously: the snapshot, the prefetch, every fetch, the refresh,
gh, and now `launcherctl` too are tasks whose stdout the loop polls. Pictures are decoded, fitted
and encoded for the terminal by a two-thread worker that wakes the loop through a pipe; READMEs
are parsed there too. Frames of a clip are encoded by the frame thread. Uploads leave through a
write queue the loop drains as the terminal accepts them, with `POLLOUT` in the poll set, so a
clip streaming never blocks input. Up to three clips stay decoded, and up to three stay uploaded
in the terminal after their placements go, so going back re-places a clip instead of sending it
again. Nothing is asked for before an item has rested 150 ms under the cursor.

## Revision 8 — binaries as release assets, a store that updates itself (tlstore 0.6)

A launcher APK carrying an older `app/tlstore.lock` put engine 0.4 back under a 0.5 `tlstore-ui`
and the store broke. The engine and the UI now move together, from this repository's own
releases, whichever launcher version installed them; and the binaries the catalog installs are
no longer committed.

### Binaries as release assets

`bin/` is gone. `.github/workflows/build.yml` builds the tools of `recipes/cross` on a runner
(`recipes/cross/build-asset.sh <tool> [edition]`, one job per tool and per launcher edition where
the binary carries a prefix), publishes them as the assets of one GitHub Release tagged
`bins-YYYY.MM.DD[-N]` — a **prerelease**, so `releases/latest` keeps meaning the store release —
under their catalog names (`<tool>-aarch64`, `<tool>-<package>-aarch64`), and commits the record
to `main` with `scripts/bins-record.sh`: the assets' `SHA256SUMS` lines replaced, and every
`items.tsv` row with a bare `binaries:<asset>@<old tag>` source for a rebuilt asset moved to the
new tag. Tools not in that run keep their tag and digest, so tags differ per tool.

Resolution in the engine (`source_url`, and the awk `url_of` copies in `snapshot_rows` and
`prefetch_gc`): a bare `binaries:<asset>@<tag>` is
`$BINARIES_RELEASES/<tag>/<asset>-aarch64` (`https://github.com/PickleHik3/tlstore/releases/download`,
`TLSTORE_BINARIES_RELEASES` in tests); a path with a slash stays
`$BINARIES_RAW/<tag>/<path>`, a small file kept in git (`TLSTORE_BINARIES_RAW`). Digests still
come from `SHA256SUMS` at `build-catalog.sh` time, bare assets by `<asset>-aarch64`.

Update detection is by version: `update_items` and `snapshot_rows` compare the catalog's version
with the installed one and nothing else. A rebuilt binary is therefore an update only when its
version moves. `bins-record.sh` bumps the build number of a `+<commit>.<N>` version (dawn's
`0.1.3+0e958747.3` → `.4`) when the asset's digest changed; a plain upstream version (btop
`1.4.7`) is left alone and named on stderr and in the run summary for the maintainer to bump by
hand (`docs/maintainer/catalog.md`, "Rebuilding a binary").

### The store release

`release.yml` still commits `dist/` and `SHA256SUMS` and tags — the launcher's gradle fetch reads
`dist/` from the tag through raw URLs — and then creates the GitHub Release `<tag>`, marked
latest, with `tlstore`, `tlstore.minisig`, `catalog.tsv`, `catalog.tsv.minisig`, `trusted.pub`,
`tlstore-ui-arm64-v8a` and `tlstore-ui-x86_64` as its assets (`gh release create` with the
workflow token; the dry-run `publish` input stops before the commit as before).

Before signing, `release.sh --prepare` runs `scripts/embed-ui-digests.sh`: the engine carries two
placeholder lines, `TLSTORE_UI_SHA256_arm64_v8a=` and `TLSTORE_UI_SHA256_x86_64=`, empty in the
source and filled from `dist/tlstore-ui-<abi>` in `dist/tlstore`, so the signature over the
script covers the digests of the UI built beside it. The second `release.sh` pass runs the same
script with `--check` and refuses a `dist/tlstore` that names other bytes.

### Self-update, under the launcher too

`CATALOG_URL` defaults to `$RELEASE_BASE/catalog.tsv`, `RELEASE_BASE` being
`https://github.com/PickleHik3/tlstore/releases/latest/download` (`TLSTORE_RELEASE_BASE` in tests);
the serial and signature checks are unchanged. `self_update` no longer looks at `.standalone` or
`.installed`: it fetches `$RELEASE_BASE/tlstore` and `.minisig`, verifies against `trusted.pub`,
and goes on only when the new `TLSTORE_VERSION` is ahead. Where a `tlstore-ui` is in place
(`$PREFIX/libexec/termux-launcher/tlstore/tlstore-ui`), the new script must name a digest for
this processor's ABI (`uname -m`: `aarch64` → `arm64-v8a`, `x86_64` → `x86_64`), the matching
`tlstore-ui-<abi>` is downloaded and checked against that signed digest, and both files are
staged beside their targets and renamed into place — the script first, since an older UI reads a
newer script's output (columns only ever land at the end) and the reverse is what broke. A UI that
cannot be had, or does not match, keeps the old script too. The launcher's own record of the UI,
`.tlstore-ui-sha256`, is rewritten with the new digest so the app keeps treating the file as its
own. Nothing is re-executed. Without a UI in place (a standalone install on plain Termux) only
the script moves.

When: on `update` and on `update --check` (the refresh `tlstore-ui` runs when it starts, whose
stderr it discards) — never `--offline`, and never inside a `--progress` stream, which carries the
item lines alone. Under `--tsv` the self-update's one line of narration goes to stderr, so the
machine output stays clean.

The launcher's installer (`TlstoreInstaller`, in the launcher repository) is being changed
separately so an APK never puts an older release back; nothing here depends on that beyond the
`.tlstore-ui-sha256` record above.

## Revision 9 — the store updates itself in plain view (tlstore 0.7)

Revision 8's self-update ran silently inside `update --check`, the refresh `tlstore-ui` starts in
the background: the files were swapped under a running UI, the UI stayed old until the next
launch, and nobody saw anything. Now the UI asks first, installs the store itself on its own
Installing screen before anything else, and hands over to the new copy.

### Engine: `tlstore self-update`

```
tlstore self-update --check --tsv    self	<installed>	<latest>	<available 0|1>
tlstore self-update --progress       the --progress stream for the one item `tlstore`
tlstore self-update                  what `update` does for the script, narrated
```

`--check --tsv` fetches only `$RELEASE_BASE/tlstore` and `.minisig` (`--connect-timeout 5
--max-time 60`; offline it answers within that, available 0, latest `-`), verifies against
`trusted.pub`, and says available 1 when the script is newer *and*, where a `tlstore-ui` is in
place, names a `TLSTORE_UI_SHA256_<abi>` for this processor. The verified script then stays at
`$CACHE_DIR/tlstore.new` (+ `.minisig`) for the `--progress` run, which takes it from there when
it still verifies and is still newer rather than fetching it twice; on 0 nothing is left behind.
A refused signature is available 0 with one line on stderr, and no file is touched. Exit 0
whenever the line is printed.

`--progress` (`PROGRESS=1`, `CANCEL_ITEM=tlstore`): `step tlstore 2 fetched`; the script's
download, when it is not cached, fills 2–8 through `curl_to`; the store program's download
fills 8–80 as curl reports it; `step tlstore 85 signature checked` when its digest matches the
one the signed script names (the script's own minisign check came before that download, and a
refused script ends the job there); `step tlstore 92 putting files in place` before the staging
and renames of Revision 8 (unchanged: both staged beside their targets, the script renamed
first); `step tlstore 100 ready`; then `done tlstore ok updated to <v>`, exit 0 — or `done
tlstore failed <reason>`, exit 1, with both old files where they were. A cancel (SIGTERM to the
process group) drops the part file, the cached script pair and the staged copies, prints `done
tlstore failed Cancelled.` and exits 143, as for any job. `self_update` is now
`self_update_try` (`su_ready`, `su_fetch_script`, `su_fetch_ui`, `su_place`) under three
callers; `update` keeps self-updating as before, `update --check` no longer does (the test that
expected it now expects the opposite), and `--offline` and `--progress` item jobs never do.

### UI: Installing for `tlstore`, then the new `tlstore-ui`

`Store::new` starts `self-update --check --tsv` first, beside the snapshot; until it answers,
the store is exactly as before, and with available 0 nothing changes (no flash, no wait). With
available 1 and no job running, `Verb::SelfUpdate` starts `self-update --progress` at once (it
does not wait for the refresh) and the router pushes Installing over whatever is up: the header
reads `tlstore` in the script face, "the launcher's tool store", the masthead links
`PickleHik3/tlstore`, the facts strip reads `updating <old> → <new>` from the check, and the
number, steps and line follow the stream as for any item. `esc`/back, `x` and `q` all cancel
the job (a self-update left running would swap the files under the UI); `esc` then goes back,
`q` quits, `x` stays for the summary. A failed job shows its summary and `⏎ done` leads back
into the store on the old files.

On `done tlstore ok` the finished screen is held 600 ms (`SELF_UPDATE_HOLD`) with keys
ignored, then `Router::finished` ends the app loop the way a quit does: pending bytes flushed,
the terminal restored (`LEAVE`: mouse and resize modes off, kitty images deleted, cursor
shown, main screen, termios back), `Router::drop` (keyboard shown, prefetch stopped). `main`
then `exec`s the path `current_exe()` gave at startup — taken before the rename replaced the
file, since `/proc/self/exe` is stale after it — with the same arguments and environment plus
`TLSTORE_UI_SELF_UPDATED=<new version>`. The new copy reads that variable, skips the check
(so a launch never updates twice), and shows `tlstore updated to <version>` on Front's notice
row for four seconds or until a key. If the exec fails, the old copy prints `tlstore updated to
<version> — run tlstore again` and exits 0. `app::Screen` gains `finished() -> bool`, asked
after every tick.

`TLSTORE_VERSION` moves to 0.7: a phone on 0.6 only sees this once a release carries a newer
script.

## Revision 10 — items that own commands a package owns (tlstore 0.8)

`termux-api-shims` installs commands (`termux-clipboard-get`, `termux-notification`, ...) that the
apt package `termux-api` also installs. tlstore never writes into Termux's own `bin`, so the two
would not overwrite each other — but `~/.local/bin` comes first on PATH, and the shims would
silently shadow the real commands. The engine learns to refuse instead.

| addition | meaning |
|---|---|
| `conflicts=<pkg,pkg>` | any kind. `install` refuses the item — exit 1, `<name> cannot be installed while the <pkg> package is: both provide the same commands. Remove it first (pkg uninstall <pkg>), then install <name> again.` — while a listed package is installed (`pacman -Q`, else `dpkg-query` status `installed`, so a removed package with only config files left does not count, else `command -v`). It is checked for every item in the plan before the "Go ahead?" question and before anything is fetched, and again in `install_item`. An item that is already installed is not refused afterwards, and `update`, `remove` and `snapshot` never look at it. A part installs before the item that needs it, so the option goes on the visible item and on every part |

An engine older than 0.8 ignores the option (an unknown `options` key is skipped), which is why
`TLSTORE_VERSION` moves to 0.8: a phone takes the new script with the release that carries the
row. `scripts/test.sh` covers the option with a bundle and a part under a fake `pacman` that
reports `termux-api` only while a marker file exists.

The shims themselves are `file` items, one per command, each `mode=755` at
`~/.local/bin/<command>`, sourced as `binaries:shims/termux-api/<command>@<ref>` — a path in this
repository, digest-checked from `SHA256SUMS` like a pinned readme. The visible item is a
`bundle`. See `docs/maintainer/termux-api-shims.md`.
