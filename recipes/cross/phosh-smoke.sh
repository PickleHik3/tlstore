#!/bin/bash
# phosh-smoke.sh — check that a meson project configures and links against the phosh sysroot.
#
# Usage: TL_ARCH=aarch64|x86_64 ./phosh-smoke.sh
# Assembles the sysroot (phosh-deps.txt, main + x11 repos; cached .debs are reused), writes the
# cross file, then configures and links phosh-smoke/ (wayland-client + pixman). Needs meson,
# ninja and pkg-config on the host. Env as termux-sysroot.sh and phosh-cross-file.sh; the work
# directory is TL_WORK (default ./phosh-smoke-work).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TL_ARCH=${TL_ARCH:-aarch64}
TL_WORK=${TL_WORK:-"$PWD/phosh-smoke-work"}

for tool in meson ninja pkg-config; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is not on PATH" >&2; exit 1; }
done

export TL_ARCH TL_TERMUX_ARCH="$TL_ARCH" TL_TERMUX_X11=1
export TL_SYSROOT=${TL_SYSROOT:-"$TL_WORK/sysroot-$TL_ARCH"}
export TL_CACHE=${TL_CACHE:-"$TL_WORK/debs-$TL_ARCH"}
mkdir -p "$TL_WORK"

"$SCRIPT_DIR/termux-sysroot.sh" -f "$SCRIPT_DIR/phosh-deps.txt"
"$SCRIPT_DIR/phosh-cross-file.sh" "$TL_WORK/cross-$TL_ARCH.ini"

build="$TL_WORK/build-$TL_ARCH"
rm -rf "$build"
meson setup "$build" "$SCRIPT_DIR/phosh-smoke" --cross-file "$TL_WORK/cross-$TL_ARCH.ini"
ninja -C "$build"
file "$build/smoke" 2>/dev/null || true
echo "phosh-smoke: $TL_ARCH ok"
