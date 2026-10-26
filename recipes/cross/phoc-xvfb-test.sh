#!/usr/bin/env bash
# phoc-xvfb-test.sh — phoc's X11 output follows the X root window's size and scale (issue #14,
# docs/PHOSH.md "Size and scale"). Builds phoc 0.58.0 natively with this directory's patches,
# starts it on an Xvfb screen, resizes the screen with `xrandr --fb` and checks, through
# wayland-info and wlr-randr, that the output's size and scale follow:
#
#   root 720x1280  -> output 720x1280,  scale 2   (the size the screen has when phoc starts)
#   root 1080x1920 -> output 1080x1920, scale 3   (resized while phoc runs)
#   root 300x600   -> output 300x600,   scale 1   (width / 360 rounded down, at least 1)
#   root 1440x720  -> output 1440x720,  scale 4
#   PHOSH_SCALE=1.5 on a second phoc -> scale 1.5, before and after a resize
#
# Needs on the host: Xvfb (built with RANDR), xrandr, wlr-randr, wayland-info, and what building
# phoc natively needs (meson >= 1.3, ninja, pkg-config, a C compiler, curl, patch, gettext,
# wayland-scanner, gtk3, libhandy-1, gnome-desktop-3, json-glib, glib's host tools, libxcb with
# the dri3, present, render, shm, xfixes and xinput extensions, pixman, xkbcommon,
# wayland-protocols, gsettings-desktop-schemas). A missing tool exits 77 (skipped) unless
# TL_XVFB_TEST_STRICT=1, which CI sets.
#
# Env: TL_TEST_DIR (default $PWD/phoc-xvfb-test: the tarball, the native build and its install
# go there and are reused until the patches change), TL_BUILD_JOBS.
set -euo pipefail

PHOC_VERSION="0.58.0"
PHOC_URL="https://gitlab.gnome.org/World/Phosh/phoc/-/archive/v$PHOC_VERSION/phoc-v$PHOC_VERSION.tar.gz"
PHOC_SHA256=a0e738e1e0b81b37ed7a7421e6fcaf113111809cec7c659371705c7cfc48fe5a

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TL_TEST_DIR=${TL_TEST_DIR:-"$PWD/phoc-xvfb-test"}
jobs=${TL_BUILD_JOBS:-$(nproc)}

missing=()
for tool in Xvfb xrandr wlr-randr wayland-info meson ninja pkg-config curl patch tar wayland-scanner msgfmt; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "phoc-xvfb-test: missing on this host: ${missing[*]}" >&2
    [ "${TL_XVFB_TEST_STRICT:-0}" = 1 ] && exit 1
    echo "phoc-xvfb-test: skipped" >&2
    exit 77
fi

mkdir -p "$TL_TEST_DIR"
prefix="$TL_TEST_DIR/prefix"
source_dir="$TL_TEST_DIR/source"
patch_key=$(cat "$SCRIPT_DIR"/phoc/*.patch | sha256sum | cut -d' ' -f1)

if [ "$(cat "$TL_TEST_DIR/.built" 2>/dev/null || true)" != "$patch_key" ]; then
    tarball="$TL_TEST_DIR/phoc-$PHOC_VERSION.tar.gz"
    if [ ! -f "$tarball" ]; then
        curl -fsSL -o "$tarball.tmp" "$PHOC_URL"
        mv "$tarball.tmp" "$tarball"
    fi
    echo "$PHOC_SHA256  $tarball" | sha256sum -c - >/dev/null
    rm -rf "$source_dir" "$prefix" "$TL_TEST_DIR/build"
    mkdir -p "$source_dir"
    tar -xzf "$tarball" -C "$source_dir" --strip-components=1
    for p in "$SCRIPT_DIR"/phoc/*.patch; do
        echo "Applying $(basename "$p")..."
        patch -p1 -s -d "$source_dir" < "$p"
    done
    # The options build-phosh.sh gives the phone's build, on the host's own toolchain.
    meson setup "$TL_TEST_DIR/build" "$source_dir" \
        --prefix="$prefix" --buildtype=debug --wrap-mode=default \
        -Dtests=false -Dgtk_doc=false -Dman=false -Dxwayland=disabled \
        -Dwlroots:default_library=static -Dgmobile:default_library=static \
        -Dwlroots:backends=x11 -Dwlroots:renderers= -Dwlroots:allocators= \
        -Dwlroots:session=disabled -Dwlroots:xcb-errors=disabled -Dwlroots:xwayland=disabled \
        -Dwlroots:color-management=disabled -Dwlroots:libliftoff=disabled \
        -Dwlroots:examples=false
    ninja -C "$TL_TEST_DIR/build" -j"$jobs"
    meson install -C "$TL_TEST_DIR/build" >/dev/null
    echo "$patch_key" > "$TL_TEST_DIR/.built"
fi

run_dir=$(mktemp -d)
chmod 700 "$run_dir"
pids=()
phoc_pid=
cleanup() {
    local pid
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
    rm -rf "$run_dir"
}
trap cleanup EXIT

export XDG_RUNTIME_DIR="$run_dir"
export XDG_DATA_DIRS="$prefix/share:/usr/local/share:/usr/share"
export GSETTINGS_SCHEMA_DIR="$prefix/share/glib-2.0/schemas"
export WLR_BACKENDS=x11 WLR_RENDERER=pixman NO_AT_BRIDGE=1
unset WAYLAND_DISPLAY

# Xvfb's RandR range tops out at the screen it starts with, so it starts big and is shrunk to
# the phone-like size before phoc starts.
disp=:$((90 + $$ % 100))
Xvfb "$disp" -screen 0 2160x3840x24 +extension RANDR -nolisten tcp 2>"$run_dir/xvfb.log" &
pids+=($!)
for _ in $(seq 100); do
    DISPLAY=$disp xrandr >/dev/null 2>&1 && break
    sleep 0.1
done
DISPLAY=$disp xrandr >/dev/null 2>&1 || { echo "Xvfb did not come up"; cat "$run_dir/xvfb.log"; exit 1; }
export DISPLAY=$disp

# state — "<width> <height> <scale>" of phoc's output: the size from wl_output's current mode,
# the scale from wlr-randr (which shows fractional scales).
state() {
    local size scale
    size=$(wayland-info -i wl_output 2>/dev/null |
        awk '/width:/ && /height:/ {gsub(/[^0-9 ]/," "); print $1, $2; exit}' || true)
    scale=$(wlr-randr 2>/dev/null | awk '/Scale:/ {print $2; exit}' || true)
    echo "${size:-? ?} ${scale:-0}"
}

# expect <width> <height> <scale> <what> — the state follows within five seconds. The X server
# and phoc answer on events; this loop is only the test waiting for them.
expect() {
    local want got="" _
    want=$(awk -v w="$1" -v h="$2" -v s="$3" 'BEGIN { printf "%s %s %.3f", w, h, s }')
    for _ in $(seq 50); do
        got=$(state | awk '{ printf "%s %s %.3f", $1, $2, $3 }')
        if [ "$got" = "$want" ]; then
            echo "ok: $4 -> $got"
            return 0
        fi
        sleep 0.1
    done
    echo "FAIL: $4: wanted '$want', phoc has '$got'" >&2
    echo "--- phoc log" >&2
    cat "$run_dir/phoc.log" >&2
    exit 1
}

start_phoc() {
    local s _
    "$prefix/bin/phoc" >"$run_dir/phoc.log" 2>&1 &
    phoc_pid=$!
    pids+=("$phoc_pid")
    for _ in $(seq 100); do
        for s in "$run_dir"/wayland-*; do
            case "$s" in
                *.lock) ;;
                *) if [ -S "$s" ]; then export WAYLAND_DISPLAY=${s##*/}; return 0; fi ;;
            esac
        done
        kill -0 "$phoc_pid" 2>/dev/null || { echo "phoc exited"; cat "$run_dir/phoc.log"; exit 1; }
        sleep 0.1
    done
    echo "phoc made no Wayland socket"
    cat "$run_dir/phoc.log"
    exit 1
}
stop_phoc() {
    kill "$phoc_pid" 2>/dev/null || true
    wait "$phoc_pid" 2>/dev/null || true
    rm -f "$run_dir"/wayland-*
    unset WAYLAND_DISPLAY
}

xrandr --fb 720x1280
start_phoc
expect 720 1280 2 "phoc starts on a 720x1280 root"

xrandr --fb 1080x1920
expect 1080 1920 3 "root resized to 1080x1920"

xrandr --fb 300x600
expect 300 600 1 "root resized to 300x600 (scale at least 1)"

xrandr --fb 1440x720
expect 1440 720 4 "root rotated to 1440x720"
stop_phoc

export PHOSH_SCALE=1.5
start_phoc
expect 1440 720 1.5 "PHOSH_SCALE=1.5 overrides the width rule"
xrandr --fb 720x1280
expect 720 1280 1.5 "PHOSH_SCALE=1.5 holds across a resize"
stop_phoc

echo "phoc-xvfb-test: all passed"
