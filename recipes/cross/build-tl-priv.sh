#!/bin/bash
# build-tl-priv.sh — build tl-priv, the client half of Termux:Launcher's privileged lane, for
# Android (aarch64, or x86_64 with TL_ARCH=x86_64) from a Linux host.
#
# tl-priv is plain C against Bionic alone — a unix socket, a pty relay and termios — and is linked
# -static, so it has no prefix, no RUNPATH and no library outside the binary: one build serves every
# edition. The catalog installs it as a hidden part that every priv=shizuku item requires; the
# wrapper tlstore writes for such an item execs it.
#
# Requires: the Android NDK.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE="$SCRIPT_DIR/tl-priv/tl-priv.c"

TL_NDK=${TL_NDK:-"$HOME/Android/Sdk/ndk/29.0.14206865"}
TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-tl-priv"}
TL_ANDROID_API=${TL_ANDROID_API:-26}

NDK_BIN="$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
TL_ARCH=${TL_ARCH:-aarch64}
TL_TRIPLE=${TL_TRIPLE:-$TL_ARCH-linux-android}
CC="$NDK_BIN/$TL_TRIPLE$TL_ANDROID_API-clang"
[ -x "$CC" ] || { echo "error: NDK compiler not found at $CC (set TL_NDK)" >&2; exit 1; }
[ -f "$SOURCE" ] || { echo "error: source not found at $SOURCE" >&2; exit 1; }

mkdir -p "$TL_OUT" "$TL_BUILD_DIR"

echo "Building tl-priv..."
"$CC" -std=c11 -O2 -Wall -Wextra -static -o "$TL_BUILD_DIR/tl-priv" "$SOURCE"
"$NDK_BIN/llvm-strip" -o "$TL_OUT/tl-priv" "$TL_BUILD_DIR/tl-priv"

readelf="$NDK_BIN/llvm-readelf"
if "$readelf" -l "$TL_OUT/tl-priv" | grep -q INTERP || "$readelf" -d "$TL_OUT/tl-priv" | grep -q NEEDED; then
    echo "error: tl-priv is not static" >&2
    exit 1
fi
# The protocol tag is a literal in the source, so its presence proves the right file was compiled.
if ! grep -qa 'tlpriv1' "$TL_OUT/tl-priv"; then
    echo "error: the protocol tag is missing from the build" >&2
    exit 1
fi

echo
echo "Built: $TL_OUT/tl-priv (static, edition-agnostic)"
