#!/bin/bash
# build-herdr-core.sh — herdr-core (`hc`), the terminal runtime under the Herdr desktop app, for
# TL_ARCH (aarch64 by default, or x86_64), built from source for <arch>-linux-android (bionic).
#
# One bare PIE per arch: interpreter /system/bin/linker64, NEEDED libc and libdl only, no prefix
# baked in, so one copy serves every launcher edition. The catalog installs it as ~/.local/bin/hc,
# the name people and agents type; herdr-app finds the core under that name too.
#
# What it takes, all of it in this script and its patch:
#   - upstream's Rust from the pinned commit below (upstream tags no releases in git), with the
#     cargo target <arch>-linux-android linked by the NDK's clang at API 29;
#   - libghostty-vt from the vendor/ghostty submodule, which crates/ghostty-vt/build.rs builds with
#     `zig build` for <arch>-linux-android: Zig 0.16.0, pinned by version and sha256 below. SIMD is
#     off there (its C++ needs the NDK's libc++). API 29, not the launcher's 26: Zig's objects use
#     native ELF TLS, which bionic loads only from Android 10, and only API 29's crtbegin carries
#     the 64-aligned .tdata ARM64 bionic requires (see build-herdr.sh);
#   - 0001-herdr-core-android.patch: the Linux cfgs also true on Android, the X11 socket under
#     $TMPDIR/$PREFIX, the Zig target, and `hc update` refused (the store updates hc; upstream's
#     release is a Linux build that cannot run here). `hc update --from` still works;
#   - 0001-ghostty-android-no-libc-stubs.patch, on vendor/ghostty: with SIMD off the vt module
#     links no libc, so wuffs exports hidden weak calloc/free stubs, and in the final executable
#     those win over bionic's for every caller (calloc returns null, free leaks). Not on Android.
#
# Requires: rustup with the <arch>-linux-android target, the Android NDK, git, curl, xz, and an
# x86_64 Linux host (the Zig download and the NDK's host tools).
set -euo pipefail

CORE_URL="https://github.com/herdrdev/herdr-core.git"
CORE_COMMIT="9ce385d9c8abb041dd4437476d770365b3fb5282"   # 0.1.18 on master
CORE_VERSION="0.1.18"
ZIG_VERSION="0.16.0"
ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCH="$SCRIPT_DIR/0001-herdr-core-android.patch"
GHOSTTY_PATCH="$SCRIPT_DIR/0001-ghostty-android-no-libc-stubs.patch"

TL_NDK=${TL_NDK:-"$HOME/Android/Sdk/ndk/29.0.14206865"}
TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-herdr-core"}
TL_ANDROID_API=${TL_ANDROID_API:-29}
TL_ARCH=${TL_ARCH:-aarch64}
case "$TL_ARCH" in
    aarch64|x86_64) ;;
    *) echo "error: no herdr-core build for $TL_ARCH" >&2; exit 2 ;;
esac
TL_TRIPLE=${TL_TRIPLE:-$TL_ARCH-linux-android}
triple_env=${TL_TRIPLE//-/_}
triple_env_upper=${triple_env^^}

NDK_BIN="$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
[ -d "$NDK_BIN" ] || { echo "error: NDK not found at $TL_NDK (set TL_NDK)" >&2; exit 1; }

export RUSTUP_TOOLCHAIN=${RUSTUP_TOOLCHAIN:-stable}
rustup target list --installed 2>/dev/null | grep -qx "$TL_TRIPLE" || {
    echo "error: rust target missing — run: rustup target add $TL_TRIPLE" >&2
    exit 1
}

mkdir -p "$TL_OUT" "$TL_BUILD_DIR"

# --- Zig ----------------------------------------------------------------------------------------
if [ -z "${ZIG:-}" ]; then
    [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] || {
        echo "error: no pinned Zig download for this host; set ZIG to a Zig $ZIG_VERSION" >&2
        exit 1
    }
    zig_dir="$TL_BUILD_DIR/zig-$ZIG_VERSION"
    if [ ! -x "$zig_dir/zig" ]; then
        tarball="$TL_BUILD_DIR/zig-x86_64-linux-$ZIG_VERSION.tar.xz"
        [ -f "$tarball" ] || curl -fsSL -o "$tarball" \
            "https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz"
        echo "$ZIG_SHA256  $tarball" | sha256sum -c - >/dev/null || {
            echo "error: the Zig tarball does not match its pinned sha256" >&2
            rm -f "$tarball"
            exit 1
        }
        rm -rf "$zig_dir" "$zig_dir.tmp"
        mkdir -p "$zig_dir.tmp"
        tar -xJf "$tarball" -C "$zig_dir.tmp" --strip-components=1
        mv "$zig_dir.tmp" "$zig_dir"
    fi
    ZIG="$zig_dir/zig"
fi
[ "$("$ZIG" version)" = "$ZIG_VERSION" ] || {
    echo "error: Zig $("$ZIG" version) at $ZIG, libghostty-vt needs $ZIG_VERSION" >&2
    exit 1
}
export ZIG
export ZIG_GLOBAL_CACHE_DIR="$TL_BUILD_DIR/zig-cache"

# --- the source ---------------------------------------------------------------------------------
source_dir="$TL_BUILD_DIR/source"
prepared="$CORE_COMMIT $(cat "$PATCH" "$GHOSTTY_PATCH" | sha256sum | cut -d' ' -f1) $(sha256sum < "${BASH_SOURCE[0]}" | cut -d' ' -f1)"
if [ "$(cat "$source_dir/.tl-prepared" 2>/dev/null || true)" != "$prepared" ]; then
    rm -rf "$source_dir"
    echo "Fetching herdr-core $CORE_VERSION ($CORE_COMMIT)..."
    git init -q "$source_dir"
    git -C "$source_dir" remote add origin "$CORE_URL"
    git -C "$source_dir" fetch -q --depth 1 origin "$CORE_COMMIT"
    git -C "$source_dir" checkout -q --detach FETCH_HEAD
    [ "$(git -C "$source_dir" rev-parse HEAD)" = "$CORE_COMMIT" ] || {
        echo "error: fetched a commit other than $CORE_COMMIT" >&2
        exit 1
    }
    git -C "$source_dir" submodule update -q --init --depth 1
    echo "Applying the Android patch..."
    git -C "$source_dir" apply "$PATCH" || {
        echo "error: 0001-herdr-core-android.patch does not apply to herdr-core $CORE_VERSION; rebase it" >&2
        exit 1
    }
    echo "Patching ghostty's wuffs libc stubs out of the Android build..."
    git -C "$source_dir/vendor/ghostty" apply "$GHOSTTY_PATCH" || {
        echo "error: 0001-ghostty-android-no-libc-stubs.patch does not apply to vendor/ghostty; rebase it" >&2
        exit 1
    }
    printf '%s\n' "$prepared" > "$source_dir/.tl-prepared"
fi

echo "Building..."
(
    cd "$source_dir"
    export "CARGO_TARGET_${triple_env_upper}_LINKER=$NDK_BIN/$TL_TRIPLE$TL_ANDROID_API-clang"
    export "CC_${triple_env}=$NDK_BIN/$TL_TRIPLE$TL_ANDROID_API-clang"
    export "AR_${triple_env}=$NDK_BIN/llvm-ar"
    cargo build --release --locked --target "$TL_TRIPLE" -p herdr-core
)

rm -f "$TL_OUT/herdr-core"
"$NDK_BIN/llvm-strip" -o "$TL_OUT/herdr-core" "$source_dir/target/$TL_TRIPLE/release/herdr-core"
chmod 755 "$TL_OUT/herdr-core"

echo
echo "Built: $TL_OUT/herdr-core (herdr-core $CORE_VERSION for $TL_ARCH)"
"$NDK_BIN/llvm-readelf" -d "$TL_OUT/herdr-core" | grep -E "NEEDED|RUNPATH" || true
ls -l "$TL_OUT/herdr-core"
sha256sum "$TL_OUT/herdr-core"
