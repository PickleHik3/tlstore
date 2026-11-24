#!/bin/bash
# build-mesa-wayland-egl.sh — Termux's Mesa libEGL_mesa.so.0 rebuilt with one patch, packed as a
# small overlay for tlstore's mesa-wayland-egl item (an archive item), on a Linux host with Docker.
#
# Under Termux Launcher's Wayland Display there is no DRM render node, so stock Mesa's Wayland EGL
# falls back to llvmpipe. 0001-mesa-egl-wayland-kopper-dri2-without-render-node.patch (the patch
# Termux's packages/mesa would carry as 0020) makes the Wayland platform take the wl_shm + kopper
# path with the GPU's Vulkan device when LIBGL_KOPPER_DRI2=1 is set, the way X11 already does. It
# touches src/egl/drivers/dri2/platform_wayland.c only; every other library of the package is
# byte for byte the stock one, so the overlay is that one library.
#
# The build is Termux's own: termux-packages at the pinned commit, the patch added to
# packages/mesa, then `./scripts/run-docker.sh ./build-package.sh -I -a <arch> mesa` in Termux's
# package-builder image (about 15 minutes, a 10 GB image). The library comes out of the resulting
# mesa .deb.
#
# Output: $TL_OUT/mesa-wayland-egl, a .tar.gz with, at its top level,
#   lib/libEGL_mesa.so.0   the patched library
#   MESA_VERSION           one line, the Termux mesa package version (as dpkg reports it) built from
#   bin/tl-mesa-wayland    the program the item's wrapper runs; prints the lib directory
#
# EVERY TERMUX MESA BUMP: the patched library must be built from the same Mesa as the stock
# libgallium it loads beside (its DT_NEEDED names libgallium-<version>.so). When Termux moves its
# mesa package, move the two pins below together (TERMUX_PACKAGES_COMMIT to a termux-packages
# commit that has the new mesa; MESA_VERSION to that package's version), check the patch still
# applies, and rebuild the item. The launcher reads MESA_VERSION to know when the overlay is stale.
#
# The library has the com.termux prefix baked in (its tmp directory, its search path), so this is
# the com.termux edition's build only. Env: TL_ARCH (aarch64 default, or x86_64), TL_OUT,
# TL_BUILD_DIR. 32-bit arm is not built: tlstore serves aarch64 and x86_64 only.
set -euo pipefail

# The one pin: the Termux mesa package version this overlay targets. The commit below must have
# exactly that version; the script stops if the package it builds reports another.
MESA_VERSION=${MESA_VERSION:-26.3.1}
TERMUX_PACKAGES_URL="https://github.com/termux/termux-packages.git"
TERMUX_PACKAGES_COMMIT=${TERMUX_PACKAGES_COMMIT:-d85d18f456d732d26d8b87d826155c2ced0342e8}   # mesa 26.3.1, 2026-11-23

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PATCH="$SCRIPT_DIR/0001-mesa-egl-wayland-kopper-dri2-without-render-node.patch"
LAUNCHER_SCRIPT="$SCRIPT_DIR/mesa-wayland-egl/tl-mesa-wayland"

TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-mesa-wayland-egl"}
TL_ARCH=${TL_ARCH:-aarch64}
TL_TERMUX_ARCH=${TL_TERMUX_ARCH:-$TL_ARCH}
case "$TL_TERMUX_ARCH" in aarch64|x86_64) ;; *) echo "error: unsupported architecture $TL_TERMUX_ARCH" >&2; exit 2 ;; esac

for tool in git docker dpkg-deb tar gzip; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
done

mkdir -p "$TL_OUT" "$TL_BUILD_DIR"
src="$TL_BUILD_DIR/termux-packages"
if [ ! -d "$src/.git" ]; then
    rm -rf "$src"
    git init -q "$src"
    git -C "$src" remote add origin "$TERMUX_PACKAGES_URL"
fi
if [ "$(git -C "$src" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$TERMUX_PACKAGES_COMMIT" ]; then
    git -C "$src" fetch -q --depth 1 origin "$TERMUX_PACKAGES_COMMIT"
    git -C "$src" checkout -q --detach FETCH_HEAD
fi
[ "$(git -C "$src" rev-parse HEAD)" = "$TERMUX_PACKAGES_COMMIT" ] || {
    echo "error: the termux-packages checkout is not at $TERMUX_PACKAGES_COMMIT" >&2
    exit 1
}
# A rerun starts from the pinned mesa directory, without a patch an earlier run left there.
git -C "$src" clean -fdq packages/mesa
git -C "$src" checkout -q -- packages/mesa

# The commit must carry the mesa version this overlay says it targets (a revision, if any, is
# checked against the built .deb below).
pkg_version=$(sed -n 's/^TERMUX_PKG_VERSION=["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}$/\1/p' "$src/packages/mesa/build.sh" | head -1)
case "$MESA_VERSION" in
    "$pkg_version"|"$pkg_version"-*) ;;
    *) echo "error: termux-packages $TERMUX_PACKAGES_COMMIT has mesa $pkg_version, not $MESA_VERSION" >&2; exit 1 ;;
esac

# 0020 is free in Termux's mesa directory, and sorts after 0012, whose context the patch carries.
patch_name=0020-egl-wayland-kopper-dri2-without-render-node.patch
[ ! -e "$src/packages/mesa/$patch_name" ] || { echo "error: packages/mesa already has $patch_name" >&2; exit 1; }
cp "$PATCH" "$src/packages/mesa/$patch_name"

echo "Building mesa $MESA_VERSION for $TL_TERMUX_ARCH in Termux's package-builder image..."
(
    cd "$src"
    mkdir -p output
    rm -f output/mesa_*.deb
    ./scripts/run-docker.sh ./build-package.sh -I -a "$TL_TERMUX_ARCH" mesa
)

deb=$(find "$src/output" -name "mesa_*_$TL_TERMUX_ARCH.deb" | head -1)
[ -n "$deb" ] || { echo "error: the build left no mesa .deb under $src/output" >&2; exit 1; }
built_version=$(dpkg-deb -f "$deb" Version)
[ "$built_version" = "$MESA_VERSION" ] || {
    echo "error: the build made mesa $built_version, but MESA_VERSION is $MESA_VERSION" >&2
    exit 1
}

stage="$TL_BUILD_DIR/stage"
rm -rf "$stage" "$TL_BUILD_DIR/deb-x"
mkdir -p "$stage/lib" "$stage/bin" "$TL_BUILD_DIR/deb-x"
dpkg-deb -x "$deb" "$TL_BUILD_DIR/deb-x"
lib=$(find "$TL_BUILD_DIR/deb-x" -path '*/usr/lib/libEGL_mesa.so' -type f | head -1)
[ -n "$lib" ] || { echo "error: no libEGL_mesa.so in $deb" >&2; exit 1; }
cp "$lib" "$stage/lib/libEGL_mesa.so.0"
printf '%s\n' "$MESA_VERSION" > "$stage/MESA_VERSION"
cp "$LAUNCHER_SCRIPT" "$stage/bin/tl-mesa-wayland"
chmod 755 "$stage/bin/tl-mesa-wayland"
chmod 644 "$stage/lib/libEGL_mesa.so.0" "$stage/MESA_VERSION"

# Reproducible: sorted names, root ownership, no times, no name in the gzip header.
(cd "$stage" && tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 2020-01-01' \
    -cf - . | gzip -n -9 > "$TL_OUT/mesa-wayland-egl")

echo
echo "Built: $TL_OUT/mesa-wayland-egl (mesa $MESA_VERSION, $TL_TERMUX_ARCH)"
tar tzf "$TL_OUT/mesa-wayland-egl"
