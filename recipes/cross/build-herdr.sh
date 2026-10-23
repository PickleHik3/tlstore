#!/bin/bash
# build-herdr.sh — herdr for TL_ARCH (aarch64 by default, or x86_64): built from source for
# <arch>-linux-android (bionic), as one .tar.gz app tree with a launcher script in front of it.
#
# herdr used to be upstream's static musl release binary, byte for byte. That one dies on the
# x86_64 Android build: the app's seccomp filter there kills the legacy syscalls musl's x86_64 code
# makes directly (poll, pipe, dup2, unlink, mkdir, access, epoll_wait, eventfd, fork, ...), where
# bionic goes through the newer ones (ppoll, pipe2, dup3, unlinkat, mkdirat, ...). So herdr is built
# against bionic here, for both processors: one PIE per arch, interpreter /system/bin/linker64,
# NEEDED libc, libm and libdl only, no prefix baked in, so one copy serves every launcher edition.
#
# What it takes, all of it in this script and its patch:
#   - upstream's Rust, from the pinned commit below (the tag's commit, not the moving tag), with
#     the cargo target <arch>-linux-android linked by the NDK's clang, as build-sigye.sh does;
#   - libghostty-vt, which crates/ghostty-vt/build.rs builds with `zig build`: Zig 0.16.0, pinned
#     by version and sha256 below and downloaded into the build directory unless $ZIG names one.
#     Zig fetches libghostty-vt's own dependencies itself, and checks every package against the
#     content hash in vendor/libghostty-vt/build.zig.zon (a pre-fetch with curl could only check
#     the tarball's digest, which upstream does not publish), into $TL_BUILD_DIR/zig-cache. SIMD is
#     off (LIBGHOSTTY_VT_SIMD=0): its C++ needs the NDK's libc++ and is not worth the weight here;
#   - every `target_os = "linux"` cfg in the Rust sources also true on android, by the sed below
#     (robust across upstream bumps: a bump needs no patch rebase for it). The build stops if one
#     is left that the sed did not reach, other than the two the patch gates on purpose;
#   - 0001-herdr-android.patch: the two Android triples in build.rs's zig_target(), no logind
#     (zbus) shutdown monitor (Android takes platform/mod.rs's no-op one), and `herdr update` and the background update check switched off,
#     because they would fetch upstream's musl release over this build. The store updates herdr
#     (`tlstore upgrade herdr`).
#
# The asset is an archive item (docs/SPEC.md, Revision 14), not the bare binary:
#
#   libexec/herdr   the built binary, stripped
#   bin/herdr       what the catalog's exe= runs: inside Termux Launcher it tells herdr it is in
#                   kitty (KITTY_WINDOW_ID), so herdr's [ui.toast] delivery = "terminal" writes
#                   kitty's OSC 99, which the launcher shows as an Android notification; herdr
#                   writes nothing for a terminal it does not know. Anywhere else it changes nothing
#
# The archive's top level is the app root (bin/, libexec/; no leading directory), with sorted
# names, one fixed mtime, numeric owner 0 and gzip -n, so the same inputs give the same archive
# (the binary itself is reproducible only as far as rustc and Zig are).
#
# Requires: rustup with the <arch>-linux-android target, the Android NDK, git, curl, GNU tar, xz,
# gzip, and an x86_64 Linux host (the Zig download and the NDK's host tools).
set -euo pipefail

HERDR_URL="https://github.com/herdrdev/herdr.git"
# scripts/upstream-watch.sh moves the pins below to upstream's latest release; keep their shape.
HERDR_COMMIT="2ecf19a92fc3a7fff75b6ce3655ef04f4625ec01"   # v0.9.5
HERDR_VERSION="0.9.5"
# The Zig upstream's libghostty-vt requires (the zig version in vendor/libghostty-vt/build.zig.zon),
# and the sha256 of its linux x86_64 tarball from https://ziglang.org/download/index.json.
ZIG_VERSION="0.16.0"
ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
# Every entry's mtime in the archive (2026-10-21, when the launcher script was added). A fixed
# date, not the time of the run, so a rebuild of the same pin is the same asset.
HERDR_MTIME=1792540800

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCH="$SCRIPT_DIR/0001-herdr-android.patch"

TL_NDK=${TL_NDK:-"$HOME/android-sdk/ndk/27.2.12479018"}
TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-herdr"}
# 29, not the launcher's 26: libghostty-vt's Zig objects use native ELF TLS, which bionic loads
# only from Android 10, and only API 29's crtbegin carries the 64-aligned .tdata ARM64 bionic
# requires of a TLS segment (an API 26 link aborts at start: "TLS segment is underaligned").
TL_ANDROID_API=${TL_ANDROID_API:-29}
TL_ARCH=${TL_ARCH:-aarch64}
case "$TL_ARCH" in
    aarch64|x86_64) ;;
    *) echo "error: no herdr build for $TL_ARCH" >&2; exit 2 ;;
esac
TL_TRIPLE=${TL_TRIPLE:-$TL_ARCH-linux-android}
# The names cargo and the cc crate read their per-target settings under.
triple_env=${TL_TRIPLE//-/_}
triple_env_upper=${triple_env^^}

NDK_BIN="$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
[ -d "$NDK_BIN" ] || { echo "error: NDK not found at $TL_NDK (set TL_NDK)" >&2; exit 1; }

# herdr's rust-toolchain.toml pins a toolchain (and components) rustup would have to install; the
# stable one is what CI and a laptop have, and builds it.
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
    echo "error: Zig $("$ZIG" version) at $ZIG, herdr's libghostty-vt needs $ZIG_VERSION" >&2
    exit 1
}
export ZIG
export ZIG_GLOBAL_CACHE_DIR="$TL_BUILD_DIR/zig-cache"
export LIBGHOSTTY_VT_SIMD=0

# --- the source ---------------------------------------------------------------------------------
source_dir="$TL_BUILD_DIR/source"
# What the prepared tree was made from: a changed pin, patch or script makes a new tree.
prepared="$HERDR_COMMIT $(sha256sum < "$PATCH" | cut -d' ' -f1) $(sha256sum < "${BASH_SOURCE[0]}" | cut -d' ' -f1)"
if [ "$(cat "$source_dir/.tl-prepared" 2>/dev/null || true)" != "$prepared" ]; then
    rm -rf "$source_dir"
    echo "Fetching herdr v$HERDR_VERSION ($HERDR_COMMIT)..."
    git init -q "$source_dir"
    git -C "$source_dir" remote add origin "$HERDR_URL"
    git -C "$source_dir" fetch -q --depth 1 origin "$HERDR_COMMIT"
    git -C "$source_dir" checkout -q --detach FETCH_HEAD
    [ "$(git -C "$source_dir" rev-parse HEAD)" = "$HERDR_COMMIT" ] || {
        echo "error: fetched a commit other than $HERDR_COMMIT" >&2
        exit 1
    }

    echo "Making the Linux cfgs true on Android..."
    # Every plain `target_os = "linux"` in the Rust sources becomes any(linux, android). Cargo.toml's
    # target-specific dependencies (zbus and the like) stay Linux only.
    find "$source_dir/src" "$source_dir/crates" "$source_dir/build.rs" -name '*.rs' -type f -print0 \
        | xargs -0 sed -i 's/target_os = "linux"/any(target_os = "linux", target_os = "android")/g'

    echo "Applying the Android patch..."
    git -C "$source_dir" apply "$PATCH" || {
        echo "error: 0001-herdr-android.patch does not apply to herdr $HERDR_VERSION; rebase it" >&2
        exit 1
    }

    # What is left must be the patch's own gates (platform/linux.rs, the logind monitor) and nothing
    # else: a plain Linux cfg the sed missed (one with no android in it) would be dead code on
    # Android.
    left=$(grep -rn 'target_os = "linux"' "$source_dir/src" "$source_dir/crates" "$source_dir/build.rs" --include='*.rs' \
        | grep -v 'target_os = "android"' \
        | grep -v '^[^:]*/src/platform/linux.rs:' || true)
    if [ -n "$left" ]; then
        echo "error: a plain target_os = \"linux\" cfg is left after the sed:" >&2
        printf '%s\n' "$left" >&2
        exit 1
    fi
    printf '%s\n' "$prepared" > "$source_dir/.tl-prepared"
fi

echo "Building..."
(
    cd "$source_dir"
    export "CARGO_TARGET_${triple_env_upper}_LINKER=$NDK_BIN/$TL_TRIPLE$TL_ANDROID_API-clang"
    export "CC_${triple_env}=$NDK_BIN/$TL_TRIPLE$TL_ANDROID_API-clang"
    export "AR_${triple_env}=$NDK_BIN/llvm-ar"
    cargo build --release --locked --target "$TL_TRIPLE"
)

# --- the app tree -------------------------------------------------------------------------------
stage="$TL_BUILD_DIR/stage-$TL_ARCH"
rm -rf "$stage"
mkdir -p "$stage/bin" "$stage/libexec"
# The basename stays herdr, the name the binary has always run under here.
"$NDK_BIN/llvm-strip" -o "$stage/libexec/herdr" "$source_dir/target/$TL_TRIPLE/release/herdr"
chmod 755 "$stage/libexec/herdr"

cat > "$stage/bin/herdr" <<'EOF'
#!/bin/sh
# herdr as tlstore ships it: built from upstream's source for Android, in ../libexec.
SELF="$0"
while [ -L "$SELF" ]; do
  LINK="$(readlink "$SELF")"
  case "$LINK" in
    /*) SELF="$LINK" ;;
    *) SELF="$(dirname -- "$SELF")/$LINK" ;;
  esac
done
ROOT="$(CDPATH= cd -- "$(dirname -- "$SELF")/.." && pwd -P)"

# herdr's terminal notifications ([ui.toast] delivery = "terminal") are written only for the
# terminals on its allowlist (Ghostty, iTerm2, WezTerm, kitty); for any other it writes nothing.
# Termux Launcher shows kitty's OSC 99 in the Android shade, so in the launcher herdr is told it
# runs in a kitty window. herdr reads KITTY_WINDOW_ID for nothing else, and removes it from every
# pane it starts, so the programs in its panes never see it.
if [ "${TERM_PROGRAM:-}" = termux-launcher ] && [ -z "${KITTY_WINDOW_ID+set}" ]; then
  export KITTY_WINDOW_ID=1
fi

exec "$ROOT/libexec/herdr" "$@"
EOF
chmod 755 "$stage/bin/herdr"

# --- the archive --------------------------------------------------------------------------------
rm -f "$TL_OUT/herdr"
(
    cd "$stage"
    find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort \
        | tar --no-recursion -T - -cf - --format=gnu --mtime="@$HERDR_MTIME" \
            --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w'
) | gzip -9n > "$TL_OUT/herdr"

echo
echo "Built: $TL_OUT/herdr (herdr $HERDR_VERSION for $TL_ARCH, as an app tree)"
"$NDK_BIN/llvm-readelf" -d "$stage/libexec/herdr" | grep -E "NEEDED|RUNPATH" || true
ls -l "$TL_OUT/herdr"
sha256sum "$TL_OUT/herdr"
