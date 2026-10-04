# tlstore

This repository (`PickleHik3/tlstore`, renamed from termux-launcher-binaries 2026-09-24; local
checkout at `~/Projects/termux-launcher/tlstore`) is
the self-contained home of `tlstore`, the little package store
[Termux Launcher](https://github.com/PickleHik3/termux-launcher) ships to install, list, update and
remove the terminal tools and configs it shows off but does not ship inside the APK: the POSIX
`sh` engine, the item catalog and its inputs, the Rust store UI, the release and maintainer
scripts, this design documentation, and the recipes for the prebuilt binaries the catalog installs
by pinned digest. The binaries themselves are GitHub Release assets, built here by
`.github/workflows/build.yml`; nothing built is committed.

`dist/` is what the launcher consumes: a tagged, signed release set built from the sources below
by `scripts/release.sh`, committed at the tag for the launcher's gradle fetch and attached to the
tag's GitHub Release for phones. The launcher pins one tag's `dist/` and reads only that; a phone
reads `releases/latest/download/` to refresh its catalog and to keep `tlstore` and `tlstore-ui`
current, whichever launcher version installed them.

## Sources vs. `dist/`

| Directory | What | Built by |
|---|---|---|
| `engine/tlstore`, `engine/trusted.pub` | The POSIX `sh` engine and the maintainer's minisign public key — hand-edited sources | you, in an editor |
| `scripts/items.tsv`, `scripts/pictures/` | The catalog's hand-maintained item list and hero pictures | you, in an editor |
| `ui/` | The Rust store UI crate (`tlstore-ui`) | `cargo`, via `scripts/build-ui.sh` |
| `dist/` | `tlstore`, `tlstore.minisig`, `catalog.tsv`, `catalog.tsv.minisig`, `trusted.pub`, `tlstore-ui-arm64-v8a`, `tlstore-ui-x86_64` — the release set a tag ships | `scripts/release.sh <tag>` — never hand-edited |
| `recipes/`, `SHA256SUMS`, `hero/`, `readme/` | How every binary is built; the digests of the published assets and of the pinned readmes and heroes; the small pinned files themselves | `.github/workflows/build.yml` publishes the binaries and writes their `SHA256SUMS` lines |

See `docs/maintainer/catalog.md` for the full workflow (adding an item, rebuilding a binary,
cutting a release, changing the engine or the UI) and `AGENTS.md` for build/test commands.

## Release flow, in short

Two workflows on GitHub, no laptop needed:

1. **`build.yml`** (`gh workflow run build.yml -f tools=all`, or a comma list) builds the named
   tools from `recipes/cross` on a runner, publishes them as the assets of one prerelease tagged
   `bins-YYYY.MM.DD[-N]`, and commits their `SHA256SUMS` lines and the moved `items.tsv` tags to
   `main`.
2. **`release.yml`** (`gh workflow run release.yml`) tests, rebuilds `tlstore-ui` if `ui/`
   changed, builds and signs the catalog and the script, commits `dist/`, tags, and creates the
   store's GitHub Release, marked latest, with `dist/` as its assets.

The same thing by hand, for the store release:

```sh
scripts/build-ui.sh --install         # only if ui/ changed
scripts/release.sh <tag> --prepare    # copies engine/tlstore + trusted.pub into dist/, builds
                                       # the catalog, checks tlstore-ui-<abi> freshness, writes
                                       # the UI digests into dist/tlstore
bash scripts/sign.sh                  # the developer runs this by hand — needs the passphrase
scripts/release.sh <tag>              # verifies the signatures, updates SHA256SUMS, prints
                                       # the lock block (tag + one sha256 line per dist file)
```

`release.sh` never tags or pushes; push a tag with the printed digests once you are ready, and the
launcher pins that tag's `dist/` by those digests.

## Prebuilt binaries, as release assets

Prebuilt `aarch64` binaries for the terminal tools the launcher shows off but does not ship inside
the APK: `kitten`, a Fastfetch patched to animate Kitty-protocol GIFs, the `dawn` writing pad, the
`sigye` clock and `btop` with its `tl-priv` client — plus the musl runtime that lets `tlstore` run
Claude Code and opencode inside a Termux prefix.

They exist because building them on a phone ranges from slow to impossible — `kitten` in particular
cannot practically be built in Termux at all, because kitty's generated Go sources come from a
generator that needs a built kitty first.

Each lives at `https://github.com/PickleHik3/tlstore/releases/download/<bins-tag>/<asset>`, on
the prerelease `.github/workflows/build.yml` made it in, and `tlstore` installs it from there
against the digest its catalog pins: a bare `binaries:<asset>@<tag>` source in `scripts/items.tsv`
resolves to exactly that URL with `-aarch64` appended, and its digest is the `<asset>-aarch64`
line of `SHA256SUMS`.

## What is published

| Asset | Version | Source |
|---|---|---|
| `kitten-aarch64` | kitty `v0.48.2` (`2cb1d95c`), unmodified | [kovidgoyal/kitty `v0.48.2`](https://github.com/kovidgoyal/kitty/tree/v0.48.2) |
| `fastfetch-aarch64` | Fastfetch `v2.67.0` + `recipes/termux/fastfetch/0001-kitty-animation.patch`, for the `com.termux` prefix | [fastfetch-cli/fastfetch `9c7cfb86`](https://github.com/fastfetch-cli/fastfetch/tree/9c7cfb864ff9154ffe951fae191c14d60bb91544) |
| `fastfetch-io.vaj.tl-aarch64` | the same build, for the `io.vaj.tl` prefix | [fastfetch-cli/fastfetch `9c7cfb86`](https://github.com/fastfetch-cli/fastfetch/tree/9c7cfb864ff9154ffe951fae191c14d60bb91544) |
| `dawn-aarch64` | dawn `0.1.3+0e958747` with the launcher's changes (clipboard, AI chat and editing, touch, data safety), for the `com.termux` prefix | [PickleHik3/dawn `d17ee4ae`](https://github.com/PickleHik3/dawn/tree/d17ee4ae9f29cb7da99edf7566d4d7ebf02a95c5), a fork of andrewmd5/dawn `0e958747` |
| `dawn-io.vaj.tl-aarch64` | the same build, for the `io.vaj.tl` prefix | [PickleHik3/dawn `d17ee4ae`](https://github.com/PickleHik3/dawn/tree/d17ee4ae9f29cb7da99edf7566d4d7ebf02a95c5) |
| `sigye-aarch64` | Sigye `v0.6.0` + `recipes/termux/sigye/0001-termux-clipboard.patch` | [am2rican5/sigye `0f0b8caa`](https://github.com/am2rican5/sigye/tree/0f0b8caaccb4ca01ab5d1fad1237c4a01a49766f) |
| `btop-aarch64` | btop `v1.4.7` + `recipes/cross/0001`–`0006-btop-*.patch`, fully static | [aristocratos/btop `6e39144a`](https://github.com/aristocratos/btop/tree/6e39144aaf5a6bc01b9f795010b0914431067183) |
| `tl-priv-aarch64` | `recipes/cross/tl-priv/tl-priv.c`, fully static | this repository |
| `musl-loader-aarch64` | musl `1.2.5` + `recipes/cross/0001-musl-ld-preload-var.patch` + prefix paths, for the `com.termux` prefix | [musl-1.2.5.tar.gz](https://musl.libc.org/releases/musl-1.2.5.tar.gz) |
| `musl-loader-io.vaj.tl-aarch64` | the same build, for the `io.vaj.tl` prefix | [musl-1.2.5.tar.gz](https://musl.libc.org/releases/musl-1.2.5.tar.gz) |
| `musl-libstdcxx-aarch64` | GCC `14.2.0` `libstdc++.so.6`, musl-linked, unmodified | [Alpine `libstdc++-14.2.0-r6`](https://pkgs.alpinelinux.org/package/v3.22/main/aarch64/libstdc++) |
| `musl-libgcc-aarch64` | GCC `14.2.0` `libgcc_s.so.1`, musl-linked, unmodified | [Alpine `libgcc-14.2.0-r6`](https://pkgs.alpinelinux.org/package/v3.22/main/aarch64/libgcc) |

Fastfetch, dawn and the musl loader are published twice because each carries a path fixed at build
time (a `RUNPATH`, or the resolver files under the prefix), so one build per install prefix is
needed; the rest are prefix-independent and serve every edition. `tlstore` reads `$PREFIX` and
installs the right one. Which tag each item is installed from is in `scripts/items.tsv`; the
tags differ per tool, since a build only republishes the tools it was asked for.

The last two are not built here and not patched: they are GCC's runtime libraries as Alpine
packages them, taken out with `recipes/cross/fetch-musl-runtime.sh` against a pinned digest. They exist
because a binary built for musl elsewhere wants musl's C++ library, and Termux's is a Bionic one the
musl loader cannot load.

`SHA256SUMS` covers every asset the catalog points at. `tlstore` verifies the digest its catalog
pins before installing anything, so a tampered file is refused rather than run.

Two more directories pin content the Item page shows, so the phone never depends on upstream
HEAD: `readme/<name>.md` is each upstream project's own README, fetched verbatim at the commit
this repository's tag pins (see `readme/SOURCES.md`), and `hero/<name>.png` is a short APNG made
from that project's own demo GIF for the items that have one (see `hero/SOURCES.md`). `tlstore`
resolves both through the catalog's `readme`/`readme-digest`/`demo-digest` columns and the
`binaries:<path>@<tag>` source form — a path with a slash is read raw from this repository at
that tag, where a bare asset name is a release asset.

## Installing

Through the store, which is the intended path:

```sh
tlstore install kitten dawn sigye
```

By hand, into `~/.local/bin` — where `tlstore` puts them, and never `$PREFIX/bin`, which a
bootstrap reinstall deletes whole and which APT owns the name `fastfetch` in:

```sh
mkdir -p ~/.local/bin
tag=$(sed -n 's/^kitten\t.*binaries:kitten@\([^\t]*\)\t.*/\1/p' scripts/items.tsv)   # its bins-… tag
curl -fsSLo ~/.local/bin/kitten \
  "https://github.com/PickleHik3/tlstore/releases/download/$tag/kitten-aarch64"
chmod +x ~/.local/bin/kitten
sha256sum ~/.local/bin/kitten     # compare against the kitten-aarch64 line of SHA256SUMS
```

Make sure `~/.local/bin` comes before `$PREFIX/bin` in `PATH`, or the APT `fastfetch` wins.

## Which editions these work on

- **`kitten`** — static Go, no shared-library dependencies at all. Runs on any edition.
- **`sigye`** — links only Bionic (`libc`, `libm`, `libdl`). Runs on any edition. Its `u` and `i`
  clipboard keys shell out to `termux-clipboard-get`/`-set`, so they need `termux-api`.
- **`dawn`** — one build per prefix, for the same reason as Fastfetch and with one library
  instead of several: it links `libcurl` (`pkg install libcurl`) and finds it through its own
  `RUNPATH`, because Termux clears `LD_LIBRARY_PATH` on Android 7+. The `com.termux` build does not
  start under `io.vaj.tl` and the other way round. Everything else it parses — markdown, YAML,
  regular expressions, images — is vendored into the binary. Copy and paste go through the terminal
  rather than the system: upstream shells out to `xclip`, which no phone has, so the patch replaces
  that with OSC 52. Termux Launcher answers it, including the read that makes paste work, unless
  that read has been turned off in its Terminal I/O settings.
  The AI chat (`Ctrl+/`, `Tab` switches between it and the note) talks to Termux Launcher's TAI by
  default, reading its address and optional token from `~/.launcherctl/`. It can answer about the
  note, rewrite the selected text, and write at the cursor; `Ctrl+Z` undoes an edit. To use any
  other OpenAI-compatible server instead, write `~/.config/dawn/ai.json`:
  `{"provider":"openai","base_url":"https://host/v1","api_key":"…","model":"…"}`. The key sits in
  that file in plain text, so `chmod 600` it. With TAI, `{"provider":"tai","model":"…"}` picks a
  model other than the default assistant.
- **`fastfetch`** — one build per prefix: `fastfetch-aarch64` for `com.termux`
  (`/data/data/com.termux/files/usr`), `fastfetch-io.vaj.tl-aarch64` for `io.vaj.tl`. Each has a
  `RUNPATH` into its own prefix and needs `libandroid-glob` there (`pkg install libandroid-glob`),
  so the wrong one does not start at all — the linker cannot find `libandroid-glob.so` and the
  process dies before `main`. Its home directory comes from `recipes/termux-pwd-polyfill.h` and is
  fixed at the same time, because Bionic reports `pw_dir="/data"` for an app uid and Fastfetch reads
  passwd in preference to `$HOME`. Image logos are loaded through `dlopen`, so
  `pkg install imagemagick chafa` is what makes the GIF logo work; without them Fastfetch falls
  back to text.

The Nix edition needs none of this — nixpkgs has kitty, fastfetch and their dependencies, and the
animated-logo build is a toolkit there.

Both fastfetch builds were rebuilt 2026-09-01 with the 8-bit depth fix (`SetImageDepth` before the
Kitty transmission), the `io.vaj.tl` one against a sysroot from that edition's own repository
(`https://repo.pathayam.xyz`); `kitten` and `sigye` were built 2026-08-16 with NDK `27.2.12479018`.

## The musl loader, and Claude Code

Claude Code is distributed only as a Bun-compiled binary linked against musl
(`@anthropic-ai/claude-code-linux-arm64-musl` on npm). Android has Bionic, not musl, so the binary
needs a musl dynamic loader — and stock musl does not work on Android either: it reads
`/etc/resolv.conf`, which does not exist there, so every DNS lookup times out, and it dies on the
Bionic library Termux puts in `LD_PRELOAD` (termux-exec). `recipes/cross/build-musl-loader.sh` builds
musl 1.2.5 with the resolver paths moved under the prefix and `LD_PRELOAD` renamed to
`MUSL_LD_PRELOAD`, so Termux's variable passes through untouched to every child shell and shebang
handling keeps working there. One loader per prefix, because the resolver path is a string in the
library. The loader is built natively in Termux (`pkg install clang make patch`), from any edition.

## opencode

opencode ships a musl build on npm (`opencode-linux-arm64-musl`), so it takes the same path as
Claude Code: the store downloads it, checks the registry's own sha512, and points its interpreter
at the loader. It needs one thing Claude Code does not — `libstdc++.so.6` and `libgcc_s.so.1`,
which is what the two library files above are for. `tlstore` copies them in beside the loader,
where the rpath it sets already looks.

Verified 2026-09-22 on a Nothing A065 running Android 16: the libraries resolve under the patched
loader, and `opencode --version` and `--help` run. Its own installer picks a build by asking `ldd`,
which on Android chooses the glibc one and fails, so the store makes that choice instead.

Claude Code itself is not in this repository: it is Anthropic's proprietary build, and at 208 MB it
is over GitHub's file limit anyway. `tlstore` downloads the npm tarball from
registry.npmjs.org, checks it against the registry's own sha512, points its interpreter at the
loader with `patchelf`, and installs a `~/.local/bin/claude` wrapper that turns off the built-in
updater (an updated binary would arrive unpatched and fail to start). Verified 2026-09-06 inside
the com.termux app process on a Nothing A065 running Android 16: startup, DNS, TLS to
api.anthropic.com, and the interactive UI.

## Codex

OpenAI's own `@openai/codex` on npm is a static musl binary that reads a hard-coded
`/etc/resolv.conf`, which Android does not have, and it cannot use our patched musl loader. So the
store installs the Android build from [DioNanos/codex-termux](https://github.com/DioNanos/codex-termux)
instead (`@mmmbuto/codex-cli-termux` on npm), through the `npm-android` kind: the registry's latest
version, checked against its sha512, with no loader and no `patchelf`, because the binaries are
Bionic ones that run as they are. Two files are kept from the package: `codex.bin` and
`codex-code-mode-host`, which has to sit in the same directory because Codex's code mode, on by
default, needs it for shell commands. The `~/.local/bin/codex` wrapper starts `codex.bin` with
`-c check_for_update_on_startup=false`, since Codex's own update check cannot be turned off any
other way and `tlstore update` is how it is updated. About 275 MB on disk.

Credit for making Codex run on Android goes to DioNanos (Davide A. Guglielmi) and
[codex-termux](https://github.com/DioNanos/codex-termux), Apache-2.0, a port of
[openai/codex](https://github.com/openai/codex). See `docs/adr/0004-codex-from-codex-termux-via-npm-android.md`.

## Known limits

- **`kitten update-self` fails.** These are `android/arm64` builds and upstream publishes no Android
  asset, so the updater 404s. Update by pulling a newer file from here.
  The Android build is not optional: a `linux/arm64` kitten dies with `SIGSYS: bad system call` on
  `faccessat2`, which Android's seccomp filter kills, and kitten issues it during package
  initialisation — so every subcommand crashes before it runs.
- **`dawn` needs `libcurl` present**, or it does not start: `pkg install libcurl`. `tlstore`
  installs it with the item; a hand-installed copy has to be given it.
- **`kitten @` does nothing useful.** There is no kitty remote-control endpoint to talk to.
- **`kitten clipboard`** guesses MIME types from file extensions.
- **Fastfetch's animation** relies on the terminal continuing playback on its own clock, which
  Termux Launcher does and most terminals do not.
- **Fastfetch places its logo through Kitty's Unicode placeholders** (`U=1`), the mechanism
  `kitten icat --unicode-placeholder` uses, so the terminal must implement placeholders and not
  only the graphics protocol. One that ignores `U=1` stores the image, draws nothing, and shows
  the placeholder cells as missing glyphs. Set `"printRemaining": true` when the logo is taller
  than the module list, or the shell prompt clears the bottom of it.

## Corresponding source

`kitten` is GPL-3.0-only. The complete corresponding source is kitty at tag `v0.48.2`, unmodified:

```sh
git clone --depth 1 --branch v0.48.2 https://github.com/kovidgoyal/kitty
```

`dawn` is MIT, so its modified source is not an obligation, but it is public: the fork
[PickleHik3/dawn](https://github.com/PickleHik3/dawn), branch `tl`, carries every change as a commit on
top of andrewmd5/dawn `0e958747`:

```sh
git clone --branch tl https://github.com/PickleHik3/dawn && cd dawn
git checkout d17ee4ae9f29cb7da99edf7566d4d7ebf02a95c5
git submodule update --init --recursive
```

`recipes/` holds the exact scripts these binaries were produced with, including the sysroot
assembly and every flag. They need a Linux host with the Android NDK, Go, and rustup — no Docker
and no `termux-packages` checkout.

If any source here becomes hard to obtain, open an issue and it will be provided.

## Licences

- kitty / `kitten` — GPL-3.0-only, `licenses/kitty-GPL-3.0-only.txt`
- Fastfetch — MIT, `licenses/fastfetch-MIT.txt`, modified by `recipes/termux/fastfetch/0001-kitty-animation.patch`
- Sigye — MIT, `licenses/sigye-MIT.txt`, modified by `recipes/termux/sigye/0001-termux-clipboard.patch`
- dawn — MIT, `licenses/dawn-MIT.txt`, modified in the fork [PickleHik3/dawn](https://github.com/PickleHik3/dawn) (branch `tl`)
- `libstdc++.so.6` and `libgcc_s.so.1` — GCC 14.2.0, GPL-3.0-or-later with the GCC Runtime Library
  Exception, `licenses/gcc-runtime-GPL-3.0-with-exception.txt`, unmodified. The corresponding
  source is GCC 14.2.0 as Alpine builds it:
  [aports `main/gcc`](https://gitlab.alpinelinux.org/alpine/aports/-/tree/v3.22-stable/main/gcc)
  over [gcc-14.2.0.tar.xz](https://ftp.gnu.org/gnu/gcc/gcc-14.2.0/gcc-14.2.0.tar.xz)

Codex is fetched on the phone from its author's npm release (codex-termux, Apache-2.0) and is not
redistributed by this repository.

Fastfetch loads Chafa (LGPL-3.0-or-later) and ImageMagick (`ImageMagick` licence) through `dlopen`
at runtime; neither is linked into or redistributed with the binary here.

These are convenience builds of other people's software. They carry no warranty, and bugs in them
are this repository's problem, not upstream's — report them
[here](https://github.com/PickleHik3/tlstore/issues).

## Recipes

`recipes/` is how every binary here is built, moved from the launcher repository so the
sources and the artefacts live together:

- `recipes/cross/` — host cross-builds with the Android NDK: fastfetch, dawn, sigye, kitten, the
  musl loader, and `termux-sysroot.sh` that assembles a sysroot from Termux's own `.deb`s.
- `recipes/termux/` — the same tools built on the phone, in Termux.
- `recipes/nix/` — the Nix edition's overlay.

Each `cross` script honours `TL_NDK`, `TL_SYSROOT`, `TL_OUT` and `TL_BUILD_DIR`; see
`recipes/cross/README.md`.
