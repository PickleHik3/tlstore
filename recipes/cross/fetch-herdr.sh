#!/bin/bash
# fetch-herdr.sh — take herdr's own Linux build for TL_ARCH (aarch64 by default, or x86_64) from
# its GitHub release.
#
# herdr is not built here. Upstream publishes one static musl binary per processor
# (herdr-linux-aarch64 is a static executable, herdr-linux-x86_64 a static PIE): no interpreter, no
# NEEDED entries, no prefix baked in, so it runs on Android as it is and one copy serves every
# launcher edition. Device-verified on Pong (A065, Android 16), 2026-10-09: the v0.9.3 aarch64
# asset, byte for byte, runs in the launcher's terminal. It is mirrored as a bins-… asset rather
# than read from upstream so it is pinned by digest beside the others and reaches x86_64 too.
set -euo pipefail

HERDR_VERSION=${HERDR_VERSION:-v0.9.3}
TL_ARCH=${TL_ARCH:-aarch64}
# Each processor's asset, pinned by digest. A new version is downloaded once from
# https://github.com/herdrdev/herdr/releases/download/<version>/herdr-linux-<arch> and its sha256
# written here.
case "$TL_ARCH" in
    aarch64) HERDR_SHA256=4de7aa3e25678812e92960de64f7c2aaa1bca1f0f80a3c5e559837e231e1f5c0 ;;
    x86_64)  HERDR_SHA256=18a8dc65f1c2fa485884344356dea1cfd911c6f06cf46fa78e193f4087f4dba7 ;;
    *) echo "error: no pinned herdr build for $TL_ARCH" >&2; exit 2 ;;
esac

TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-herdr"}

mkdir -p "$TL_OUT" "$TL_BUILD_DIR"
file="$TL_BUILD_DIR/herdr-linux-$TL_ARCH-$HERDR_VERSION"
[ -f "$file" ] || curl -fsSL -o "$file" \
    "https://github.com/herdrdev/herdr/releases/download/$HERDR_VERSION/herdr-linux-$TL_ARCH"
echo "$HERDR_SHA256  $file" | sha256sum -c - >/dev/null

cp "$file" "$TL_OUT/herdr"
chmod 755 "$TL_OUT/herdr"

echo
echo "Fetched: $TL_OUT/herdr ($HERDR_VERSION)"
ls -l "$TL_OUT/herdr"
