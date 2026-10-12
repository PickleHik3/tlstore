#!/bin/bash
# build-terminal-browser.sh — terminal-browser for Termux (aarch64, or x86_64 with TL_ARCH=x86_64),
# as one .tar.gz of its app tree, from a Linux host.
#
# terminal-browser (zenbu-labs/terminal-browser) is a JavaScript app run by Electron, plus two
# native pieces. Upstream's Linux tarball is glibc throughout, so this keeps its JavaScript, skills
# and assets as they are and replaces the rest:
#
#   electron/pixel        upstream's patched glibc Electron 44 (285 MB) is dropped; a two-line
#                         script execs Termux's own `electron42` package (x11 repo) instead
#   pixel.node            the pixel engine's napi addon, rebuilt from the pinned source for
#                         <arch>-linux-android with 0001-terminal-browser-pixel-android.patch
#                         (no clipboard images: arboard has no Android backend; no POSIX shm:
#                         the frame transport probe falls back to file frames)
#   agent-browser         vercel-labs/agent-browser, rebuilt for <arch>-linux-android with
#                         0002-terminal-browser-agent-browser-android.patch: Rust calls
#                         Android "android", not "linux", so it takes upstream's other-OS
#                         fallbacks, and one of them (a Playwright cache path) is missing
#   bin/terminal-browser  upstream's launcher, plus: `upgrade` is refused (tlstore updates this
#                         copy) and telemetry is off unless the user opts back in
#
# Upstream's JavaScript runs on Electron 42 unchanged: process.platform is "linux" there too, so
# the addon keeps its pixel-native-linux-<arm64|x64> path. Device-verified on Pong (A065,
# Android 16, aarch64), 2026-10-12: v0.13.4 with electron42 42.7.1 and a pixel.node built from this
# patch renders pages in the launcher's terminal; taps, typing, scrolling and Ctrl+Q all work.
#
# Both native pieces need nothing but Bionic: libc++ is linked statically (a phone has no
# libc++_shared.so), and the only undefined symbols pixel.node may keep are napi_*, which the
# Electron process provides when it loads the addon. Both are checked below.
#
# The archive's top level is the app root (bin/, cli/, browser/, ...; no leading directory),
# with sorted names, one fixed mtime (the pinned commit's), numeric owner 0 and gzip -n, so the
# same inputs give the same bytes.
#
# Requires: rustup with the <arch>-linux-android target on the stable toolchain, the Android
# NDK, git, curl, GNU tar, gzip.
set -euo pipefail

TB_VERSION=v0.13.4
TB_URL="https://github.com/zenbu-labs/terminal-browser.git"
TB_COMMIT="fd5f1798b128cd71508aa534ddbf67caf05ec0b8"   # v0.13.4
AB_VERSION=v0.38.1
AB_URL="https://github.com/vercel-labs/agent-browser.git"
AB_COMMIT="aff6125c023b810ea3f2e5deec5379e9a4270bdc"   # v0.38.1, the version upstream ships

TL_ARCH=${TL_ARCH:-aarch64}
# Upstream's release tarball for each processor, pinned by digest (the same files
# terminal-browser.sh/install serves for v0.13.4).
case "$TL_ARCH" in
    aarch64) TB_PLATFORM=linux-arm64
        TB_SHA256=0cf567d8218995a24fb6ce4b06c07ccf58a8c517906058087355f1e2fad1969f ;;
    x86_64)  TB_PLATFORM=linux-x64
        TB_SHA256=6277daaabab16711ab3f1961cdffad9efac5e70ac55d5076e2c86496d649d3a4 ;;
    *) echo "error: no pinned terminal-browser build for $TL_ARCH" >&2; exit 2 ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PATCH="$SCRIPT_DIR/0001-terminal-browser-pixel-android.patch"
AB_PATCH="$SCRIPT_DIR/0002-terminal-browser-agent-browser-android.patch"

TL_NDK=${TL_NDK:-"$HOME/Android/Sdk/ndk/29.0.14206865"}
TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-terminal-browser"}
TL_ANDROID_API=${TL_ANDROID_API:-26}
TL_TRIPLE=${TL_TRIPLE:-$TL_ARCH-linux-android}
# The names cargo and the cc crate read their per-target settings under.
triple_env=${TL_TRIPLE//-/_}
triple_env_upper=${triple_env^^}

NDK_BIN="$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
NDK_LIB="$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/$TL_TRIPLE"
[ -d "$NDK_BIN" ] || { echo "error: NDK not found at $TL_NDK (set TL_NDK)" >&2; exit 1; }

# pixel/engine pins 1.93.1 in rust-toolchain.toml; both builds use stable instead, the toolchain
# build.yml installs the Android target for (a native Termux build, which is what was verified,
# ignores the file as well).
export RUSTUP_TOOLCHAIN=${TL_RUST_TOOLCHAIN:-stable}
rustup target list --installed 2>/dev/null | grep -qx "$TL_TRIPLE" || {
    echo "error: rust target missing — run: rustup target add --toolchain $RUSTUP_TOOLCHAIN $TL_TRIPLE" >&2
    exit 1
}

mkdir -p "$TL_OUT" "$TL_BUILD_DIR"

# fetch <url> <commit> <dir> — a shallow checkout of one pinned commit.
fetch() {
    if [ ! -d "$3/.git" ]; then
        echo "Fetching $1 at $2..."
        git init -q "$3"
        git -C "$3" remote add origin "$1"
        git -C "$3" fetch -q --depth 1 origin "$2"
        git -C "$3" checkout -q --detach FETCH_HEAD
        return 0
    fi
    return 1
}

# --- 1. upstream's release tarball --------------------------------------------------------------
tarball="$TL_BUILD_DIR/terminal-browser-$TB_PLATFORM-$TB_VERSION.tar.gz"
[ -f "$tarball" ] || curl -fsSL -o "$tarball" \
    "https://github.com/zenbu-labs/terminal-browser/releases/download/$TB_VERSION/terminal-browser-$TB_PLATFORM.tar.gz"
echo "$TB_SHA256  $tarball" | sha256sum -c - >/dev/null

# --- 2. the sources -----------------------------------------------------------------------------
tb_src="$TL_BUILD_DIR/terminal-browser"
ab_src="$TL_BUILD_DIR/agent-browser"
if fetch "$TB_URL" "$TB_COMMIT" "$tb_src"; then
    echo "Applying the Android pixel patch..."
    git -C "$tb_src" apply "$PATCH"
fi
if fetch "$AB_URL" "$AB_COMMIT" "$ab_src"; then
    echo "Applying the agent-browser Android patch..."
    git -C "$ab_src" apply "$AB_PATCH"
fi

# --- 3. the two native pieces -------------------------------------------------------------------
cc="$NDK_BIN/$TL_TRIPLE$TL_ANDROID_API-clang"
export "CARGO_TARGET_${triple_env_upper}_LINKER=$cc"
export "CC_${triple_env}=$cc"
export "CXX_${triple_env}=$cc++"
export "AR_${triple_env}=$NDK_BIN/llvm-ar"
# The cc crate would link C++ code (openh264) against c++_shared; take the static libc++ and its
# ABI library instead. The path remaps keep the build machine's directories out of the binaries
# (Rust's panic locations, and the C asserts in tree-sitter and openh264).
export "CXXSTDLIB_${triple_env}=c++_static"
cargo_home=${CARGO_HOME:-$HOME/.cargo}
export "CARGO_TARGET_${triple_env_upper}_RUSTFLAGS=-C link-arg=-lc++abi --remap-path-prefix=$TL_BUILD_DIR=/build --remap-path-prefix=$cargo_home=/cargo"
export "CFLAGS_${triple_env}=-ffile-prefix-map=$TL_BUILD_DIR=/build -ffile-prefix-map=$cargo_home=/cargo"
export "CXXFLAGS_${triple_env}=-ffile-prefix-map=$TL_BUILD_DIR=/build -ffile-prefix-map=$cargo_home=/cargo"

# openh264 (page recording) assembles its x86 code with nasm when the host happens to have it and
# silently falls back to C when not; pin the C path so the x86_64 build does not depend on the
# host, and so no hand-written assembly with text relocations reaches Android's linker.
[ "$TL_ARCH" != x86_64 ] || export OPENH264_NO_ASM=1

echo "Building pixel-node..."
(cd "$tb_src/pixel/engine" && cargo build --release --locked --target "$TL_TRIPLE" -p pixel-node)
echo "Building agent-browser..."
(cd "$ab_src/cli" && cargo build --release --locked --target "$TL_TRIPLE" --bin agent-browser)

pixel_node="$TL_BUILD_DIR/pixel.node"
agent_browser="$TL_BUILD_DIR/agent-browser.bin"
"$NDK_BIN/llvm-strip" -o "$pixel_node" "$tb_src/pixel/engine/target/$TL_TRIPLE/release/libpixel_node.so"
"$NDK_BIN/llvm-strip" -o "$agent_browser" "$ab_src/cli/target/$TL_TRIPLE/release/agent-browser"

# check_bionic_only <file> <allowed undefined pattern> — every NEEDED entry is a system library
# and every undefined symbol either matches the pattern or is defined by one of those libraries
# (the NDK's stubs for API $TL_ANDROID_API stand in for the phone's).
check_bionic_only() {
    local file="$1" allow="$2" lib needed defined missing
    needed=$("$NDK_BIN/llvm-readelf" -d "$file" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
    echo "$(basename "$file") NEEDED: $(echo "$needed" | paste -sd' ' -)"
    defined=$(mktemp)
    for lib in $needed; do
        case "$lib" in
            libc.so|libm.so|libdl.so|liblog.so) ;;
            *) echo "error: $file needs $lib, which a phone does not have" >&2; exit 1 ;;
        esac
        "$NDK_BIN/llvm-nm" -D --defined-only "$NDK_LIB/$TL_ANDROID_API/$lib" | awk '{ print $NF }' | sed 's/@.*//' >> "$defined"
    done
    missing=$("$NDK_BIN/llvm-nm" -D --undefined-only "$file" | awk '$1 == "U" { print $2 }' \
        | sed 's/@.*//' | grep -Ev "$allow" | grep -vxFf "$defined" || true)
    rm -f "$defined"
    if [ -n "$missing" ]; then
        echo "error: $file leaves symbols nothing on a phone defines:" >&2
        echo "$missing" | head -20 >&2
        exit 1
    fi
}
check_bionic_only "$pixel_node" '^napi_'
check_bionic_only "$agent_browser" '^$'

# --- 4. the app tree ----------------------------------------------------------------------------
stage="$TL_BUILD_DIR/stage"
rm -rf "$stage"
mkdir -p "$stage"
# Everything of upstream's but its glibc binaries, without the leading terminal-browser/.
tar -xzf "$tarball" -C "$stage" --strip-components=1 \
    --exclude='terminal-browser/electron' \
    --exclude='terminal-browser/agent-browser/bin/agent-browser' \
    --exclude='terminal-browser/browser/node_modules/@zenbu-labs/*/pixel.node'

native_dir="$stage/browser/node_modules/@zenbu-labs/pixel-native-$TB_PLATFORM"
[ -d "$native_dir" ] || { echo "error: upstream's tarball has no $native_dir" >&2; exit 1; }
install -m 644 "$pixel_node" "$native_dir/pixel.node"
install -m 755 "$agent_browser" "$stage/agent-browser/bin/agent-browser"
install -m 644 "$ab_src/LICENSE" "$stage/agent-browser/LICENSE"
install -m 644 "$tb_src/LICENSE" "$stage/LICENSE"

mkdir -p "$stage/electron"
cat > "$stage/electron/pixel" <<'EOF'
#!/bin/sh
# Termux's Electron (pkg install electron42, from the x11 repository) in place of upstream's own.
# Chromium finds its resources through /proc/self/exe, so exec'ing it from here is enough.
exec "${PREFIX:-/data/data/com.termux/files/usr}/lib/electron42/electron" "$@"
EOF
chmod 755 "$stage/electron/pixel"

cat > "$stage/bin/terminal-browser" <<'EOF'
#!/bin/sh
# terminal-browser as tlstore ships it: upstream's launcher, run on Termux's Electron.
SELF="$0"
while [ -L "$SELF" ]; do
  LINK="$(readlink "$SELF")"
  case "$LINK" in
    /*) SELF="$LINK" ;;
    *) SELF="$(dirname -- "$SELF")/$LINK" ;;
  esac
done
ROOT="$(CDPATH= cd -- "$(dirname -- "$SELF")/.." && pwd -P)"

# Upstream's upgrade would install its glibc build over this one.
if [ "${1:-}" = upgrade ]; then
  echo "terminal-browser: this copy comes from tlstore; update it with: tlstore update" >&2
  exit 1
fi

# No usage reports or crash reports unless the user asks for them (set either variable,
# e.g. TERMINAL_BROWSER_NO_TELEMETRY=0, and this leaves the choice to upstream's settings).
if [ -z "${TERMINAL_BROWSER_NO_TELEMETRY+set}" ] && [ -z "${DO_NOT_TRACK+set}" ]; then
  export TERMINAL_BROWSER_NO_TELEMETRY=1
fi

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# The CLI puts agent-browser's socket under $XDG_RUNTIME_DIR (else ~/.local/state), and
# agent-browser refuses a socket path longer than 103 bytes: under ~/.local/state, or a
# $TMPDIR-based XDG_RUNTIME_DIR as termux-x11 setups use, `terminal-browser action` cannot
# connect. The app's own cache directory (/data/data/<package>/cache) is short enough, so it
# always wins; $PREFIX/tmp only if that cannot be written.
XDG_RUNTIME_DIR="${PREFIX%/files/usr}/cache"
if [ ! -d "$XDG_RUNTIME_DIR" ] || [ ! -w "$XDG_RUNTIME_DIR" ]; then
  XDG_RUNTIME_DIR="$PREFIX/tmp"
fi
export XDG_RUNTIME_DIR

# With neither set, the CLI starts Chromium with the headless ozone platform, the only one that
# works here; a termux-x11 DISPLAY would make Electron try X11.
unset DISPLAY WAYLAND_DISPLAY

export TERMINAL_BROWSER_DIST_ROOT="$ROOT"
export ELECTRON_RUN_AS_NODE=1

exec "$ROOT/electron/pixel" "$ROOT/cli/dist/main.js" "$@"
EOF
chmod 755 "$stage/bin/terminal-browser"

cat > "$stage/TLSTORE-BUILD" <<EOF
terminal-browser $TB_VERSION for $TL_TRIPLE, built by tlstore's recipes/cross/build-terminal-browser.sh
upstream tarball  terminal-browser-$TB_PLATFORM.tar.gz  sha256 $TB_SHA256
pixel.node        zenbu-labs/terminal-browser@$TB_COMMIT + 0001-terminal-browser-pixel-android.patch
agent-browser     vercel-labs/agent-browser@$AB_COMMIT ($AB_VERSION) + 0002-terminal-browser-agent-browser-android.patch
electron          Termux's electron42 package, \$PREFIX/lib/electron42/electron
EOF

# --- 5. the archive -----------------------------------------------------------------------------
mtime=$(git -C "$tb_src" log -1 --format=%ct)
(
    cd "$stage"
    find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort \
        | tar --no-recursion -T - -cf - --format=gnu --mtime="@$mtime" \
            --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w'
) | gzip -9n > "$TL_OUT/terminal-browser"

echo
echo "Built: $TL_OUT/terminal-browser (terminal-browser $TB_VERSION for $TL_TRIPLE)"
ls -l "$TL_OUT/terminal-browser"
sha256sum "$TL_OUT/terminal-browser"
