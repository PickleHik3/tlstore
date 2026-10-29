# AGENTS.md

This repository (`PickleHik3/tlstore`, renamed from termux-launcher-binaries 2026-09-24; local
checkout at `~/Projects/termux-launcher/tlstore`) is
the self-contained home of `tlstore`, Termux Launcher's package store: the engine, the catalog and
its inputs, the Rust store UI, the release/maintainer scripts, the design docs, and the recipes
for the prebuilt binaries the catalog installs — the binaries themselves are GitHub Release assets
built by `.github/workflows/build.yml`, never committed. `dist/` is the tagged, signed release set
the launcher consumes (and the assets of the store's GitHub Release, which phones read) —
everything else here is a source for it.

## Layout

| Path | What |
|---|---|
| `engine/tlstore`, `engine/trusted.pub` | The POSIX `sh` engine, and the maintainer's minisign public key. Edited by hand. |
| `scripts/items.tsv`, `scripts/pictures/` | The catalog's hand-maintained item list and hero pictures. |
| `scripts/*.sh` | Build, test, sign and release tooling — see below. |
| `ui/` | The Rust store UI crate, `tlstore-ui`. |
| `dist/` | `tlstore`, `tlstore.minisig`, `catalog.tsv`, `catalog.tsv.minisig`, `trusted.pub`, `tlstore-ui-arm64-v8a`, `tlstore-ui-x86_64` — the release set a tag ships. Never hand-edited; `scripts/release.sh` writes it. |
| `recipes/`, `licenses/`, `SHA256SUMS`, `hero/`, `readme/` | The recipes that build the showcase binaries (kitten, fastfetch, dawn, sigye, btop, tl-priv, the musl runtime), the digests of the published assets and pinned files, and the pinned readmes and hero pictures themselves. The binaries are release assets: `.github/workflows/build.yml` builds them (`recipes/cross/build-asset.sh`), publishes a `bins-…` prerelease and records it with `scripts/bins-record.sh`. |
| `.github/workflows/` | `ci.yml` (tests on every push), `build.yml` (binaries → release assets), `release.yml` (the signed store release). |
| `docs/` | Design docs: `SPEC.md` and `REVISION-5.md`/`REVISION-6.md` (engine and UI history and current design), `docs/maintainer/catalog.md` (the day-to-day workflow), `docs/maintainer/npm-items.md` (how npm items such as opencode are fetched, patched and updated on the phone), `docs/user/Tlstore.md` (user-facing), `docs/PHOSH.md` (the planned native phosh desktop item: keep/drop, launcherctl bridges, milestones), `docs/adr/` (architecture decisions). |

## Build and test commands

```sh
# Engine tests (POSIX sh, no framework) — run under sh, dash, busybox sh and bash --posix
bash scripts/test.sh
bash scripts/test-install.sh          # the standalone curl-pipe installer, same shells

# Catalog: rebuild from scripts/items.tsv against this repo's own SHA256SUMS
scripts/build-catalog.sh
scripts/build-catalog.sh /path/to/SHA256SUMS   # only if you need a different one

# UI crate (Rust) — from ui/
cd ui && cargo test
cargo run --features shot -- --shot 53x26 --screen item:<name> --out /tmp/item.png
cargo run --features shot -- --shot-all --out /tmp/frames/

# Rebuild the release UI binaries (needs the Android NDK; ANDROID_HOME defaults to
# ~/Android/Sdk if ANDROID_NDK_HOME is unset) — run after any change under ui/
ANDROID_HOME=~/Android/Sdk bash scripts/build-ui.sh --install

# Release flow — see docs/maintainer/catalog.md for the full walkthrough
scripts/release.sh <tag> --prepare    # copy sources into dist/, build the catalog, check
                                       # dist/tlstore-ui-<abi> freshness (scripts/check-dist.sh),
                                       # write the UI digests into dist/tlstore (embed-ui-digests.sh)
bash scripts/sign.sh                  # the developer runs this by hand — needs the passphrase
scripts/release.sh <tag>              # verify signatures, update SHA256SUMS, print the lock block

# On GitHub instead (the normal way): binaries first when a tool changed, then the store release
gh workflow run build.yml -f tools=all      # or tools=dawn,btop — publishes bins-… assets,
                                            # commits SHA256SUMS + items.tsv to main
gh workflow run release.yml                 # signs, commits dist/, tags, creates the release
```

`scripts/release.sh` never tags or pushes. Never generate or commit a signing key; the key at
`~/.config/vaj-apt/tlstore-minisign.key` is the maintainer's alone.

## Never run in an agent session

- `bash scripts/sign.sh` — needs the developer's passphrase.
- `scripts/release.sh <tag>` (the non-`--prepare` pass) — verifies signatures that must already
  exist from a human-run `sign.sh`.
- Never enable the `shot` cargo feature in a build meant to ship; it pulls in a bundled font and
  is dev-only.

## The launcher side

The launcher (`PickleHik3/termux-launcher`) pins one tag of this repository's `dist/` by digest and
consumes it read-only:

- `TlstoreInstaller` (`app/src/main/java/com/termux/app/store/TlstoreInstaller.java`) writes
  `dist/tlstore`, `dist/catalog.tsv`, `dist/trusted.pub` and the matching `dist/tlstore-ui-<abi>`
  into `$PREFIX` on every launcher start.
- `launcherctl` and the kitty graphics protocol implementation the store UI relies on (placements,
  animated frames, OSC 66 sized text) live in the launcher's own terminal emulator, not here — see
  `ui/CONTRACT.md` for exactly what tlstore-ui expects the terminal to support.
- Nothing in the launcher builds, tests or signs any of this; that all happens in this repository,
  and a release is consumed by tag.

## Agent skills

### Issue tracker

GitHub Issues on PickleHik3/tlstore, through the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default labels: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See
`docs/agents/triage-labels.md`.

### Domain docs

Single-context: a root `GLOSSARY.md` (created when a term is first settled) and `docs/adr/`. See
`docs/agents/domain.md`.
