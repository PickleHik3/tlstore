#!/bin/bash
# termux-sysroot.sh — assemble a Termux sysroot from published .deb packages, for aarch64 or, with
# TL_TERMUX_ARCH=x86_64, x86_64.
#
# The cross recipes need Termux's own headers and shared libraries, not the NDK's. The Termux
# package server publishes both inside ordinary Debian archives, so a sysroot is just a set of
# extracted .deb files — no Docker image and no termux-packages checkout are involved.
#
# Usage:
#   ./termux-sysroot.sh [package ...]
#
# With no arguments it installs the default set needed by the recipes in this directory.
# "-f FILE" reads package names from FILE instead (whitespace separated, "#" comments), as
# phosh-deps.txt does; names after the options are added to them. The
# sysroot is written to $TL_SYSROOT (default ./sysroot) and keeps the packages' absolute layout,
# so the prefix inside it is $TL_SYSROOT/data/data/com.termux/files/usr.
#
# For an edition that installs under another package name, point TL_TERMUX_REPO at that edition's
# repository instead of relocating this one: the .deb files, and the absolute paths inside their
# .pc files, carry the prefix they were built for. The VAJ edition's repository, for example:
#
#   TL_SYSROOT=$PWD/sysroot-vaj TL_CACHE=$PWD/debs-vaj \
#       TL_TERMUX_REPO=https://repo.pathayam.xyz ./termux-sysroot.sh
#
# then pass that sysroot and prefix to the build script:
#
#   TL_SYSROOT=$PWD/sysroot-vaj TERMUX_PREFIX=/data/data/io.vaj.tl/files/usr \
#       TERMUX_HOME=/data/data/io.vaj.tl/files/home ./build-fastfetch.sh
set -euo pipefail

TL_SYSROOT=${TL_SYSROOT:-"$PWD/sysroot"}
TL_TERMUX_REPO=${TL_TERMUX_REPO:-"https://packages.termux.dev/apt/termux-main"}
TL_TERMUX_ARCH=${TL_TERMUX_ARCH:-aarch64}
TL_CACHE=${TL_CACHE:-"$PWD/debs"}
# Termux's x11-repo (libxkbcommon, xwayland, xcb-util-*, ...) is a separate repository with its
# own index. TL_TERMUX_X11=1 makes it a second source after the main one; a package is taken from
# the first repository that has it. Off by default, so the recipes that need only the main
# repository, and other editions' repositories, behave as before.
TL_TERMUX_X11=${TL_TERMUX_X11:-0}
TL_TERMUX_X11_REPO=${TL_TERMUX_X11_REPO:-"https://packages.termux.dev/apt/termux-x11"}
TL_TERMUX_X11_DIST=${TL_TERMUX_X11_DIST:-x11}

# Enough to configure and link Fastfetch with ImageMagick 7, Chafa and zlib. Most of these are
# header-only from the compiler's point of view: Fastfetch dlopens the image libraries at runtime.
DEFAULT_PACKAGES=(
    zlib libandroid-support libandroid-glob libandroid-execinfo libandroid-wordexp-static
    imagemagick chafa glib libpng libjpeg-turbo libiconv libffi pcre2 freetype
    mesa mesa-dev libglvnd libglvnd-dev opengl vulkan-headers vulkan-loader-generic
    libx11 libxcb libxrandr libxrender libxext libxau libxdmcp xorgproto
    dbus pulseaudio libelf ocl-icd opencl-headers
)

for tool in curl python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: missing required tool: $tool" >&2; exit 1; }
done

# dpkg-deb is the obvious extractor but is not installed everywhere (no dpkg on Arch, for one).
# A .deb is an ar archive holding data.tar.*, so ar plus a tar that reads xz is a full substitute.
if command -v dpkg-deb >/dev/null 2>&1; then
    extract_deb() { dpkg-deb -x "$1" "$2"; }
elif command -v ar >/dev/null 2>&1 && command -v bsdtar >/dev/null 2>&1; then
    extract_deb() { ar p "$1" "$(ar t "$1" | grep '^data\.tar')" | bsdtar -xf - -C "$2"; }
else
    echo "error: no way to extract .deb files — install dpkg, or binutils and libarchive" >&2
    exit 1
fi

mkdir -p "$TL_SYSROOT" "$TL_CACHE"

# Each source is "<repo url> <dist> <index file>". The main repository keeps the index name it
# always had, so an existing cache still works.
repos=("$TL_TERMUX_REPO stable $TL_CACHE/Packages.gz")
if [ "$TL_TERMUX_X11" = 1 ]; then
    repos+=("$TL_TERMUX_X11_REPO $TL_TERMUX_X11_DIST $TL_CACHE/Packages-x11.gz")
fi
for entry in "${repos[@]}"; do
    read -r url dist index <<<"$entry"
    if [ ! -f "$index" ]; then
        echo "Fetching package index $url ($dist) for $TL_TERMUX_ARCH..."
        curl -fsS --max-time 120 \
            "$url/dists/$dist/main/binary-$TL_TERMUX_ARCH/Packages.gz" -o "$index"
    fi
done

packages=()
while [ $# -gt 0 ]; do
    case "$1" in
        -f)
            [ $# -ge 2 ] || { echo "error: -f needs a file" >&2; exit 2; }
            # shellcheck disable=SC2207
            packages+=($(sed 's/#.*//' "$2"))
            shift 2
            ;;
        *)
            packages+=("$1")
            shift
            ;;
    esac
done
if [ ${#packages[@]} -eq 0 ]; then
    packages=("${DEFAULT_PACKAGES[@]}")
fi

for package in "${packages[@]}"; do
    found=""
    for entry in "${repos[@]}"; do
        read -r url dist index <<<"$entry"
        filename=$(python3 -I - "$index" "$package" <<'PY'
import gzip, sys
index, want = sys.argv[1], sys.argv[2]
text = gzip.open(index, 'rt', errors='replace').read()
for block in text.split('\n\n'):
    fields = dict(line.split(': ', 1) for line in block.split('\n') if ': ' in line)
    if fields.get('Package') == want:
        print(fields['Filename'])
        break
PY
)
        if [ -n "$filename" ]; then
            found=1
            break
        fi
    done
    if [ -z "$found" ]; then
        echo "warning: $package is not in the index; skipping" >&2
        continue
    fi
    deb="$TL_CACHE/$(basename "$filename")"
    [ -f "$deb" ] || curl -fsS --max-time 300 "$url/$filename" -o "$deb"
    extract_deb "$deb" "$TL_SYSROOT"
    echo "installed $package"
done

echo
echo "Sysroot ready: $TL_SYSROOT"
for prefix in "$TL_SYSROOT"/data/data/*/files/usr; do
    # An if, not an &&: an unmatched glob must not fail the script under set -e.
    if [ -d "$prefix" ]; then
        echo "Prefix inside it: $prefix"
    fi
done
