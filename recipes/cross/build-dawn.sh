#!/bin/bash
# build-dawn.sh — cross-compile the dawn markdown drafter for Termux aarch64 from a Linux host.
#
# The source is the PickleHik3/dawn fork, branch tl: upstream andrewmd5/dawn 0e958747 with the
# launcher's changes as commits (they used to be patches 0001-0009 here). The store still credits
# and stars andrewmd5/dawn — that is the catalog's `upstream` column, not this URL.
#
# dawn is plain C with its parsers vendored in, so the only library it needs from the device is
# libcurl. The AI chat is built in: upstream's chat talks only to Apple Intelligence, and the
# bridge patch points it at Termux Launcher's TAI instead, or at any OpenAI-compatible server
# named in ~/.config/dawn/ai.json. That one library is also the whole reason for a build per launcher edition: Termux
# removes LD_LIBRARY_PATH on Android 7+, so libcurl is found through DT_RUNPATH, and a RUNPATH
# naming another edition's prefix does not resolve.
#
# Requires: Android NDK, CMake, git, and a Termux sysroot from ./termux-sysroot.sh with libcurl:
#
#   ./termux-sysroot.sh libcurl openssl zlib libnghttp2
set -euo pipefail

DAWN_URL="https://github.com/PickleHik3/dawn.git"
DAWN_COMMIT="70fe1b0f8120ae169381bdff348d9904d3e2d431"   # tl: upstream 0e958747 (v0.1.3 plus fixes) + touch, data safety, P1, Material surfaces, bottom-sheet chat, scroll pill, warm session, voice, meaning index, the 2026-10-06 fixes, Nerd Font task boxes, storage robustness, EmbeddingGemma 2 meaning search, the status panel
# The version the binary reports (dawn -v): upstream's release plus the short fork commit, so the
# build names what it is made from. The catalog rows in scripts/items.tsv carry the same base with
# a build number (0.1.3+<commit>.N) that bins-record.sh bumps; when DAWN_COMMIT moves, move the
# base in items.tsv by hand too.
DAWN_VERSION_STRING="0.1.3+${DAWN_COMMIT:0:7}"

TL_NDK=${TL_NDK:-"$HOME/android-sdk/ndk/27.2.12479018"}
TL_SYSROOT=${TL_SYSROOT:-"$PWD/sysroot"}
TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-dawn"}
TL_ANDROID_API=${TL_ANDROID_API:-24}
TERMUX_PREFIX=${TERMUX_PREFIX:-/data/data/com.termux/files/usr}

PREFIX_IN_SYSROOT="$TL_SYSROOT$TERMUX_PREFIX"
[ -f "$PREFIX_IN_SYSROOT/lib/libcurl.so" ] || {
    echo "error: no libcurl in the sysroot at $PREFIX_IN_SYSROOT — run" >&2
    echo "       ./termux-sysroot.sh libcurl openssl zlib libnghttp2 first" >&2
    exit 1
}
[ -d "$TL_NDK" ] || { echo "error: NDK not found at $TL_NDK (set TL_NDK)" >&2; exit 1; }

mkdir -p "$TL_OUT" "$TL_BUILD_DIR"
source_dir="$TL_BUILD_DIR/source"

# A checkout left by an older pin (or by the patch-based recipe) is refetched, not reused.
if [ -d "$source_dir/.git" ] && [ "$(git -C "$source_dir" rev-parse HEAD 2>/dev/null)" != "$DAWN_COMMIT" ]; then
    rm -rf "$source_dir"
fi
if [ ! -d "$source_dir/.git" ]; then
    echo "Fetching dawn $DAWN_COMMIT..."
    git init -q "$source_dir"
    git -C "$source_dir" remote add origin "$DAWN_URL"
    git -C "$source_dir" fetch -q --depth 1 origin "$DAWN_COMMIT"
    git -C "$source_dir" checkout -q --detach FETCH_HEAD
    git -C "$source_dir" submodule update -q --init --recursive --depth 1
fi

# The same CMAKE_FIND_ROOT_PATH_MODE_* reasoning as build-fastfetch.sh: with BOTH, CMake finds the
# host's libcurl headers and the link then fails on a library that is not there. The RUNPATH is what
# makes libcurl resolve on device; without it dawn does not start at all.
echo "Configuring for $TERMUX_PREFIX..."
PKG_CONFIG_SYSROOT_DIR="$TL_SYSROOT" \
PKG_CONFIG_LIBDIR="$PREFIX_IN_SYSROOT/lib/pkgconfig" \
cmake -S "$source_dir" -B "$TL_BUILD_DIR/build" \
    -DCMAKE_TOOLCHAIN_FILE="$TL_NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM="android-$TL_ANDROID_API" \
    -DCMAKE_BUILD_TYPE=Release \
    -DDAWN_VERSION="$DAWN_VERSION_STRING"     -DUSE_LIBAI=ON \
    -DCMAKE_FIND_ROOT_PATH="$PREFIX_IN_SYSROOT" \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DCMAKE_C_FLAGS="-I$PREFIX_IN_SYSROOT/include" \
    -DCMAKE_EXE_LINKER_FLAGS="-L$PREFIX_IN_SYSROOT/lib -Wl,-rpath,$TERMUX_PREFIX/lib"

echo "Building..."
cmake --build "$TL_BUILD_DIR/build" -j"${TL_BUILD_JOBS:-$(nproc)}"

"$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" \
    -o "$TL_OUT/dawn" "$TL_BUILD_DIR/build/dawn"

# Upstream's POSIX clipboard shells out to xclip and xsel, neither of which exists on a phone. The
# patch replaces that path with OSC 52 through the terminal, and only for __ANDROID__ — so the query
# string is in the binary exactly when the patch took, and xclip is gone exactly then too.
if ! grep -qa ']52;c;?' "$TL_OUT/dawn"; then
    echo "error: the clipboard patch is missing from the build — copy and paste would be silent" >&2
    exit 1
fi
if grep -qa 'xclip' "$TL_OUT/dawn"; then
    echo "error: the xclip path is still in the build — the patch did not replace it" >&2
    exit 1
fi

# The chat is compiled out unless USE_LIBAI took effect, and then the panel simply never opens —
# so the endpoint path and the edit tool names must both be in the binary.
if ! grep -qa '/chat/completions' "$TL_OUT/dawn"; then
    echo "error: the AI bridge is missing from the build — the chat panel would never open" >&2
    exit 1
fi
if ! grep -qa 'replace_selection' "$TL_OUT/dawn"; then
    echo "error: the edit tools are missing from the build — the chat could read but not edit" >&2
    exit 1
fi

# TAI drops tools for most on-device models, so reading and editing the note must not need them:
# the note rides on every question and a plain reply edits through tagged blocks.
if ! grep -qa '<append_to_note>' "$TL_OUT/dawn"; then
    echo "error: the note-context patch is missing — a tool-less model would not see the note" >&2
    exit 1
fi

readelf="$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
if ! "$readelf" -d "$TL_OUT/dawn" | grep -q "Library runpath: \[$TERMUX_PREFIX/lib\]"; then
    echo "error: RUNPATH does not name $TERMUX_PREFIX/lib — libcurl would not resolve on device" >&2
    exit 1
fi

echo
echo "Built: $TL_OUT/dawn"
"$readelf" -d "$TL_OUT/dawn" | grep -E "NEEDED|RUNPATH" || true
