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
| `build-tuios.sh` | tuios, the terminal window manager for agents (Go, `GOOS=android`, like kitten); `0001-tuios-android-cpu.patch` | Go + git (+ NDK for x86_64) |
| `build-tuios-cpu.sh` | `tuios-cpu` (`tuios-cpu/tuios-cpu.c`), the `/proc/stat` reader tuios's CPU meter gets through the lane, fully static | NDK |
| `build-btop.sh` | patched btop, fully static, for the launcher's Shizuku lane | NDK + GNU make |
| `build-tl-priv.sh` | `tl-priv`, the lane's client (`tl-priv/tl-priv.c`), fully static | NDK |
| `build-herdr.sh` | herdr, built from source for bionic (Rust, plus Zig 0.16.0 for libghostty-vt, which the script downloads and verifies itself), as a `.tar.gz` app tree behind a launcher script that turns its terminal notifications on in Termux Launcher; `0001-herdr-android.patch` | rustup (`<arch>-linux-android`), NDK, git, curl, xz, GNU tar, gzip |
| `build-phosh.sh` | the native phosh desktop as a `.tar.gz` archive tree (`bin/`, `share/`), built against the Termux sysroot of `phosh-deps.txt`. builds phoc 0.58.0 with its bundled wlroots 0.20.2 (X11 backend, pixman renderer, no libinput, udev or session) and, from M1, phosh 0.58.0 with the dropped features compiled out; one function per upstream tree, each with its own patch directory (`phoc/`, `phosh/`; `phosh-mobile-settings/`, M4); `TL_PHOSH_TREES` picks the trees | meson, ninja, pkg-config, wayland-scanner, glib's host tools, gettext, NDK, curl, git, GNU tar, gzip |
| `fetch-launcher-skills.sh` | the launcher's agent skills, one `.tar.gz` each, packed by the launcher's own `scripts/pack-agent-skills.sh` at a pinned commit (not built; the same on every processor) | git, GNU tar, gzip |
| `build-terminal-browser.sh` | terminal-browser as a `.tar.gz` app tree, from our fork: its JavaScript built as upstream releases it, `pixel.node` and `agent-browser` built for Android, Termux's `electron42` in place of upstream's Electron | rustup `<arch>-linux-android` + NDK, Node 22 + pnpm 10.13.1, GNU tar |

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

The x86_64 musl loader also carries `0003-musl-x86_64-legacy-syscalls.patch`: Android's x86_64 app
seccomp filter kills the legacy syscalls x86_64 Linux kept (access, poll, pipe, dup2, unlink,
mkdir, rename, select, fork, ...; aarch64 never had them), and Bun reaches some through musl's
`syscall()`. The patch makes libc itself use the modern calls (as on aarch64) and makes `syscall()`
translate the legacy numbers programs pass in; aarch64 is unaffected. `pause` and `vfork` are only
done inside libc: through `syscall()`, vfork cannot be made from C.

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
and bakes the prefix into its default paths. All three are fixed at
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

`sigye`, `kitten`, `tuios` and `herdr` are prefix-independent — no `RUNPATH`, no absolute prefix anywhere in either
binary (herdr's NEEDED entries are libc, libm and libdl) — so one build of each serves every edition. So is `terminal-browser`: its two native pieces
have no `RUNPATH` either, and `electron/pixel` finds Termux's Electron through `$PREFIX` at run
time (falling back to `com.termux`'s prefix only when it is unset).

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
verified statically only — `RUNPATH` and every baked `/data/data/...` string
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

**terminal-browser**

- The asset is a gzipped tar of the app root (`bin/`, `cli/`, `browser/`, `agent-browser/`,
  `assets/`, `skills/`, `scripts/`, `electron/pixel`, `tlstore/`, `TLSTORE-BUILD`), not a single
  binary; the catalog unpacks it and runs `bin/terminal-browser`. Names are sorted, every mtime is
  the pinned commit's, owners are numeric 0 and gzip stores no name or time, so the same inputs give
  the same archive.
- Built from our fork, `PickleHik3/terminal-browser` branch `tl` (an upstream release plus our
  changes, committed there rather than carried here as patches), so the fork's JavaScript ships
  too. The recipe runs what upstream's `scripts/release.sh` runs for the JavaScript, skills and
  assets — `pnpm install --frozen-lockfile` (scripts skipped: pixel's would fetch upstream's
  Electron), pixel's TypeScript, the two esbuild bundles with their source maps,
  `generate-skill.sh`, `copy-react-grab.sh` — and stages the tree as release.sh does, without
  electron or agent-browser. Needs Node 22+ and pnpm 10.13.1. At v0.13.4 the result matches
  upstream's Linux tarball byte for byte, but for the pieces replaced below. `VERSION` stays
  upstream's (`v0.13.4`): the browser compares it with upstream's latest release.
- Runs on Termux's `electron42` (42.x, x11 repository), not upstream's patched Electron 44, which is
  glibc. `electron/pixel` is a two-line script that execs `$PREFIX/lib/electron42/electron`.
- `pixel.node` is the fork's, built for Android: no clipboard image paste (arboard
  has no Android backend) and no POSIX shared memory (the frame transport probe falls back to file
  frames, which the launcher's terminal supports). libc++ is linked statically; the recipe fails if
  either native piece needs a library a phone does not have, or leaves a symbol undefined other
  than the `napi_*` ones Electron provides.
- `agent-browser` (what `terminal-browser action` runs) carries
  `0002-terminal-browser-agent-browser-android.patch`. Rust's `target_os` is `android` here, not
  `linux`, so agent-browser takes the fallbacks upstream wrote for other systems; the patch adds
  the one it forgot (a Playwright cache path).
- Both Rust builds use the stable toolchain, not the 1.93.1 `pixel/engine/rust-toolchain.toml`
  names.
- `terminal-browser upgrade` is refused by the launcher script (it would install upstream's glibc
  build), and telemetry is off unless `TERMINAL_BROWSER_NO_TELEMETRY` or `DO_NOT_TRACK` is set.
  It also points `XDG_RUNTIME_DIR` at the app's cache directory (agent-browser refuses socket
  paths over 103 bytes, which `~/.local/state` and `$TMPDIR` both exceed) and unsets `DISPLAY` and
  `WAYLAND_DISPLAY`, so Chromium always takes the headless ozone platform.

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

**tuios**

- Built like kitten: `GOOS=android` (a linux build dies on `faccessat2`, and on x86_64 on the legacy
  syscalls), android/arm64 linked by Go, android/amd64 by the NDK's clang (`TL_CGO_CC`). The plain
  `tuios` build of `cmd/tuios`, with goreleaser's ldflags, not `tuios-ghostty` (cgo) or
  `tuios-web`. Go comes from `setup-go` `stable` with `GOTOOLCHAIN=auto`, which fetches the
  toolchain go.mod asks for.
- `main.builtBy` is `tlstore`, so `tuios update` refuses ("an unknown build") instead of replacing
  the binary with upstream's linux one; `tlstore upgrade tuios` is the way.
- Android keeps `/proc/stat` from a Termux uid, so the dock's CPU meter would read `n/a`.
  `0001-tuios-android-cpu.patch` adds an Android-only fallback (`internal/app/sysinfo_android.go`):
  when `/proc/stat` cannot be opened it starts `~/.local/bin/tuios-cpu 250` (the wrapper the store
  writes for the hidden `priv=shizuku` item `tuios-cpu`, which runs the static helper as the shell
  uid through tl-priv), reads its samples (the `cpu` line, then a `.` line; CRLF through the pty),
  and feeds the same percent calculation. No helper, no lane or a dead helper (retried every 30
  s) leaves `CPU: n/a`; RAM reads `/proc/meminfo`, which is open. The helper ends when tuios does.
- The catalog has two `tuios` rows: `host=launcher`, requiring `tuios-cpu`, and `host=termux`
  with no requirement, since a `requires` on a part with no row on the host blocks the install.

**herdr**

- Built from source, not fetched. Upstream's release is a static musl binary, and Android's
  x86_64 app seccomp filter kills musl's direct legacy syscalls (poll, pipe, dup2, unlink, mkdir,
  access, epoll_wait, eventfd, fork, ...); a bionic build goes through the newer ones and runs.
  So `build-herdr.sh` builds `<arch>-linux-android` for both processors from the pinned upstream
  commit, linked by the NDK's clang as `build-sigye.sh` does.
- libghostty-vt is Zig, built by upstream's `crates/ghostty-vt/build.rs`. The script downloads
  Zig 0.16.0 (pinned by sha256; `ZIG` points it at one you have), lets Zig fetch libghostty-vt's
  dependencies into `$TL_BUILD_DIR/zig-cache` (Zig checks each against the content hash in
  upstream's `build.zig.zon`; a curl pre-fetch could not check more than a tarball digest), and
  builds with SIMD off (`LIBGHOSTTY_VT_SIMD=0`: the SIMD code needs the NDK's libc++).
- Upstream treats `target_os = "linux"` as the only Unix-with-procfs; a `sed` makes every such cfg
  in the Rust sources true on android too, and the build fails if one is left. The small hand
  patch `0001-herdr-android.patch` adds the two Android triples to `zig_target()`, leaves out the
  logind (zbus) shutdown monitor, and switches `herdr update` and the background update check off
  on Android: they would download upstream's musl release over this build. `herdr update` prints
  that the store updates herdr (`tlstore upgrade herdr`) and exits 1.
- A bump of the pins (`scripts/upstream-watch.sh --bump herdr`) moves `HERDR_COMMIT` and
  `HERDR_VERSION`; if the patch no longer applies, the build says so and the patch is rebased by hand.
- The asset is a gzipped tar of the app root, not the bare binary: the stripped binary as
  `libexec/herdr`, and `bin/herdr`, the script the catalog runs. It is packed as
  terminal-browser's is (sorted names, one fixed mtime, numeric owner 0, gzip -n), so the same
  inputs give the same archive.
- herdr writes its terminal notifications (`[ui.toast] delivery = "terminal"`) only for Ghostty,
  iTerm2, WezTerm and kitty, and nothing for any other terminal. When `TERM_PROGRAM` is
  `termux-launcher` and `KITTY_WINDOW_ID` is unset, `bin/herdr` sets `KITTY_WINDOW_ID=1`, so herdr
  writes kitty's OSC 99, which the launcher shows as an Android notification. herdr reads the
  variable for nothing else and removes it from every pane it starts.

## Redistribution

These scripts build from upstream sources on the machine that runs them, which is why the
repository ships patches rather than binaries. Publishing the resulting binaries is a different
act with obligations attached — `kitten` is GPLv3 and requires an offer of corresponding source,
and Chafa is LGPLv3. See [`../../THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md).

## phosh sysroot and meson cross files

`phosh-deps.txt` lists the Termux packages phoc needs at M0. `TL_TERMUX_X11=1 TL_TERMUX_ARCH=<arch>
./termux-sysroot.sh -f phosh-deps.txt` assembles them, taking each from the main repository or,
failing that, Termux's x11-repo (`TL_TERMUX_X11_REPO`, `TL_TERMUX_X11_DIST`). `TL_ARCH=<arch>
./phosh-cross-file.sh [out]` writes the meson cross file (NDK clang, API 26, pkg-config on the
sysroot through `sys_root`). `TL_ARCH=<arch> ./phosh-smoke.sh` does both and links
`phosh-smoke/` against wayland-client and pixman; it needs meson, ninja and pkg-config on the host.

`build-asset.sh phosh` runs the whole chain (sysroot, cross file, `build-phosh.sh`) and leaves
`phosh-<arch>`, a `.tar.gz`. phoc's meson wants libinput and libudev, which Termux does not have,
and the X11 backend uses neither: `phoc/0001` stands in for them (`src/compat/`, answering "no such
device"), and also supplies `libintl.h` (glib's `gi18n.h`), which neither Bionic nor Termux ships.
`phoc/0002` carries two fixes for the bundled wlroots (no `librt`, no `shm_open` on Bionic) as
patch files its wrap applies. xcb-util-errors is not built: `-Dwlroots:xcb-errors=disabled`, it
only names X11 errors. On a host whose glib tools are missing where its `.pc` files say (Arch
without `glib2-devel`), `TL_NATIVE_FILE=<meson native file>` points meson's build-machine
`pkg_config_path` at a copy of the `.pc` files that names the tools in the sysroot instead;
`build-phosh.sh` makes that file itself when the host has no `glib-mkenums` or `gdbus-codegen`.

`phoc/0003` and `phoc/0004` make phoc's output follow the X root window (docs/PHOSH.md, "Size and
scale"). 0003 is a wlroots patch file the wrap applies: the X11 backend starts the output at the
root's current size, selects StructureNotify on the root and, on the root's ConfigureNotify (what
RandR sends), resizes the output's window, which then asks phoc for the new mode. 0004 is phoc's
side: an X11 output's scale is width / 360 rounded down, at least 1, set at creation and again on
each such request, unless the output config sets a scale; `PHOSH_SCALE` (1 to 10, an integer or a
decimal) in phoc's environment overrides it, which is the hook for the settings app.
`phoc-xvfb-test.sh` builds phoc natively with the patches and checks the behaviour on an Xvfb
screen resized with `xrandr --fb` (needs Xvfb, xrandr, wlr-randr and wayland-info; exits 77 when a
tool is missing, 1 under `TL_XVFB_TEST_STRICT=1`).

`phoc/0005` is a wlroots patch file (`wlroots/tl/0004-vulkan-render-into-shm.patch`, applied by the
wrap) that lets wlroots' Vulkan renderer render into shm buffers, for the X11 backend without DRI3
(docs/PHOSH.md, "Rendering"): the frame is rendered in an internal image, copied into a staging
buffer by the same command buffer and from there into the shm buffer the backend presents.
`build-phosh.sh` builds wlroots with `-Dwlroots:renderers=vulkan` (Vulkan beside pixman), which needs
the sysroot's `vulkan-headers` and `vulkan-loader-generic` (already in `phosh-deps.txt`) and a host
`glslang` (`glslang-tools`; the shaders are compiled at build time). phoc then links
`libvulkan.so.1`, so the package must install `vulkan-loader-generic` and, for Adreno,
`mesa-vulkan-icd-freedreno` (kgsl Turnip) as hidden parts. At start phoc tries Vulkan and falls back
to pixman, logging `Renderer: ...`; `WLR_RENDERER=pixman|vulkan` forces one. The patch cannot be
exercised off a phone: the Pong (Adreno) check is owed.

M1 adds phosh 0.58.0 (`TL_PHOSH_TREES` defaults to `phoc phosh phosh-mobile-settings tl-feedbackd` from M3). `phosh/` is its patch set: the
wraps' revisions, the Bionic fixes (a `libintl.h` stand-in as a global argument so that the
subprojects see it, `memfd_create` by system call, no `exp10`), and meson options that compile out
what the launcher does not ship (`lockscreen`, `polkit`, `logind`, `osk`, `eds`, `calls`,
`bluetooth`, `location`, `vpn`, `hotspot`, `networkmanager`, `modemmanager`, `gudev`, all on in
upstream's build; the build turns them all off, plus upstream's `searchd` and the plugins). Termux
has no libnm, mm-glib, libgudev, polkit, libsystemd/elogind, PAM, evolution-data-server,
gnome-bluetooth or libcall-ui: `phosh-deps.txt` lists what it does have. The patches are commits on
the `v0.58.0` tag exported with `git format-patch --zero-commit --no-signature`; to move them to a
new tag, apply them to the old tag as commits (`git am`), `git rebase --onto <new tag>`, and export
again. `data/90_tl.gschema.override` (app-filter-mode `[]`, no screensaver lock, no screen
keyboard) is checked by the build against the sysroot's `org.gnome.desktop` schemas; compiling the
schemas into the session's `GSETTINGS_SCHEMA_DIR` is the session-file step, not done here.

M4 adds phosh-mobile-settings 0.58.0, built after phosh in the same stage. `phosh-mobile-settings/` is
its patch set, made like phosh's: the gmobile wrap's revision, the Bionic fixes (the `libintl.h`
stand-in, no `GLOB_PERIOD`, `libandroid-glob` and `libandroid-wordexp` from Termux), libfeedback
found next to the binary (`$ORIGIN/../lib`), then one meson option per panel
(`welcome-panel`, `lang-panel`, `alerts-panel`, `lockscreen-panel`, `osk-panel`, `convergence-panel`,
`sensors-panel`, `features-panel`, `updates-panel`, `about-panel`, all on in upstream's build) and a
commit for each that takes the panel, and the library only it needs, out: accountsservice and polkit
(language), libcellbroadcast (alerts), libpms (language, OSK, OS updates); libnm is only for the
GNOME Settings panels, which are off. The build turns them all off, which leaves the four panels
the launcher keeps: overview and apps (the app filter and hidden apps), quick settings (the top bar
page), compositor and feedback. It also builds without the device plugin and the tests. phosh's
`phosh-plugins` and `phosh-settings` `.pc` files, headers and libfeedback are copied from the stage
into `$TL_SYSROOT/tl-phosh-dev` for the build (the cross file's pkg-config wants every path inside the
sysroot) and removed afterwards. Its desktop file is in `share/applications` (it starts
`phosh-mobile-settings` from the session's `PATH`, with no D-Bus activation and no service file)
and shows in phosh's grid when `XDG_CURRENT_DESKTOP` is `Phosh`, which the session script sets.
The quick settings page lists phosh's quick-setting plugins, and the phosh build has none of
them (`-Dquick-setting-plugins=false`), so it is empty until phosh builds some.

The display scale is a new row in the compositor panel and a new gsettings key,
`mobi.phosh.MobileSettings display-scale` (a double: `0.0` is automatic, `1.0` to `10.0` is the
scale). Nothing writes `phoc.ini` and nothing sets phoc's environment from inside the app: the
session script that starts phoc (`phosh-session`, #8) reads the key and exports `PHOSH_SCALE=<value>`
when it is not `0.0`, which phoc reads when it starts (`phoc/0004`); a change applies the next time
the display starts. A scale in `phoc.ini` still wins over both.

M3 adds `tl-feedbackd/` (#13), this repository's own daemon: C with GLib and GIO only, a meson project
(`main.c`, `feedback-theme.{c,h}`, the D-Bus activation file). It owns `org.sigxcpu.Feedback` and
answers what libfeedback 0.8.1 asks of feedbackd (`TriggerFeedback`, `EndFeedback`, `Profile`,
`FeedbackEnded`, and `Feedback.Haptic.Vibrate`); each event of feedbackd's quiet (haptics) theme becomes
`POST /v1/vibrate` calls to launcherctl, one per pulse because the route takes a duration only, at most
28 a minute (launcherctl's limit is 30). `silent` suppresses haptics; without launcherctl events still end,
and the first failure is logged once. `build-phosh.sh` builds it last (`tl-feedbackd` in `TL_PHOSH_TREES`)
into `bin/tl-feedbackd` and `share/dbus-1/services/`; `phosh-session` starts it before phoc. The activation
file's `Exec=` is a shell line that finds the archive under `$HOME/.local/lib/phosh` (or `$PHOSH_APP`).
