#!/bin/bash
# run-headless.sh - phoc and phosh on the host, headless, against a fake launcherctl, then the
# tests in tests/phosh/test-*.sh (docs/PHOSH.md, "Testing"; README.md here says how one is written).
#
# What it does: builds phoc 0.58.0 and phosh 0.58.0 natively with the same patch stacks the phone's
# archive has (recipes/cross/phoc/, recipes/cross/phosh/; build-phosh.sh is the authority for the
# pins and options, copied below), starts a session D-Bus, the fake (fake-launcherctl.py) and
# `phoc -E phosh` under wlroots' headless backend, runs the tests, tears everything down.
#
# phosh's own test fixtures (-Dtests=true, phosh-test-fullshell) are not used: they build against
# the lock screen, logind and the other features this build compiles out. What they do - phoc with
# WLR_BACKENDS=headless and a phosh under it - is what this script does directly.
#
# Host dependencies (Ubuntu 24.04 apt names; CI installs them, see .github/workflows/ci.yml):
#   build:  meson ninja-build pkg-config gcc git curl patch gettext glslang-tools
#           libglib2.0-dev libglib2.0-dev-bin libgtk-3-dev libhandy-1-dev libgnome-desktop-3-dev
#           libjson-glib-dev libgcr-3-dev libpulse-dev libpulse-mainloop-glib0 libupower-glib-dev
#           libfontconfig-dev libcairo2-dev libwayland-dev libwayland-bin wayland-protocols
#           libxkbcommon-dev libpixman-1-dev libdrm-dev libegl-dev libgles-dev libgbm-dev
#           libvulkan-dev gsettings-desktop-schemas-dev libxcb1-dev libxcb-composite0-dev
#           libxcb-dri3-dev libxcb-icccm4-dev libxcb-present-dev libxcb-render-util0-dev
#           libxcb-render0-dev libxcb-shm0-dev libxcb-xfixes0-dev libxcb-xinput-dev
#           libxcb-ewmh-dev libxcb-res0-dev libxcb-util-dev libx11-xcb-dev
#   run:    dbus libglib2.0-bin (gdbus) gsettings-desktop-schemas python3 curl
#           librsvg2-common adwaita-icon-theme fonts-dejavu-core xkb-data
# A missing tool or pkg-config module exits 77 (skipped) unless TL_HEADLESS_STRICT=1 (CI sets it).
#
# Android-only patches: none are skipped today (every patch is guarded by __ANDROID__ or
# host_machine.system() == 'android', or is harmless on Linux). TL_SKIP_PATCHES below is the list
# this script owns for the day one is not; entries are "<tree>/<file name>".
#
# Usage: tests/phosh/run-headless.sh [--self-test] [test-file...]
#   --self-test   only start the fake and check its routes with curl (no phoc/phosh needed)
# Env: TL_TEST_DIR (default $PWD/phosh-headless: sources, builds and installs, reused until the
#      patches or this script change), TL_BUILD_JOBS, TL_HEADLESS_SECONDS (how long phosh must
#      stay up in the smoke test; default 10), TL_KEEP=1 (keep the run directory and print it).
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
RECIPES=$REPO_DIR/recipes/cross
TL_TEST_DIR=${TL_TEST_DIR:-"$PWD/phosh-headless"}
jobs=${TL_BUILD_JOBS:-$(nproc)}
TL_SKIP_PATCHES=()

# Pins: the same as recipes/cross/build-phosh.sh.
PHOC_VERSION="0.58.0"
PHOC_URL="https://gitlab.gnome.org/World/Phosh/phoc/-/archive/v$PHOC_VERSION/phoc-v$PHOC_VERSION.tar.gz"
PHOC_SHA256=a0e738e1e0b81b37ed7a7421e6fcaf113111809cec7c659371705c7cfc48fe5a
PHOSH_VERSION="0.58.0"
PHOSH_URL="https://gitlab.gnome.org/World/Phosh/phosh/-/archive/v$PHOSH_VERSION/phosh-v$PHOSH_VERSION.tar.gz"
PHOSH_SHA256=685ca53406b3692bba2f501b92f694759162864869ca0f272763c1a9b5f317cf
# The features the launcher's phosh compiles out (build-phosh.sh PHOSH_FEATURES_OFF).
PHOSH_FEATURES_OFF=(
    lockscreen polkit logind osk eds calls bluetooth location vpn hotspot networkmanager
    modemmanager gudev
)

self_test=0
tests=()
for a in "$@"; do
    case "$a" in
        --self-test) self_test=1 ;;
        *) tests+=("$a") ;;
    esac
done
[ ${#tests[@]} -gt 0 ] || tests=("$SCRIPT_DIR"/test-*.sh)

skip() {
    echo "run-headless: $1" >&2
    [ "${TL_HEADLESS_STRICT:-0}" = 1 ] && exit 1
    echo "run-headless: skipped" >&2
    exit 77
}

need_tools="python3 curl"
[ "$self_test" = 1 ] || need_tools="$need_tools meson ninja pkg-config patch tar git gcc glslangValidator \
    wayland-scanner msgfmt glib-compile-schemas glib-mkenums gdbus-codegen gdbus dbus-daemon"
missing=()
for tool in $need_tools; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
[ ${#missing[@]} -eq 0 ] || skip "missing tools: ${missing[*]}"

if [ "$self_test" = 0 ]; then
    missing=()
    for mod in gtk+-3.0 libhandy-1 gnome-desktop-3.0 json-glib-1.0 gcr-3 libpulse-mainloop-glib \
               upower-glib wayland-server wayland-client xkbcommon pixman-1 libdrm egl glesv2 \
               xcb xcb-icccm xcb-composite xcb-xfixes xcb-xinput xcb-shm xcb-present \
               xcb-dri3 xcb-ewmh xcb-res xcb-renderutil x11-xcb gsettings-desktop-schemas; do
        pkg-config --exists "$mod" 2>/dev/null || missing+=("$mod")
    done
    [ ${#missing[@]} -eq 0 ] || skip "missing pkg-config modules: ${missing[*]}"
fi

# --- build -------------------------------------------------------------------------------------

prefix="$TL_TEST_DIR/prefix"

skipped_patch() {
    local want="$1" s
    for s in "${TL_SKIP_PATCHES[@]}"; do [ "$s" = "$want" ] && return 0; done
    return 1
}

# fetch_tree <name> <url> <sha256> <version>: tarball, checksum, patch stack in file-name order.
fetch_tree() {
    local name="$1" url="$2" sha="$3" version="$4" src="$TL_TEST_DIR/$name-src" p
    local tarball="$TL_TEST_DIR/$name-$version.tar.gz" patches=()
    for p in "$RECIPES/$name"/*.patch; do
        skipped_patch "$name/$(basename "$p")" || patches+=("$p")
    done
    local key
    key=$( { cat "${patches[@]}"; sha256sum < "${BASH_SOURCE[0]}"; } | sha256sum | cut -d' ' -f1)
    if [ "$(cat "$src/.tl-prepared" 2>/dev/null || true)" = "$key" ]; then
        return 0
    fi
    rm -rf "$src" "$TL_TEST_DIR/$name-build"
    rm -f "$TL_TEST_DIR/.installed-$name"
    mkdir -p "$src"
    if [ ! -f "$tarball" ]; then
        echo "Fetching $name $version..."
        curl -fsSL -o "$tarball.tmp" "$url"
        mv "$tarball.tmp" "$tarball"
    fi
    echo "$sha  $tarball" | sha256sum -c - >/dev/null || { echo "error: $name tarball sha256 differs" >&2; exit 1; }
    tar -xzf "$tarball" -C "$src" --strip-components=1
    for p in "${patches[@]}"; do
        echo "Applying $name/$(basename "$p")..."
        patch -p1 -s -d "$src" < "$p" || { echo "error: $(basename "$p") does not apply to $name" >&2; exit 1; }
    done
    echo "$key" > "$src/.tl-prepared"
}

build_phoc() {
    fetch_tree phoc "$PHOC_URL" "$PHOC_SHA256" "$PHOC_VERSION"
    [ -f "$TL_TEST_DIR/.installed-phoc" ] && return 0
    # The phone's options (build-phosh.sh), with the headless backend added to the X11 one: phoc's
    # patch 0004 calls wlr_output_is_x11 (), so the X11 backend stays compiled in.
    meson setup "$TL_TEST_DIR/phoc-build" "$TL_TEST_DIR/phoc-src" \
        --prefix="$prefix" --buildtype=debug --wrap-mode=default \
        -Dtests=false -Dgtk_doc=false -Dman=false -Dxwayland=disabled \
        -Dwlroots:default_library=static -Dgmobile:default_library=static \
        -Dwlroots:backends=x11,headless -Dwlroots:renderers= -Dwlroots:allocators= \
        -Dwlroots:session=disabled -Dwlroots:xcb-errors=disabled -Dwlroots:xwayland=disabled \
        -Dwlroots:color-management=disabled -Dwlroots:libliftoff=disabled \
        -Dwlroots:examples=false
    ninja -C "$TL_TEST_DIR/phoc-build" -j"$jobs"
    meson install -C "$TL_TEST_DIR/phoc-build" >/dev/null
    cp "$RECIPES/phoc/org.gnome.mutter.keybindings.gschema.xml" "$prefix/share/glib-2.0/schemas/"
    touch "$TL_TEST_DIR/.installed-phoc"
}

build_phosh() {
    fetch_tree phosh "$PHOSH_URL" "$PHOSH_SHA256" "$PHOSH_VERSION"
    [ -f "$TL_TEST_DIR/.installed-phosh" ] && return 0
    local opts=() feature
    for feature in "${PHOSH_FEATURES_OFF[@]}"; do opts+=("-D$feature=false"); done
    meson setup "$TL_TEST_DIR/phosh-build" "$TL_TEST_DIR/phosh-src" \
        --prefix="$prefix" --libexecdir=bin --buildtype=debug --wrap-mode=default \
        -Dtests=false -Dtools=false -Dgtk_doc=false -Dman=false \
        "${opts[@]}" \
        -Dsearchd=false -Dlockscreen-plugins=false -Dquick-setting-plugins=false \
        -Dstatus-icon-plugins=false \
        -Dgmobile:default_library=static -Dlibfeedback:default_library=static \
        -Dlibfeedback:udev=false -Dlibfeedback:vapi=false
    ninja -C "$TL_TEST_DIR/phosh-build" -j"$jobs"
    meson install -C "$TL_TEST_DIR/phosh-build" >/dev/null
    touch "$TL_TEST_DIR/.installed-phosh"
}

mkdir -p "$TL_TEST_DIR"
if [ "$self_test" = 0 ]; then
    build_phoc
    build_phosh
fi

# --- run ---------------------------------------------------------------------------------------

run_dir=$(mktemp -d)
chmod 700 "$run_dir"
pids=()
cleanup() {
    local pid
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
    if [ "${TL_KEEP:-0}" = 1 ]; then echo "run-headless: kept $run_dir"; else rm -rf "$run_dir"; fi
}
trap cleanup EXIT

export HOME="$run_dir/home"
export XDG_RUNTIME_DIR="$run_dir/runtime"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_HOME="$HOME/.local/share"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
chmod 700 "$XDG_RUNTIME_DIR"
export TL_RUN_DIR="$run_dir" TL_SCRIPT_DIR="$SCRIPT_DIR"

# The fake launcherctl: endpoint and token land in $HOME/.launcherctl/, where phosh's bridge reads them.
python3 -I "$SCRIPT_DIR/fake-launcherctl.py" --home "$HOME" --log "$run_dir/fake-calls.json" \
    >"$run_dir/fake.out" 2>"$run_dir/fake.err" &
pids+=($!)
for _ in $(seq 100); do grep -q '^ready' "$run_dir/fake.out" 2>/dev/null && break; sleep 0.1; done
grep -q '^ready' "$run_dir/fake.out" || { echo "run-headless: the fake did not start"; cat "$run_dir/fake.err"; exit 1; }
export FAKE_CALLS_FILE="$run_dir/fake-calls.json"
FAKE_ENDPOINT=$(head -n1 "$HOME/.launcherctl/endpoint")
FAKE_CONTROL=$(head -n1 "$HOME/.launcherctl/control")
FAKE_TOKEN=$(head -n1 "$HOME/.launcherctl/token")
export FAKE_ENDPOINT FAKE_CONTROL FAKE_TOKEN

if [ "$self_test" = 1 ]; then
    # shellcheck source=tests/phosh/lib.sh
    . "$SCRIPT_DIR/lib.sh"
    fake_self_test
    echo "run-headless: fake self-test passed"
    exit 0
fi

# A session bus of our own.
dbus-daemon --session --fork --print-address=3 --print-pid=4 \
    3>"$run_dir/dbus.addr" 4>"$run_dir/dbus.pid"
DBUS_SESSION_BUS_ADDRESS=$(cat "$run_dir/dbus.addr")
export DBUS_SESSION_BUS_ADDRESS
pids+=("$(cat "$run_dir/dbus.pid")")

# Schemas: the build's own plus the system's org.gnome.desktop* ones, in one directory, so
# phosh's overrides (data/90_tl.gschema.override) apply to them. Settings live in memory.
schemas="$run_dir/schemas"
mkdir -p "$schemas"
cp "$prefix"/share/glib-2.0/schemas/*.xml "$prefix"/share/glib-2.0/schemas/*.override "$schemas/" 2>/dev/null || true
cp /usr/share/glib-2.0/schemas/org.gnome.desktop*.xml "$schemas/"
glib-compile-schemas "$schemas" 2>&1 | grep -v 'non-existent schema' || true
export GSETTINGS_SCHEMA_DIR="$schemas" GSETTINGS_BACKEND=memory
export XDG_DATA_DIRS="$prefix/share:/usr/local/share:/usr/share"
export XDG_CURRENT_DESKTOP=Phosh
export LD_LIBRARY_PATH="$prefix/lib:$prefix/lib/$(gcc -dumpmachine)${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export NO_AT_BRIDGE=1 GTK_A11Y=none GDK_BACKEND=wayland G_MESSAGES_DEBUG=
# wlroots: the headless backend, one output, the pixman renderer.
export WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=pixman
unset WAYLAND_DISPLAY DISPLAY

# phoc starts phosh itself, as phosh-session does (phoc -E phosh).
"$prefix/bin/phoc" -E "$prefix/bin/phosh" >"$run_dir/phoc.log" 2>&1 &
export PHOC_PID=$!
pids+=("$PHOC_PID")
export TL_PHOC_LOG="$run_dir/phoc.log"

fail=0
for t in "${tests[@]}"; do
    echo "== $(basename "$t")"
    if ! bash "$t"; then
        echo "FAIL: $(basename "$t")" >&2
        fail=1
    fi
done
if [ "$fail" != 0 ]; then
    echo "--- phoc/phosh log" >&2
    tail -n 80 "$run_dir/phoc.log" >&2
    echo "--- fake calls" >&2
    cat "$run_dir/fake-calls.json" >&2
    exit 1
fi
echo "run-headless: all passed"
