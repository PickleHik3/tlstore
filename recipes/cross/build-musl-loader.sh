#!/data/data/com.termux/files/usr/bin/sh
# build-musl-loader.sh — build the musl dynamic loader that runs upstream musl
# binaries (Claude Code) inside a Termux prefix. Runs *inside* Termux on an
# aarch64 device: `pkg install clang make patch curl`. Any edition's Termux can
# build the loader for any prefix; only three path strings differ per prefix.
#
# Usage: TERMUX_PREFIX=/data/data/io.vaj.tl/files/usr ./build-musl-loader.sh
# Output: out/musl-loader-<app package>-<arch> (com.termux: out/musl-loader-<arch>), the asset
#         name tlstore fetches; installed as ld-musl-<arch>.so.1. <arch> is TL_ARCH, aarch64 by
#         default; build-asset.sh sets it, and hands in a `clang` and LIBCC for that processor.
#
# What is changed from upstream musl 1.2.5:
#   * /etc/resolv.conf and /etc/hosts -> $TERMUX_PREFIX/etc/... (Android has no
#     /etc/resolv.conf, so unpatched musl DNS times out).
#   * LD_PRELOAD is read from MUSL_LD_PRELOAD (recipes/cross/0001-musl-ld-preload-var.patch).
# libc.so *is* the loader in musl; it is shipped under the ld-musl name.
set -eu

MUSL_VERSION=1.2.5
MUSL_SHA256=a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TERMUX_PREFIX=${TERMUX_PREFIX:-/data/data/com.termux/files/usr}
APP_PACKAGE=${TERMUX_PREFIX#/data/data/}; APP_PACKAGE=${APP_PACKAGE%/files/usr}
TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-musl-$APP_PACKAGE"}
TL_ARCH=${TL_ARCH:-aarch64}

# musl links a handful of soft-float helpers from the compiler runtime; without
# LIBCC the final link fails on __floatditf/__multc3.
LIBCC=${LIBCC:-$(find "${PREFIX:-/data/data/com.termux/files/usr}/lib/clang" -name "libclang_rt.builtins-$TL_ARCH-android.a" | head -1)}
[ -n "$LIBCC" ] || { echo "error: compiler-rt builtins not found (pkg install clang)" >&2; exit 1; }

mkdir -p "$TL_OUT" "$TL_BUILD_DIR"
cd "$TL_BUILD_DIR"
tarball="musl-$MUSL_VERSION.tar.gz"
[ -f "$tarball" ] || curl -fsSLO "https://musl.libc.org/releases/$tarball"
echo "$MUSL_SHA256  $tarball" | sha256sum -c - >/dev/null
rm -rf "musl-$MUSL_VERSION"
tar xzf "$tarball"
cd "musl-$MUSL_VERSION"

patch -p1 -s < "$SCRIPT_DIR/0001-musl-ld-preload-var.patch"
sed -i "s|\"/etc/resolv.conf\"|\"$TERMUX_PREFIX/etc/resolv.conf\"|" src/network/resolvconf.c
sed -i "s|\"/etc/hosts\"|\"$TERMUX_PREFIX/etc/hosts\"|" src/network/lookup_name.c src/network/getnameinfo.c
grep -q "$TERMUX_PREFIX/etc/resolv.conf" src/network/resolvconf.c

CC=clang LIBCC="$LIBCC" ./configure --prefix=/nonexistent --disable-static >configure.log
make -j"$(nproc)" lib/libc.so >make.log 2>&1
case "$APP_PACKAGE" in
    com.termux) asset=musl-loader-$TL_ARCH ;;
    *)          asset=musl-loader-$APP_PACKAGE-$TL_ARCH ;;
esac
cp lib/libc.so "$TL_OUT/$asset"
echo "built $TL_OUT/$asset for $TERMUX_PREFIX"
