#!/bin/bash
# build-phosh.sh — the native phosh desktop for TL_ARCH (aarch64 by default, or x86_64), as one
# .tar.gz archive tree (bin/, lib/, share/; docs/PHOSH.md, "Packaging"), built against a Termux
# sysroot with the NDK's clang.
#
# One function per upstream tree, built in this order, each with its own ordered patch directory
# next to this script, applied with `patch -p1` in file-name order:
#
#   phoc                    recipes/cross/phoc/                   built (M0)
#   gmobile, libfeedback    (phoc and phosh build gmobile as a meson subproject today)
#   phosh                   recipes/cross/phosh/                  M1
#   phosh-mobile-settings   recipes/cross/phosh-mobile-settings/  M4
#   tl-feedbackd            (this repository's own small daemon)  M3
#
# TL_PHOSH_TREES names the trees to build, in order (default: phoc). A tree that is not written yet
# stops the build instead of being skipped.
#
# M0 builds unpatched-in-spirit phoc 0.58.0: the tag as upstream tags it, plus the numbered patches
# in recipes/cross/phoc/ that make it compile and link against Bionic and Termux's sysroot, and
# nothing that changes what it does. The patches are git commits on the upstream tag, exported with
# `git format-patch` (rebase them with git when the pin moves, as docs/PHOSH.md describes):
#   0001  no libinput, libudev or libintl: Termux has none of the three and the X11 backend uses
#         none; src/compat/ declares what phoc names and answers "no such device" and "untranslated"
#   0002  the wlroots subproject's own two Bionic fixes (no librt, no shm_open), carried as wlroots
#         patch files that wlroots.wrap applies
#   0003, 0004  the output follows the X root window's size and scale (docs/PHOSH.md, "Size and
#         scale")
#   0005  wlroots' Vulkan renderer renders into shm buffers (docs/PHOSH.md, "phoc on the X11
#         display", Rendering), carried as a wlroots patch file
#
# What is built in:
#   - wlroots 0.20.2, the subproject phoc's wlroots.wrap names, linked statically: backends=x11
#     only (no DRM, libinput, session), renderers=vulkan (the Vulkan renderer, and pixman, which
#     wlroots always has; no GLES2), no allocators (no gbm, no udmabuf; the shm allocator is
#     always built), no libliftoff, color management or Xwayland, and xcb-errors off (Termux has
#     no xcb-util-errors; it only gives the X11 backend readable error names). The Vulkan
#     renderer links libvulkan.so (Termux's vulkan-loader-generic, with mesa-vulkan-icd-freedreno
#     for the GPU: a hidden part of the archive's package) and compiles its shaders with the
#     host's glslang (glslang-tools in CI). At start phoc tries Vulkan on the GPU and falls back
#     to pixman, logging the choice; WLR_RENDERER=pixman|vulkan forces one;
#   - gmobile v0.6.0_beta1 and gvdb, meson subprojects too, static;
#   - phoc's own xwayland option off: M0 runs Wayland clients only.
# The three subprojects are fetched by meson from the wraps phoc ships; their commits are pinned
# below and checked.
#
# Output: $TL_OUT/phosh, a .tar.gz (names sorted, one fixed mtime, numeric owner 0, gzip -n, so the
# same inputs give the same archive). Its top level is the app root, no leading directory.
#
# Needs on the host (CI installs them: .github/workflows/build.yml): meson >= 1.3, ninja,
# pkg-config, git, curl, patch, GNU tar, gzip, wayland-scanner and wayland's .pc files for the
# build machine, glib's host tools (glib-mkenums, glib-genmarshal, gdbus-codegen,
# glib-compile-resources, glib-compile-schemas), gettext (msgfmt) and desktop-file-utils.
# Env: TL_SYSROOT (the Termux sysroot, recipes/cross/termux-sysroot.sh -f phosh-deps.txt with
# TL_TERMUX_X11=1; required), TL_ARCH, TL_NDK, TL_OUT, TL_BUILD_DIR, TERMUX_PREFIX,
# TL_NATIVE_FILE (an extra meson native file, for a host whose glib tools are not where its .pc
# files say), TL_BUILD_JOBS.
set -euo pipefail

PHOC_VERSION="0.58.0"
PHOC_URL="https://gitlab.gnome.org/World/Phosh/phoc/-/archive/v$PHOC_VERSION/phoc-v$PHOC_VERSION.tar.gz"
PHOC_SHA256=a0e738e1e0b81b37ed7a7421e6fcaf113111809cec7c659371705c7cfc48fe5a
PHOC_COMMIT="d50d76a4add49add71b259df9cf67d58b3cbddfb"   # v0.58.0, the tag's commit
# The subprojects phoc's wraps fetch, pinned (checked after meson has fetched them).
WLROOTS_COMMIT="d783533489e1f75d6886c2ab5c5960090ef268f8"   # 0.20.2
# Every entry's mtime in the archive (2026-10-26). A fixed date, so a rebuild of the same pin is
# the same archive.
PHOSH_MTIME=1792972800

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

TL_ARCH=${TL_ARCH:-aarch64}
case "$TL_ARCH" in
    aarch64|x86_64) ;;
    *) echo "error: no phosh build for $TL_ARCH" >&2; exit 2 ;;
esac
NDK_VERSION=29.0.14206865
TL_NDK=${TL_NDK:-${ANDROID_NDK_HOME:-"${ANDROID_HOME:-$HOME/Android/Sdk}/ndk/$NDK_VERSION"}}
TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-phosh"}
TERMUX_PREFIX=${TERMUX_PREFIX:-/data/data/com.termux/files/usr}
TL_PHOSH_TREES=${TL_PHOSH_TREES:-phoc}
TL_SYSROOT=${TL_SYSROOT:-}
[ -d "$TL_SYSROOT$TERMUX_PREFIX/lib/pkgconfig" ] || {
    echo "error: no Termux sysroot at '$TL_SYSROOT$TERMUX_PREFIX' (TL_SYSROOT; build it with termux-sysroot.sh -f phosh-deps.txt)" >&2
    exit 1
}
NDK_BIN="$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
[ -d "$NDK_BIN" ] || { echo "error: NDK not found at $TL_NDK (set TL_NDK)" >&2; exit 1; }
for tool in meson ninja pkg-config git curl patch tar gzip wayland-scanner msgfmt; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is not on PATH" >&2; exit 1; }
done
command -v glslang >/dev/null 2>&1 || command -v glslangValidator >/dev/null 2>&1 || {
    echo "error: glslang is not on PATH (wlroots' Vulkan renderer compiles its shaders with it)" >&2
    exit 1
}
export TL_ARCH TL_NDK TL_SYSROOT TERMUX_PREFIX

mkdir -p "$TL_OUT" "$TL_BUILD_DIR"
jobs=${TL_BUILD_JOBS:-$(nproc)}
stage="$TL_BUILD_DIR/stage-$TL_ARCH"
cross_file="$TL_BUILD_DIR/cross-$TL_ARCH.ini"
"$SCRIPT_DIR/phosh-cross-file.sh" "$cross_file" >/dev/null

# fetch_tree <name> <url> <sha256> <version> <pin> — the pinned tarball, unpacked and patched into
# $TL_BUILD_DIR/<name>/source, once per (pin, patch set, script) as build-herdr.sh does it.
fetch_tree() {
    local name="$1" url="$2" sha="$3" version="$4" pin="$5"
    local dir="$TL_BUILD_DIR/$name" patch_dir="$SCRIPT_DIR/$name"
    local tarball="$TL_BUILD_DIR/$name-$version.tar.gz" patches=() p
    for p in "$patch_dir"/*.patch; do [ -f "$p" ] && patches+=("$p"); done
    local prepared="$pin $(cat "${patches[@]}" 2>/dev/null | sha256sum | cut -d' ' -f1) $(sha256sum < "${BASH_SOURCE[0]}" | cut -d' ' -f1)"
    SOURCE_DIR="$dir/source"
    if [ "$(cat "$SOURCE_DIR/.tl-prepared" 2>/dev/null || true)" = "$prepared" ]; then
        return 0
    fi
    rm -rf "$dir"
    mkdir -p "$dir"
    if [ ! -f "$tarball" ]; then
        echo "Fetching $name $version..."
        curl -fsSL -o "$tarball.tmp" "$url"
        mv "$tarball.tmp" "$tarball"
    fi
    echo "$sha  $tarball" | sha256sum -c - >/dev/null || {
        echo "error: the $name tarball does not match its pinned sha256" >&2
        rm -f "$tarball"
        exit 1
    }
    mkdir -p "$SOURCE_DIR"
    tar -xzf "$tarball" -C "$SOURCE_DIR" --strip-components=1
    for p in "${patches[@]}"; do
        echo "Applying $name/$(basename "$p")..."
        patch -p1 -s -d "$SOURCE_DIR" < "$p" || {
            echo "error: $(basename "$p") does not apply to $name $version; rebase it" >&2
            exit 1
        }
    done
    printf '%s\n' "$prepared" > "$SOURCE_DIR/.tl-prepared"
}

# check_pin <repo dir> <commit> <what> — a subproject meson fetched is the commit pinned above.
check_pin() {
    local got
    got=$(git -C "$1" rev-parse HEAD)
    [ "$got" = "$2" ] || {
        echo "error: $3 is at $got, pinned $2 (its wrap moved; update the pin after a look)" >&2
        exit 1
    }
}

build_phoc() {
    fetch_tree phoc "$PHOC_URL" "$PHOC_SHA256" "$PHOC_VERSION" "$PHOC_COMMIT"
    local build="$TL_BUILD_DIR/phoc/build-$TL_ARCH" native=()
    [ -z "${TL_NATIVE_FILE:-}" ] || native=(--native-file "$TL_NATIVE_FILE")

    echo "Configuring phoc $PHOC_VERSION for $TL_ARCH..."
    rm -rf "$build"
    # --prefix=/ with a DESTDIR keeps the archive's layout: bin/phoc, share/... The subprojects'
    # options go before the project's own so a missing subproject fails the configure, not later.
    meson setup "$build" "$SOURCE_DIR" --cross-file "$cross_file" "${native[@]}" \
        --prefix=/ --buildtype=release --wrap-mode=default \
        -Dtests=false -Dgtk_doc=false -Dman=false \
        -Dxwayland=disabled \
        -Dwlroots:default_library=static -Dgmobile:default_library=static \
        -Dwlroots:backends=x11 -Dwlroots:renderers=vulkan -Dwlroots:allocators= \
        -Dwlroots:session=disabled -Dwlroots:xcb-errors=disabled -Dwlroots:xwayland=disabled \
        -Dwlroots:color-management=disabled -Dwlroots:libliftoff=disabled \
        -Dwlroots:examples=false
    check_pin "$SOURCE_DIR/subprojects/wlroots-0.20.x" "$WLROOTS_COMMIT" "wlroots"

    echo "Building phoc..."
    ninja -C "$build" -j"$jobs"

    echo "Installing phoc into the stage..."
    DESTDIR="$stage" meson install -C "$build" --no-rebuild --strip >/dev/null
}

build_phosh() { echo "error: the phosh tree is built from M1 on" >&2; exit 1; }
build_phosh_mobile_settings() { echo "error: phosh-mobile-settings is built from M4 on" >&2; exit 1; }
build_tl_feedbackd() { echo "error: tl-feedbackd is built from M3 on" >&2; exit 1; }

rm -rf "$stage"
mkdir -p "$stage"
for tree in $TL_PHOSH_TREES; do
    case "$tree" in
        phoc) build_phoc ;;
        phosh) build_phosh ;;
        phosh-mobile-settings) build_phosh_mobile_settings ;;
        tl-feedbackd) build_tl_feedbackd ;;
        *) echo "error: unknown tree $tree in TL_PHOSH_TREES" >&2; exit 2 ;;
    esac
done

# --- the app tree ----------------------------------------------------------------------------
# meson install also put the static wlroots, gmobile's development files and its udev rules in the
# stage; none is needed to run phoc (wlroots is inside the binary). M1's phosh brings gmobile's
# shared library back when phosh needs it at run time.
rm -rf "$stage/include" "$stage/lib/pkgconfig" "$stage/lib/udev" "$stage"/lib/*.a "$stage"/lib/libgmobile*
find "$stage" -mindepth 1 -type d -empty -delete

# --- checks ---------------------------------------------------------------------------------
readelf="$NDK_BIN/llvm-readelf"
[ -x "$stage/bin/phoc" ] || { echo "error: no bin/phoc in the stage" >&2; exit 1; }
# The X11 backend is the only input and output phoc has; the build must have it, and must not
# have grown a libinput, libudev, libseat or libgbm dependency by accident.
grep -qa 'Starting X11 backend' "$stage/bin/phoc" || {
    echo "error: phoc has no X11 backend" >&2
    exit 1
}
# The Vulkan renderer's shm present path is in (a missing Vulkan header or glslang makes wlroots
# skip the renderer when it is not forced; with renderers=vulkan it fails the configure instead).
grep -qa 'presenting through shared memory' "$stage/bin/phoc" || {
    echo "error: phoc has no Vulkan renderer for the shm output" >&2
    exit 1
}
if "$readelf" -d "$stage/bin/phoc" | grep NEEDED | grep -E 'libinput|libudev|libseat|libgbm|libEGL|libGLES'; then
    echo "error: phoc links a library the X11-only build must not need" >&2
    exit 1
fi
# meson install drops the build and sysroot directories from RUNPATH; only the device prefix stays.
if "$readelf" -d "$stage/bin/phoc" | grep -E 'RUNPATH|RPATH' | grep -q "$TL_BUILD_DIR\|$TL_SYSROOT"; then
    echo "error: phoc's RUNPATH names a build directory" >&2
    exit 1
fi

# --- the archive ----------------------------------------------------------------------------
rm -f "$TL_OUT/phosh"
(
    cd "$stage"
    find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort \
        | tar --no-recursion -T - -cf - --format=gnu --mtime="@$PHOSH_MTIME" \
            --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w'
) | gzip -9n > "$TL_OUT/phosh"

echo
echo "Built: $TL_OUT/phosh (phoc $PHOC_VERSION for $TL_ARCH: $TL_PHOSH_TREES)"
"$readelf" -d "$stage/bin/phoc" | grep -E "NEEDED|RUNPATH" || true
ls -l "$TL_OUT/phosh"
sha256sum "$TL_OUT/phosh"
