# Cross-build recipes

The recipes in [`../termux`](../termux) build on the phone. These build the same tools on a Linux
host, for `aarch64` and `x86_64` Termux, and add `kitten`, which cannot practically be built
on-device.

They deliberately do **not** use Docker or a `termux-packages` checkout. Termux publishes its
headers and shared libraries as ordinary `.deb` archives, so a cross-build only needs the Android
NDK plus a sysroot assembled with `dpkg-deb -x`.

| Script | Produces | Toolchain |
|---|---|---|
| `termux-sysroot.sh` | `sysroot/` from published `.deb`s, from any edition's repository | curl, python3, dpkg-deb or ar+bsdtar |
| `build-fastfetch.sh` | patched Fastfetch with animated Kitty graphics | NDK + CMake + Ninja |
| `build-dawn.sh` | patched dawn, the markdown writing pad | NDK + CMake |
| `build-sigye.sh` | patched Sigye clock | rustup `<arch>-linux-android` + NDK |
| `build-kitten.sh` | kitty's standalone `kitten` client | Go + python3 (+ NDK for x86_64) |
| `build-btop.sh` | patched btop, fully static, for the launcher's Shizuku lane | NDK + GNU make |
| `build-tl-priv.sh` | `tl-priv`, the lane's client (`tl-priv/tl-priv.c`), fully static | NDK |

`btop` and `tl-priv` are edition-agnostic: both are linked `-static` against the NDK's Bionic
`libc.a`, have no interpreter, no `NEEDED` entries and no prefix baked in. They have to be — the
launcher copies `btop` to `/data/local/tmp/tl/bin/` and starts it as the shell uid with
`PATH=/system/bin` and no Termux prefix in sight (`docs/maintainer/catalog.md`, "Privileged
items"). One build of each serves every edition.

`fastfetch` and `dawn` are built once per launcher edition — see below. If you only want the
binaries, they are published for `aarch64` and `x86_64` as GitHub Release assets of this
repository — one
`bins-YYYY.MM.DD[-N]` prerelease per run of `.github/workflows/build.yml`, each asset under the
name the catalog installs it by — and the `tlstore` catalog installs them with a pinned digest.
`build-musl-loader.sh` builds the musl loader that lets npm-shipped musl binaries (Claude Code,
opencode) run inside a Termux prefix. Build them yourself when you want to audit the result,
target another prefix, or move a pin.

`build-asset.sh <tool> [edition]` is the one entry point the workflow uses: it runs the tool's
recipe (assembling the edition's sysroot first where one is needed) and writes the result under
its asset name — `<tool>-<arch>`, or `<tool>-<package>-<arch>` for an edition other than
`com.termux` — into `$TL_ASSETS`. `TL_ARCH` picks the processor (`aarch64` by default, or
`x86_64`) and every toolchain name is derived from it there, so the recipes carry no processor of
their own. The io.vaj.tl edition is aarch64 only. The same script runs on a laptop with `TL_NDK`
set:

```sh
cd /some/scratch/dir
/path/to/recipes/cross/build-asset.sh dawn io.vaj.tl     # -> assets/dawn-io.vaj.tl-aarch64
/path/to/recipes/cross/build-asset.sh btop               # -> assets/btop-aarch64
TL_ARCH=x86_64 /path/to/recipes/cross/build-asset.sh btop  # -> assets/btop-x86_64
```

Three things differ on x86_64 beyond names. Go will not link android/amd64 itself, so the x86_64
`kitten` is linked by the NDK's clang (`TL_CGO_CC`; kitty's Go code has no C, so this only links).
Android's x86_64 ABI has a 128-bit `long double` where musl's x86_64 code expects x87's 80-bit one,
so the x86_64 musl loader is compiled for `x86_64-linux-musl`, against the build host's own
`libgcc.a` (the NDK ships compiler-rt for Android targets only). And btop's GPU support, which
upstream offers on x86_64, stays off as on aarch64.

On the runner the musl loader is built with the NDK's clang standing in for Termux's (the recipe
names plain `clang` and a compiler-rt under `$PREFIX`; `build-asset.sh` puts a wrapper on `PATH`
and passes `LIBCC`).

```sh
cd /some/scratch/dir
/path/to/recipes/cross/termux-sysroot.sh
/path/to/recipes/cross/termux-sysroot.sh libcurl openssl zlib libnghttp2   # dawn
/path/to/recipes/cross/build-fastfetch.sh
/path/to/recipes/cross/build-dawn.sh
/path/to/recipes/cross/build-sigye.sh
/path/to/recipes/cross/build-kitten.sh
/path/to/recipes/cross/build-btop.sh
/path/to/recipes/cross/build-tl-priv.sh
```

Each script honours `TL_NDK`, `TL_SYSROOT`, `TL_OUT` and `TL_BUILD_DIR`. Sources are pinned to the
same commits as the on-device recipes and carry the same patches.

## One build per launcher edition

The editions install under different package names, so their prefixes differ:
`/data/data/com.termux/files/usr` and `/data/data/io.vaj.tl/files/usr`. That matters for two of
these. `fastfetch` links `libandroid-glob`, `dlopen`s the image libraries through its own `RUNPATH`,
and gets its home directory and login shell from `termux-pwd-polyfill.h`. All three are fixed at
link time, so a build for one prefix does not start under another — the linker cannot find
`libandroid-glob.so` and the process dies before `main`. `dawn` is the same story with one library:
it needs `libcurl`, Termux removes `LD_LIBRARY_PATH` on Android 7+, and so the `RUNPATH` is the only
thing that finds it.

Build the other editions by pointing both scripts at that edition's repository and prefix. The
sysroot has to come from the edition's own repository rather than a relocated copy of another,
because the absolute paths inside the packaged `.pc` files name the prefix they were built for:

```sh
TL_SYSROOT=$PWD/sysroot-vaj TL_CACHE=$PWD/debs-vaj \
    TL_TERMUX_REPO=https://repo.pathayam.xyz ./termux-sysroot.sh
TL_SYSROOT=$PWD/sysroot-vaj TL_OUT=$PWD/out-vaj \
    TERMUX_PREFIX=/data/data/io.vaj.tl/files/usr \
    TERMUX_HOME=/data/data/io.vaj.tl/files/home ./build-fastfetch.sh
TL_SYSROOT=$PWD/sysroot-vaj TL_OUT=$PWD/out-vaj \
    TERMUX_PREFIX=/data/data/io.vaj.tl/files/usr ./build-dawn.sh
```

Each result is uploaded as `<tool>-<package name>-<arch>` (`fastfetch-io.vaj.tl-aarch64`,
`dawn-io.vaj.tl-aarch64`), beside the unsuffixed `com.termux` asset. The tlstore catalog carries one
row per edition and picks between them by `$PREFIX`, skipping the item with a build hint for a
prefix nothing is published for.

`sigye` and `kitten` are prefix-independent — no `RUNPATH`, no absolute prefix anywhere in either
binary — so one build of each serves every edition.

## Why `kitten` is here and not in `../termux`

`kitten` is the Go binary programs shell out to — most visibly `kitten icat`, which file managers
and Fastfetch's `kitty-icat` logo type invoke. It is not in the Termux repositories.

Building it looks trivial (pure Go, no cgo) but is not: kitty's `*_generated.go` files are
gitignored and are produced by a generator that imports kitty's C extension, so a *built kitty* is
a prerequisite for building `kitten`. `./dev.sh build` handles that by downloading a self-contained
dependency bundle — on a host. Reproducing it inside Termux would mean building the whole kitty
desktop application on the phone.

The output must be an **android/arm64** binary. A linux/arm64 static build is the tempting choice —
it is what upstream publishes, and `kitten update-self` then works — but it does not survive on
Android:

```
SIGSYS: bad system call
syscall.faccessat2(…) → os/exec.findExecutable → imaging/magick.init
```

Go's `os/exec.LookPath` uses `faccessat2` when `GOOS=linux`, and Android's seccomp filter kills any
process that issues it. kitten probes for ImageMagick during package initialisation, so the crash
happens before the subcommand runs at all. Device-verified on Android 16 (2026-08-16): the
linux/arm64 build dies on `kitten icat`, the android/arm64 build renders correctly.

The price is that the android build is a PIE bound to `/system/bin/linker64` instead of a static
binary, and `kitten update-self` will 404 because upstream ships no android asset.

## Where to install the binaries

Install into `~/.local/bin`, not `$PREFIX/bin`:

- A first-launch or repair bootstrap deletes `$PREFIX` wholesale before extracting the bootstrap
  archive. `$HOME` is untouched, so `~/.local/bin` survives.
- `fastfetch` is a real Termux package. A binary dropped into `$PREFIX/bin` is silently replaced by
  the unpatched upstream build on the next `pkg install`/`pkg upgrade` of that package.

Put `~/.local/bin` ahead of `$PREFIX/bin` in `PATH`. The launcher's own `config.fish` template
already does this.

## Verified state of the current build

Built 2026-08-16 on a Linux host with NDK r27c (27.2.12479018), Go 1.26.5, Rust 1.97.1:

| Binary | Stripped size | Runtime dependencies |
|---|---|---|
| `fastfetch` | 1.7 MB | `libandroid-glob.so` + Bionic; ImageMagick and Chafa are `dlopen`ed |
| `sigye` | 6.1 MB | Bionic only |
| `kitten` | 25.7 MB (android/arm64) | Android's linker only — no `DT_NEEDED` entries |

The VAJ-edition `fastfetch` (`fastfetch-io.vaj.tl-aarch64`) was built 2026-09-01 with NDK
29.0.14206865 against a sysroot from `repo.pathayam.xyz`, 1.7 MB stripped, same dependencies. It is
verified statically only — `RUNPATH`, every baked `/data/data/...` string, and the polyfill check all
name `io.vaj.tl` — and has not been run on a device yet.

Device-verified 2026-08-16 on Pong (A065, Android 16), running inside the launcher's terminal:

- `kitten icat` and `kitten icat --unicode-placeholder` both render, exit 0, no stderr.
- `kitten icat --unicode-placeholder --passthrough tmux` renders **inside tmux** — the case Unicode
  placeholders exist for.
- `fastfetch --logo-type kitty` with an animated GIF renders and keeps animating after Fastfetch
  exits (9.4% of logo-area pixels changed between two screenshots taken after the prompt returned).
- `sigye` renders its clock.

## Known limitations

**Fastfetch**

- Configured for `android-24` to match Termux's own package. At that API level Bionic has no
  `pthread_timedjoin_np`, so CMake reports `networking timeout will not work`. Termux's packaged
  build has the same gap.
- The binary is edition-specific; see "One build per launcher edition" above.
- ImageMagick and Chafa are loaded with `dlopen` at run time, not linked. The binary therefore runs
  without them, but image logos need `pkg install imagemagick chafa`. A bootstrap wipe removes
  those libraries while leaving the binary in `~/.local/bin` — image logos then fail even though
  Fastfetch still starts.
- Use `"type": "kitty"`, not `"kitty-direct"`: the launcher does not implement Kitty's file-based
  transmission, only the in-band protocol.

**Sigye**

- Built against API 26 (the launcher's `minSdkVersion`), not 24.
- The `u` and `i` clipboard shortcuts shell out to `termux-clipboard-set`, which needs the
  `termux-api` package and the Termux:API add-on matching your edition. Without them Sigye keeps
  running and reports the clipboard as unavailable.

**btop**

- Runs only through the launcher's privileged lane (Shizuku running, Termux:Launcher granted);
  `tl-priv` exits 127 with a one-line message otherwise.
- The shell uid may look but not touch: kill, terminate, the signal menu and renice are removed by
  `0002-btop-no-process-signals.patch` — keys, buttons, help text and all. Process listing, sorting,
  filtering, the tree and the detail view stay.
- Network counters come from `/proc/net/dev` whenever `/sys/class/net/*/statistics` is refused
  (`0001`); the busiest-interface default and the `b`/`n` keys are untouched.
- `/apex/*` loop mounts are hidden from the disks box and `/data` is shown right after `/`
  (`0003`). GPU support is compiled out (upstream limits it to x86_64); battery, sensors and
  per-process fields degrade on their own when a file is unreadable.
- Bionic has no `pthread_cancel` or `pthread_timedjoin_np`; `0004` joins the runner thread with a
  timeout on the way out and never cancels. A stalled runner (a rare upstream recovery path) is
  abandoned rather than cancelled.
- Built against API 29 for the `getloadavg()` declaration; the static link means it still runs on
  the launcher's minimum Android.
- A phone terminal (63×28) is too narrow for mem and net beside proc, so `0006` stacks the shown
  boxes at full width whenever the terminal is narrower than the side-by-side layout needs, and
  lets the cpu box go down to 44 columns (the clock, battery and container name in its title row
  come back once it is 60 wide again). Stacked, the boxes need 8+8+6+7 rows for cpu, mem, net and
  proc, so the Android default is `shown_boxes = "cpu mem proc"` (fits 28 rows with a 12-row
  process list); all four fit from 29 rows, and `p` steps past presets that do not fit instead of
  stopping at a size error. The process detail pane needs a proc box at least 16 rows tall. An
  existing config file's `shown_boxes` and `presets` are honoured as before.

**kitten**

- Must be built for android/arm64; see above. A linux/arm64 build dies with `SIGSYS` on any
  subcommand.
- `kitten update-self` cannot work: upstream publishes no android asset.
- Upstream reports that `kitten icat` warns about being unable to create shared memory, since
  Android has no `/dev/shm`. The android/arm64 build did not emit that warning here; if it appears,
  the in-band fallback it drops to is the path the launcher implements.
- `kitten clipboard <file>` guesses MIME types from the file extension only.
- `kitten edit-in-kitty` cannot be backgrounded; its protocol is tied to the tty.
- `kitten @ …` remote control does nothing: the launcher implements no kitty remote-control
  endpoint. Use `launcherctl` and the terminal action registry instead.
- Every kitten that expects kitty's desktop application (window management, its own config
  parsing) is out of scope; only the terminal-facing kittens are meaningful here.

## Redistribution

These scripts build from upstream sources on the machine that runs them, which is why the
repository ships patches rather than binaries. Publishing the resulting binaries is a different
act with obligations attached — `kitten` is GPLv3 and requires an offer of corresponding source,
and Chafa is LGPLv3. See [`../../THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md).
