# Keeping the tlstore catalog current

How an agent adds, updates or removes an item in tlstore, and what has to happen before the
change reaches a phone. The user-facing side is `docs/user/Tlstore.md`; the design of the store's
screens is `docs/REVISION-6.md` (Revision 5 still describes the engine, the TSV contract and the
progress stream).

This repository (`PickleHik3/tlstore`, renamed from termux-launcher-binaries 2026-09-24; local
checkout at `~/Projects/termux-launcher/tlstore`) is
the store's whole home: the engine source, the catalog inputs, the UI crate, the scripts and the
docs live here together, and a `dist/` of built, signed release files is what a tag actually ships.
The launcher (`PickleHik3/termux-launcher`) consumes a tagged `dist/` by pinned digest — nothing
in the launcher builds or signs any of this.

## The pieces

| Piece | Where | Owner |
|---|---|---|
| Item list (hand-maintained) | `scripts/items.tsv` | you edit this |
| Engine source (POSIX sh) | `engine/tlstore` | edit, `scripts/test.sh`, `scripts/sign.sh` |
| Trusted key (source) | `engine/trusted.pub` | the maintainer's minisign public key |
| Store UI (Rust) | `ui/` | `scripts/build-ui.sh --install` after any `src/` change |
| Pictures | `scripts/pictures/<name>.jpg` + `SOURCES.md` | you, with the conversion in `SOURCES.md` |
| Termux package sizes | `scripts/pkg-weight.py` | prints an item's `pkg-size=` (see "Items that pull in large Termux packages") |
| Release outputs (built, signed) | `dist/{tlstore,tlstore.minisig,catalog.tsv,catalog.tsv.minisig,trusted.pub,tlstore-ui-arm64-v8a,tlstore-ui-x86_64}` | `scripts/release.sh <tag>` — never hand-edited |
| Binaries the catalog installs | GitHub Release assets of this repository (`bins-…` prereleases), digests in `SHA256SUMS` | `.github/workflows/build.yml` builds them with `recipes/cross` and records them (`scripts/bins-record.sh`) |
| Launcher-side install | `app/src/main/java/com/termux/app/store/TlstoreInstaller.java` in `PickleHik3/termux-launcher` | writes script, catalog, key and UI binary into `$PREFIX` when the APK changes, from a pinned tag's `dist/`; from then on `tlstore` keeps itself and the UI current from the latest store release |

The phone reads `catalog.tsv` by fixed column position and requires at least ten columns. New
columns land only at the end, and a hidden part carries `-` in every descriptive column and `0`
in `setup`/`featured`.

## Adding or changing an item

1. **Pin the payload.** A `binary`/`archive`/`skill`/`file` source is `launcher:<path>@<tag or commit>` (a
   launcher-owned template, fetched from `PickleHik3/termux-launcher`), `binaries:<asset>@<tag>`
   (a release asset of this repository, `<asset>-aarch64` or `<asset>-x86_64` on the `bins-…`
   prerelease `<tag>`, whichever the phone's processor is),
   `binaries:<path/with/slash>@<tag>` (a file in this repository at that tag) or an immutable
   URL; `npm-musl` and `npm-android` are `npm:<package>#<exe>` (npm-android is for a package that ships
   an Android executable, which runs as it is: no loader, no patchelf); `pkg` names Termux packages. Never a branch. For a
   new binary, add its recipe to `recipes/cross` and a line for it in `scripts/bins-plan.sh` and
   `recipes/cross/build-asset.sh`, run `build.yml` for it ("Rebuilding a binary" below), and
   point the row at the `bins-…` tag it printed; its digest is then the `<asset>-aarch64` line of
   `SHA256SUMS` on `main`, and its x86_64 digest the `<asset>-x86_64` line ("x86_64" below).
2. **Edit `items.tsv`.** The header comment defines every column and its rule (length limits,
   allowed values). Revision 6 reads: `category`, `upstream`, `setup`, `standfirst`, `author`,
   `licence`, `size`, `picture`, `featured`, `readme-skip`, `readme` (the pinned-content addendum).
   `does1..3`, `try` and `notes` are no longer shown; fill them with `-` for a new item.
   - `standfirst`: one line, at most 42 characters, lower case, no brand name, no full stop. It is
     the only sentence we write about the item.
   - `readme-skip`: `|`-separated headings of the upstream README to leave out (developer-facing
     sections). Installation, Building, Contributing, Licence, Changelog, Sponsors and similar are
     dropped by default already.
   - `picture`: a source pointing at a hero picture in `scripts/pictures/<name>.jpg`. A new item
     points at it with `binaries:scripts/pictures/<name>.jpg@<tag>` — a path source resolved
     against this repository's own `SHA256SUMS` at that tag (the old `launcher:scripts/tlstore/
     pictures/…@<commit>` sources still on a few items are pinned at a commit in the launcher
     repository from before the store moved here; they keep working and are left alone, but no new
     item should add one). Convert the upstream hero image as `pictures/SOURCES.md` says and add a
     row there with the source and its licence.
   - `readme`: a `launcher:`/`binaries:` source for a pinned copy of the item's README, read
     instead of the upstream one; `-` to keep fetching upstream (most items). Pin one when the
     upstream README does not render well as-is (heavy badges, a build matrix table, prose that
     assumes a desktop) — write a trimmed copy instead of relying on `readme-skip` alone.
   - `demo`: unchanged (a `launcher:`/`binaries:` source for a short clip of `try` working), but
     now digest-checked like `picture` — `build-catalog.sh` computes its `demo-digest` the same
     way it already computes `picture-digest`.
3. **Build the catalog.**
   ```sh
   scripts/build-catalog.sh              # SHA256SUMS defaults to this repo's own
   scripts/build-catalog.sh /path/to/SHA256SUMS   # only if you need a different one
   ```
   It computes digests (network for plain URLs), bumps the serial (`YYYYMMDDNN`, only forward) and
   writes `dist/catalog.tsv`. A source whose digest cannot be computed stops the build.
4. **Test the engine.** `bash scripts/test.sh` must end `failed 0`. It runs `engine/tlstore` under
   `/bin/sh` and `bash --posix`; dash, busybox and shellcheck run too when installed.
5. **Sign.** `bash scripts/sign.sh` signs `dist/catalog.tsv` and `dist/tlstore`. The key is
   `~/.config/vaj-apt/tlstore-minisign.key`, encrypted, outside the tree: the developer runs this
   step (`! bash scripts/sign.sh` in a Claude session). Phones verify the signature only when they
   refresh from origin, so sign before every push, not before a local test install. In practice
   this happens inside the two-pass release flow below, not on its own.
6. **Check the UI against it.** In `ui/`: `cargo test`, and for a look at the result without a
   phone, the preview renderer:
   ```sh
   cargo run --features shot -- --shot 53x26 --screen item:<name> --out /tmp/item.png
   cargo run --features shot -- --shot-all --out /tmp/frames/
   ```
   It renders from `tests/fixtures/store`, so a new item needs a row in the fixture `list.tsv`,
   an `info/<name>` file and a `readme/<name>.md` to appear there.
7. **Commit** `items.tsv` and any picture. `dist/` is not committed by hand at this step — cut a
   release (below) once the item is ready to ship.

### Script-only items and conflicts

An item made of scripts kept in this repository (no binary to build) is a set of hidden `file`
rows, `mode=755`, sourced as `binaries:<path>@<ref>` with their digests in `SHA256SUMS`, under one
visible `bundle`. `termux-api-shims` is the model, including `conflicts=<pkg>` for an item that
owns commands a Termux package owns: `docs/maintainer/termux-api-shims.md`.

A bundle that is a shell and its setup carries `login-shell=<shell>` (`fish-shell` is the model):
once its members are in, the engine runs `chsh -s <shell>`, so new sessions start in it, and says
so; a missing shell or `chsh` is reported with the command to run, and the install still stands.
`remove` takes the `~/.termux/shell` link away again, but only while it still points at that
shell. The engine tests cover both with a fake `chsh`.

## Cutting a release

`dist/` is never hand-edited. `scripts/release.sh <tag>` builds it from the sources
(`engine/tlstore`, `engine/trusted.pub`, `scripts/items.tsv`, `ui/`) and writes the lock block the
launcher pins against. Signing needs the developer's passphrase, so this is two passes:

1. **`scripts/release.sh <tag> --prepare`** — copies `engine/tlstore` and `engine/trusted.pub`
   into `dist/`, runs `build-catalog.sh` (writing `dist/catalog.tsv`), and checks
   `dist/tlstore-ui-<abi>` freshness against the working tree (`scripts/check-dist.sh`, the
   `ui-src-hash.sh` check the launcher's own `checkTlstoreUiFresh` gradle task used to run). Run
   `scripts/build-ui.sh --install` first if the UI needs rebuilding.
2. The developer runs **`scripts/sign.sh`** by hand (the key never touches an agent session).
3. **`scripts/release.sh <tag>`** (no `--prepare`) — verifies both signatures against
   `engine/trusted.pub` with `minisign -Vm`, refuses if anything is missing or stale, writes
   `dist/<file>` lines into `SHA256SUMS` (replacing the existing `dist/` lines, leaving every other
   line untouched), and prints the lock block:
   ```
   tag <tag>
   <sha256>  tlstore
   <sha256>  tlstore.minisig
   <sha256>  catalog.tsv
   <sha256>  catalog.tsv.minisig
   <sha256>  trusted.pub
   <sha256>  tlstore-ui-arm64-v8a
   <sha256>  tlstore-ui-x86_64
   ```

`release.sh` never tags or pushes; that is the orchestrator's call once the lock block is in hand.

### From GitHub, without a laptop

Two workflows, in this order when a tool changed:

1. **`build.yml`** builds binaries and publishes them as release assets — "Rebuilding a binary"
   below. `gh workflow run build.yml -f tools=all` (or `-f tools=dawn,btop`). When it is done,
   `main` carries the new `SHA256SUMS` lines and `items.tsv` tags; nothing on a phone changes yet.
2. **`release.yml`** runs the same three passes as above on a runner (`scripts/test.sh` first;
   `tlstore-ui` rebuilt only when `scripts/check-dist.sh` says `ui/` changed), commits `dist/`
   and `SHA256SUMS`, tags, pushes, creates the GitHub Release `<tag>` marked **latest** with
   `dist/`'s seven files as its assets, and prints the lock block in the run summary. Start it
   from the Actions tab, the GitHub app, or `gh workflow run release.yml [-f tag=<tag>]`; with no
   tag it uses today's date, suffixed `-2`, `-3`… when that is taken; `-f publish=false` is a dry
   run that stops after signing. Heroes and readmes are published as committed, so commit those
   first.

Phones read the latest release: `tlstore` refreshes its catalog from
`releases/latest/download/catalog.tsv` on `update`, `upgrade` and `install` (and the UI's
background `update --check`), and `upgrade` (in the UI, `self-update --progress`) takes a newer
`tlstore` from there together with the `tlstore-ui-<abi>` it names (`docs/SPEC.md`, Revisions 8,
9 and 19). So a release is live for every phone the moment the workflow ends —
whichever launcher APK installed the store — and the launcher's `app/tlstore.lock` only decides
what a fresh install starts from. The `bins-…` releases are prereleases, so `releases/latest`
never points at one.

For the items "Upstream watch" below covers, a daily workflow runs both on its own.

A first release from a bare repository is `build.yml` with `tools=all` (every `items.tsv` row
then names a `bins-…` tag), then `release.yml`. Both need the secrets below; `build.yml` needs only
the workflow's own token. `ci.yml` runs `scripts/test.sh` and the UI crate's `cargo test` on
every push and pull request to `main`.

`release.yml` signs with two repository secrets, set once from the machine that holds the key:

```sh
gh secret set TLSTORE_SIGNING_KEY -R PickleHik3/tlstore < ~/.config/vaj-apt/tlstore-minisign.key
gh secret set TLSTORE_SIGNING_KEY_PASSWORD -R PickleHik3/tlstore   # prompts for the password
```

`scripts/sign.sh` reads the password from `TLSTORE_SIGNING_KEY_PASSWORD` when it is set. With the
key in the repository's secrets, anyone who can run workflows here can publish a catalog phones
trust: keep write access to yourself.

## Rebuilding a binary

Binaries are never committed. `.github/workflows/build.yml` builds them on a runner and publishes
them as GitHub Release assets:

```sh
gh workflow run build.yml -f tools=dawn,btop     # or tools=all
```

For each tool and each processor (`aarch64`, `x86_64`), and for each launcher edition for
`fastfetch`, `dawn` and `musl-loader`, whose binary carries the edition's prefix, a job runs
`TL_ARCH=<arch> recipes/cross/build-asset.sh <tool> [edition]` — the NDK from `sdkmanager`, the
edition's Termux sysroot from its own `.deb` repository (cached by month), the recipe as it is —
and uploads `<tool>-<arch>` or `<tool>-<package>-<arch>`. The io.vaj.tl edition is built for
aarch64 only: its APK, bootstrap and package repository are. A last job creates one release for
the run, tagged `bins-YYYY.MM.DD` (`-2`, `-3`… on the same day), marked prerelease, with every
asset under its catalog name plus a `SHA256SUMS` of them, and then commits to `main` as
`github-actions[bot]`, through `scripts/bins-record.sh`:

- the `<asset>-aarch64` and `<asset>-x86_64` lines of `SHA256SUMS` replaced (or added), every
  other line untouched;
- every `items.tsv` row with a bare `binaries:<asset>@<old tag>` source for a rebuilt asset moved
  to the new tag. Rows for tools the run did not build keep their tag and digest — tags differ
  per tool, and that is fine.

**A rebuilt binary is an update on a phone only when its version moves.** `tlstore` decides
`upgrade` by comparing the catalog's version with the installed one, not by digest. So:

- a version of the form `<upstream>+<commit>.<N>` (dawn: `0.1.3+0e958747.3`) is bumped to `.N+1`
  by `bins-record.sh` on its own whenever the asset's bytes changed. Use this shape for a tool
  whose recipe carries patches that change independently of upstream;
- a plain upstream version (btop `1.4.7`, sigye `0.6.0`) is left alone, and the run summary (and
  the script's stderr) names the item. If phones should pick the rebuild up, edit the version by
  hand before the store release — the tidy move is to switch it to the `+<commit>.<N>` shape once
  — or leave it when the rebuild changes nothing that matters to a phone that already has it.

The musl loader and the musl libraries (`musl-libs=`) are copied into each npm-musl item's own
directory when it is unpacked. From tlstore 0.17 an update or install that finds the item already
there replaces a copy that differs from the installed part, so a rebuilt loader reaches Claude
Code and opencode without a new npm version; the loader's version is `1.2.5+tl.<N>` for that.
[npm-items.md](npm-items.md) walks through an npm item end to end, using opencode as the example.

Then cut a store release (`release.yml`) so the new tag and digests reach phones in a signed
catalog. If the workflow's final push failed (a race with another commit), the release and its
assets exist: run `scripts/bins-record.sh <bins-tag> <dir with the assets>` locally and commit.

To add a tool: write its `recipes/cross/build-<tool>.sh`, add it to the table in
`scripts/bins-plan.sh` (edition-agnostic, or one build per edition) and to the `case` in
`recipes/cross/build-asset.sh`, and run `build.yml` for it. `scripts/test.sh` checks both
scripts' behaviour on fixtures; the recipe itself is exercised only by the workflow. The recipe
reads the processor from what `build-asset.sh` derives (`TL_ARCH`, `TL_TRIPLE`, `TL_ANDROID_ABI`,
`TL_GOARCH`, `TL_TERMUX_ARCH`, `TL_ALPINE_ARCH`), never from a literal, so it builds for both.

## Upstream watch

herdr, btop, fastfetch, kitten, sigye and fisher follow their upstream's latest stable release
with no hand on them: `.github/workflows/upstream-watch.yml` runs once a day and, for each item
that is behind, moves its pin, builds it, and cuts a store release when at least one bump made it
through. Which items, which upstream and which lines a bump rewrites live in one table at the top of
`scripts/upstream-watch.sh`; it runs the same on a laptop:

```sh
scripts/upstream-watch.sh --check            # ours against theirs, writes nothing
scripts/upstream-watch.sh --bump herdr       # pin herdr to upstream's latest, recipe and items.tsv
```

"Latest stable" is GitHub's `releases/latest`: never a prerelease (herdr's "Preview build"s) or a
draft. A bump moves the recipe's pin (the tag's commit, or a tag; for an item fetched as upstream's
own release asset, the version and each asset's digest, which must match the sha256 GitHub publishes
for it) and the version column of
every `items.tsv` row of the item. herdr's rows carry the store's own build number
(`0.9.5+tl.<N>`: its asset is an archive, our bionic build plus a launcher script, so a rebuild
of the same upstream version must still reach phones): the watch reads such a row as its upstream
version, and a bump writes `<new>+tl.0`. The bins tag and `SHA256SUMS` stay `build.yml`'s to
move. So the plain upstream versions in "Rebuilding a binary" above are moved for these items by
the bump itself, and `bins-record.sh`'s "bump it by hand" note on the run that lands one can be
ignored.

One run, in the order the jobs go:

1. **check** — every behind item is bumped as its own commit on the branch `upstream-watch/trial`.
   A bump that cannot verify what it pins fails there, alone.
2. **trial** — `build.yml`, called with `trial: true`, builds every bumped tool and publishes
   nothing. An item passes when every asset `bins-plan.sh` names for it built.
3. **verdict / build** — the passing bumps are made again on the main of now
   (`upstream-watch/land`) and `build.yml` builds them from there; its publish job rebases those
   commits onto main and pushes them with the record, in the `release` lane. A bump never reaches
   main without its binary; one that failed is just left out, and the others go on.
4. **release** — `release.yml`, called when something landed, or when main carries a watched
   item's built version that the last release (`dist/catalog.tsv`) does not.
5. **report** — the issue **Upstream watch** is rewritten: per item ours, theirs, status and run.
   It is opened when an item needs a hand and closed while all are current. A failed bump is
   remembered there and tried again only when upstream moves on, a week later, or on a manual run
   with `retry`. `-f dry_run=true` checks and trial-builds, and lands nothing.

Not watched: dawn and terminal-browser (our forks: an upstream release needs a hand merge), npm
items (`latest`), pkg items, launcher-pinned files and skills, the musl loader and runtime. The
on-device recipes under `recipes/termux` and `recipes/nix` are not moved either. To watch another
item, add its line to the table (one of the pin shapes the script's header lists) and give its
recipe that shape.

## x86_64

A row's own columns describe its aarch64 build. On an x86_64 device tlstore reads three options
in their place (`docs/SPEC.md`, Revision 12):

- **A binary** (and an **archive**, the same way) is offered on x86_64 once its x86_64 build is
  published. Nothing is written by hand:
  `build.yml` builds `<asset>-x86_64` beside `<asset>-aarch64` under the same `bins-…` tag,
  `bins-record.sh` records its `SHA256SUMS` line, and `build-catalog.sh` appends
  `x86_64:digest=<sha256>` to the row. Without that line the row gets no `x86_64:digest` and stays
  hidden on x86_64, so the catalog is right before and after the build. Never write
  `x86_64:digest` yourself; `build-catalog.sh` refuses it. A binary whose target names the
  processor also gets `x86_64:target=` (the musl loader: `ld-musl-x86_64.so.1`).
- **An npm-musl or npm-android item** needs `x86_64:source=npm:<x64 package>#<exe>` by hand, after
  checking the package exists for x64 (`npm view <package> cpu`) and that the executable sits at
  the same path inside it. claude-code and opencode have one. An npm-musl item is offered only
  while the musl loader (and its `musl-libs`) are there for the processor too.
- **codex** has none: `@mmmbuto/codex-cli-termux` is published for `cpu: arm64` only, so it stays
  hidden on x86_64 until an x64 build of it exists.
- **io.vaj.tl rows** are aarch64 only, like the edition itself.

## An app that is a whole directory (archive)

A `binary` is one file. An app made of many (an Electron app: `bin/`, `dist/` trees,
`node_modules`, assets) is an `archive` item (`docs/SPEC.md`, Revision 14):

1. **Pack it with the app's root at the top**: `tar czf <asset>-<arch> -C <app dir> .`. Nothing is
   stripped on the phone, so a folder on top means the program is not where `exe=` says, and the
   install is refused.
2. **Publish it as a release asset** under a `bins-…` tag, `<asset>-aarch64` and (when there is
   one) `<asset>-x86_64`, with their `SHA256SUMS` lines, the way `build.yml` publishes a binary.
3. **Write the row**: kind `archive`; version `<upstream>+<commit>.<N>`, so `bins-record.sh` bumps
   `.N` whenever a rebuild changes the asset's bytes (a rebuild at the same version is not an
   update, as for a binary); source `binaries:<asset>@<tag>`; target `-`, which is
   `~/.local/lib/<name>`; options `exe=<path of the program inside the archive>` (required),
   plus `command=<name>` when the command should not be the item's name. `env=`, `tz=1` and
   `args=` work as for the npm kinds. `build-catalog.sh` fills the digest and `x86_64:digest`, and
   refuses a row without a usable `exe=`.

tlstore unpacks it into `<dir>.new`, checks `exe=` is there and executable, swaps the directory
in whole and writes `~/.local/bin/<command>`, which execs `<dir>/<exe> "$@"`. The directory is the
store's: an update replaces it whole, and a change made inside it is lost. Settings belong
outside it. An engine older than 0.15 lists an archive item but refuses to install it, so the first
archive row ships in the same release as engine 0.15.

## An agent skill (skill)

An agent skill is a folder an agent reads: a `SKILL.md` and the files beside it. A `skill` item
installs one (`docs/SPEC.md`, Revision 18). The launcher's two skills, `termux-launcher` and
`termux-launcher-speak`, are the `launcher-skill` bundle that claude-code and opencode require.

1. **Pack it with the skill's folder on top**, named like the item, and nothing else beside it.
   The launcher's own `scripts/pack-agent-skills.sh` does this, reproducibly, and
   `recipes/cross/fetch-launcher-skills.sh` runs it at a pinned launcher commit.
2. **Publish it** with `gh workflow run build.yml -f tools=launcher-skills`. A skill is the same on
   every processor, so that is one job, and each tarball is published twice under the one tag,
   `skill-<name>-aarch64` and `skill-<name>-x86_64`, byte for byte the same.
3. **Write the row**: kind `skill`; version the launcher commit's first eight characters; source
   `binaries:skill-<name>@<tag>`; target `-`, which is `~/.agents/skills/<name>`; no options but
   `hidden=1` for a part. `build-catalog.sh` fills the digest and `x86_64:digest` as for a binary.
   A new row can carry the tag `bins-pending` until the build runs: `bins-record.sh` moves it to
   the real tag, and `build-catalog.sh` stops on it until then.

To move the launcher skills on: put the new commit in `fetch-launcher-skills.sh`, set both rows'
version to its first eight characters, run the build, and cut a store release.

tlstore unpacks the tarball beside the directory, checks that its one top-level entry is the
item's folder, swaps the directory in whole, then links `~/.claude/skills/<name>` to it, and
`~/.codex/skills/<name>` too while `~/.codex` is there. A symlink already at a link path is
replaced. A real folder there is replaced only when every file in it came from a retired `file`
row of the store and is unchanged; anything else is the person's, so it stays, stderr says so,
and the install still succeeds without that link. `remove` deletes the directory and the links
that still point into it. An engine older than 0.19 lists a skill item but refuses to install it,
so the first skill row ships in the same release as engine 0.19.

## Items that pull in large Termux packages

An item whose Termux packages are large says so before it is installed (`docs/SPEC.md`,
Revision 15): its page shows "Also installs …: about N MB to download, M MB on disk (less if you
already have some of them).", and `install` says what apt still needs on that phone before it asks
to go ahead. Both happen only above 50 MB of either; below that nothing changes.

1. **Compute the figures** for the packages the item pulls in, its own and its parts':
   ```sh
   python3 -I scripts/pkg-weight.py x11-repo electron42
   # 89 packages beyond a stock Termux: 152.5 MB to download, 862.3 MB on disk
   # largest on disk: electron42 414 MB, libllvm 174 MB, gtk3 32 MB, ...
   # pkg-size=153,862
   ```
   It reads Termux's main and x11 package indexes for aarch64 (`--arch x86_64` for the other
   build), follows every dependency, and leaves out what a fresh Termux has. `--index FILE` reads
   saved `Packages` files instead of the mirror; `--have a,b` counts more packages as already
   there. Never write the figures by hand, and recompute them when the packages move on.
2. **Put them on the visible item**: `pkg-size=<download MB>,<disk MB>` exactly as printed, and
   `pkg-what=<words>` for the sentence (default "packages from Termux"). `build-catalog.sh` refuses
   anything but two whole numbers, and a `pkg-what=` with no `pkg-size=`.
3. **A package from a repository a stock Termux does not have on** gets a hidden `pkg` part for
   the package that turns it on, with `repo=1`, and the part that needs it requires that one. The
   engine installs a `repo=1` package in a call of its own and reads the package lists again before
   the rest; without the flag, the plan's one call would fail on the package apt has not seen yet.
   `x11-repo` is the one in use (`root-repo` would be the next). Keep both parts `com.termux`
   unless the other edition's own repository has the packages.

### terminal-browser

terminal-browser is the archive item that pulls in large packages: its row requires
`electron42`, which requires `x11-repo`, and carries `pkg-size=153,862` from `pkg-weight.py`. It
first shipped with tlstore 0.17; an engine older than 0.16 cannot install it (0.15 would try
`x11-repo electron42` in one call and fail cleanly, and 0.13 refuses an archive).

## Pinning a readme or a hero picture

Most items just fetch the upstream README (`readme` stays `-`). Pin one when the upstream page
does not render well as-is — heavy badges, a build matrix, prose written for a browser — and a
`readme-skip` heading list alone is not enough.

1. **Write the trimmed readme.** A plain markdown file, following the item page's rendering rules
   (`docs/REVISION-6.md`, "Item").
2. **Make the hero, if the item wants an animated one.** From a short screen recording or gif of
   the item running:
   ```sh
   scripts/make-hero.sh clip.mp4 hero.png
   ```
   4 seconds, 12 fps, 600 px wide, looping APNG, full frames (needs `ffmpeg`).
3. **Commit both into this repository**, under `readme/<name>.md` and `hero/<name>.png`, add their
   lines to `SHA256SUMS` (`sha256sum readme/<name>.md hero/<name>.png >> SHA256SUMS`), and push.
   They are read raw from git at a tag, so the tag they are pinned at just has to contain the
   commit: the next store release's tag does, and so does any tag pushed for the purpose.
4. **Point `items.tsv` at them.** `readme` (and, for a hero picture pinned the same way, `picture`
   or `demo`) takes `binaries:<path>@<tag>` — a path with a slash resolves to that exact file in
   the repository at the tag, where a bare asset name resolves to the release asset
   `<asset>-<arch>` on a `bins-…` prerelease. Leave
   `readme-digest`/`demo-digest` alone: `build-catalog.sh` computes them from the same
   `SHA256SUMS`, by that repo-relative path, the way it already computes `picture-digest`.
5. **Build, test, release** as above. A pinned readme that fails its digest check on a phone is a
   hard error (the `tlstore picture` convention: no silent fall back to the upstream copy).

## Changing the engine or the UI

- Script changes: edit `engine/tlstore`, keep it POSIX (`dash`-clean), add a `scripts/test.sh`
  case, cut a release to re-sign. `TLSTORE_VERSION` in the script is what phones compare when
  they self-update from origin.
- UI changes: any file under `ui/src`, `ui/Cargo.toml` or `ui/Cargo.lock` changes the source hash
  baked into the binaries. Run `ANDROID_HOME=~/Android/Sdk bash scripts/build-ui.sh --install`
  before cutting a release, or `scripts/release.sh <tag> --prepare` refuses with a stale
  `dist/tlstore-ui-<abi>`. Never enable the `shot` feature in the shipped build.
- The launcher's installer rewrites everything on the phone when the launcher's package update
  time changes, and rewrites the UI binary whenever the bundled bytes differ; a same-version debug
  reinstall therefore still picks the new binary up on the next launcher start.

## Privileged items (priv=shizuku)

Some tools need the whole phone in view — btop wants every process, every mount and every network
interface, and a Termux uid only sees its own. A `binary` row with `priv=shizuku` in `options` is
run by the launcher as the shell uid (2000) instead. End to end:

1. **tlstore** downloads the binary to `~/.local/lib/tlstore/priv/<name>`, off PATH, and writes a
   wrapper at `~/.local/bin/<name>` that runs `exec "~/.local/bin/tl-priv" run "<that path>" "$@"`.
   Both files are recorded, `remove` deletes both, `info` names both. The row must `requires`
   `tl-priv` and carry `host=launcher` (plain Termux has no lane) and a `min-launcher=` naming the
   first launcher release that has one.
2. **tl-priv** (`recipes/cross/tl-priv/tl-priv.c`, built by `build-tl-priv.sh`; a hidden `binary`
   item) connects to the launcher's abstract unix socket `\0<package>.priv` and sends one line:
   `tlpriv1 <TAB> run <TAB> <path> <TAB> <TERM> <TAB> <rows> <TAB> <cols> [<TAB> <arg>]…`. It gets back
   `ok <pid>` with the pty master over `SCM_RIGHTS`, or `err <message>`, which it prints and exits
   126 with (127 when nothing listens). Then it relays the pty to the terminal in raw mode, forwards
   window-size changes, and exits with the code from the closing `exit <code>` line. Closing the
   socket ends the child.
3. **The launcher's service** (in `PickleHik3/termux-launcher`) copies the binary to
   `/data/local/tmp/tl/bin/<name>` and, through its Shizuku `UserService`, spawns it there in a pty
   as uid 2000 with `HOME=/data/local/tmp/tl/home/<name>`, `LANG=C.UTF-8` and `PATH=/system/bin`
   — no Termux prefix exists on that side, which is why the binary must be fully static with no
   prefix baked in (see `recipes/cross/README.md`). The launcher allowlists what it will run by the
   catalog digest: the row's `digest` is the identity the service checks against, so a rebuilt
   binary means a new tag, a new digest and a new catalog before it runs.

To add another one: build it static and prefix-free with a `recipes/cross/build-<name>.sh` (the
btop script is the model — Bionic's `libc.a` through the NDK's `-static`, and mind that Bionic has
no `pthread_cancel`), publish it under a tag, add a `binary` row with `priv=shizuku`, `requires`
`tl-priv`, `host=launcher` and `min-launcher=`, and note in the item's copy what the shell uid
cannot do — signal other uids' processes, for one. Anything the tool reads from `/sys` that Android
refuses the shell uid (btop's network counters, for instance) needs a `/proc` fallback patched in,
not a note. The engine's tests cover the install/remove shape (`privbin` in `scripts/test.sh`);
the lane itself is verified on a phone.

## Removing an item

Delete its row (and its parts, if nothing else needs them), rebuild, test, release. Phones that
have it installed keep it; `tlstore remove <name>` still works from the old catalog they cached.

## Retiring an item

Dropping the row is fine for something nobody has. For an item phones already installed, retire it
instead so `tlstore upgrade` takes it away for them: keep the row (same kind, source, target and
digest — build-catalog.sh still computes the digest normally) and set `options` to
`hidden=1;retired=1`. `hidden=1` is required alongside it, not just implied by it: an older engine
that has never heard of `retired=1` reads the row as an ordinary hidden part and leaves it alone,
so retiring never breaks a phone running an old tlstore. `install` refuses a retired item outright,
and nothing may pull it in through `requires`.

On a phone running the new engine, the next `tlstore upgrade` — or, without anyone asking, the next
`tlstore snapshot` the store UI runs when it opens (a retired row is hidden, so the UI never offers
it as an update) — deletes an installed
file/file-once/binary item only when the file on disk still matches the digest that shipped it —
an edited copy is left in place and the item is simply forgotten, never overwritten or deleted.
Anything else (a `pkg`, `bundle` or `fisher` item) just stops being tracked, the way `remove`
already leaves the underlying package installed. An `archive` is removed as `remove` removes it,
directory and wrapper: the directory is the store's, with no edit of yours in it to keep. A
`skill` goes the same way: its directory, and the links that still point into it. Once every phone has had a chance to update, the
row can be deleted for good (see "Removing an item" above).

## Release cut

A launcher release pins one `dist` tag from this repository in its own build (see `AGENTS.md`
here and the launcher's own docs for exactly where); nothing else is needed per launcher edition —
the catalog is edition-neutral except for `prefixes`, where a row can name one app package when a
binary is built per prefix (see `recipes/cross/README.md` in this repository).
