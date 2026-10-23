#!/bin/bash
# build-tuios-cpu.sh — build tuios-cpu, the CPU-counter helper tuios's meter reads through the
# privileged lane, for Android (aarch64, or x86_64 with TL_ARCH=x86_64) from a Linux host.
#
# tuios-cpu is plain C against Bionic alone and linked -static, like tl-priv: the launcher runs it
# as the shell uid in a directory with no Termux prefix, so it must have no prefix, no RUNPATH and
# no library outside the binary. One build serves every edition. The catalog installs it as a
# hidden priv=shizuku part; tuios starts its wrapper, ~/.local/bin/tuios-cpu, when /proc/stat is
# closed to it (recipes/cross/0001-tuios-android-cpu.patch).
#
# Requires: the Android NDK.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE="$SCRIPT_DIR/tuios-cpu/tuios-cpu.c"

TL_NDK=${TL_NDK:-"$HOME/Android/Sdk/ndk/29.0.14206865"}
TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-tuios-cpu"}
TL_ANDROID_API=${TL_ANDROID_API:-26}

NDK_BIN="$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
TL_ARCH=${TL_ARCH:-aarch64}
TL_TRIPLE=${TL_TRIPLE:-$TL_ARCH-linux-android}
CC="$NDK_BIN/$TL_TRIPLE$TL_ANDROID_API-clang"
[ -x "$CC" ] || { echo "error: NDK compiler not found at $CC (set TL_NDK)" >&2; exit 1; }
[ -f "$SOURCE" ] || { echo "error: source not found at $SOURCE" >&2; exit 1; }

mkdir -p "$TL_OUT" "$TL_BUILD_DIR"

echo "Building tuios-cpu..."
"$CC" -std=c11 -O2 -Wall -Wextra -static -o "$TL_BUILD_DIR/tuios-cpu" "$SOURCE"
"$NDK_BIN/llvm-strip" -o "$TL_OUT/tuios-cpu" "$TL_BUILD_DIR/tuios-cpu"

readelf="$NDK_BIN/llvm-readelf"
if "$readelf" -l "$TL_OUT/tuios-cpu" | grep -q INTERP || "$readelf" -d "$TL_OUT/tuios-cpu" | grep -q NEEDED; then
    echo "error: tuios-cpu is not static" >&2
    exit 1
fi

echo
echo "Built: $TL_OUT/tuios-cpu (static, edition-agnostic)"
