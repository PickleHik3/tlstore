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
#   build:  meson >= 1.7 (phosh's meson_version; noble has 1.3.2, CI installs it with pip)
#           ninja-build pkg-config gcc git curl patch gettext glslang-tools bison xz-utils
#           libappstream-dev libfribidi-dev libpsl-dev libnghttp2-dev libsqlite3-dev
#           libffi-dev libexpat1-dev
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
# Libraries whose noble version is below what phoc, wlroots or phosh require are built from pinned
# tarballs into the prefix first (build_dep below; the table is in README.md).
# A missing tool or pkg-config module exits 77 (skipped) unless TL_HEADLESS_STRICT=1 (CI sets it).
#
# Android-only patches: none are skipped today (every patch is guarded by __ANDROID__ or
# host_machine.system() == 'android', or is harmless on Linux). TL_SKIP_PATCHES below is the list
# this script owns for the day one is not; entries are "<tree>/<file name>".
#
# Usage: tests/phosh/run-headless.sh [--self-test] [--deps-only[=name,...]] [test-file...]
#   --self-test   only start the fake and check its routes with curl (no phoc/phosh needed)
#   --deps-only   only build the too-old dependencies into the prefix (all, or the named ones)
# Env: TL_TEST_DIR (default $PWD/phosh-headless: sources, builds and installs, reused until the
#      patches or this script change), TL_BUILD_JOBS, TL_HEADLESS_SECONDS (how long phosh must
#      stay up in the smoke test; default 10), TL_KEEP=1 (keep the run directory and print it).
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
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
deps_only=0
deps_only_names=""
tests=()
for a in "$@"; do
    case "$a" in
        --self-test) self_test=1 ;;
        --deps-only) deps_only=1 ;;
        --deps-only=*) deps_only=1; deps_only_names=" ${a#--deps-only=} "; deps_only_names=${deps_only_names//,/ } ;;
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
if [ "$deps_only" = 1 ]; then
    need_tools="$need_tools meson ninja pkg-config tar xz gcc"
elif [ "$self_test" = 0 ]; then
    need_tools="$need_tools meson ninja pkg-config patch tar xz git gcc glslangValidator bison \
        wayland-scanner msgfmt glib-compile-schemas glib-mkenums gdbus-codegen gdbus dbus-daemon"
fi
missing=()
for tool in $need_tools; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
[ ${#missing[@]} -eq 0 ] || skip "missing tools: ${missing[*]}"

# phosh's meson_version (>= 1.7.0); noble's apt meson is 1.3.2.
if [ "$self_test" = 0 ] && command -v meson >/dev/null 2>&1; then
    have=$(meson --version)
    [ "$(printf '%s\n1.7.0\n' "$have" | sort -V | head -n1)" = 1.7.0 ] \
        || skip "meson $have is older than 1.7.0 (phosh's meson_version)"
fi

if [ "$self_test" = 0 ] && [ "$deps_only" = 0 ]; then
    missing=()
    for mod in gtk+-3.0 libhandy-1 gnome-desktop-3.0 json-glib-1.0 gcr-3 libpulse-mainloop-glib \
               upower-glib wayland-server wayland-client xkbcommon pixman-1 libdrm egl glesv2 \
               xcb xcb-icccm xcb-composite xcb-xfixes xcb-xinput xcb-shm xcb-present \
               xcb-dri3 xcb-ewmh xcb-res xcb-renderutil x11-xcb gsettings-desktop-schemas \
               appstream fribidi libpsl libnghttp2 sqlite3 libffi expat; do
        pkg-config --exists "$mod" 2>/dev/null || missing+=("$mod")
    done
    [ ${#missing[@]} -eq 0 ] || skip "missing pkg-config modules: ${missing[*]}"
fi

# --- build -------------------------------------------------------------------------------------

prefix="$TL_TEST_DIR/prefix"
mkdir -p "$TL_TEST_DIR" "$prefix"
# The prefix's libraries come first for pkg-config, so a too-old system copy is never picked.
multiarch=$(gcc -dumpmachine 2>/dev/null || echo x86_64-linux-gnu)
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/share/pkgconfig:$prefix/lib/$multiarch/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PATH="$prefix/bin:$PATH"

skipped_patch() {
    local want="$1" s
    for s in "${TL_SKIP_PATCHES[@]}"; do [ "$s" = "$want" ] && return 0; done
    return 1
}

# build_dep <name> <version> <url> <sha256> [meson option...]: a dependency whose noble version is
# below a minimum phoc, wlroots or phosh require (README.md has the table), built from a pinned
# tarball into the prefix with its libraries in $prefix/lib. Rebuilt when its pin or options change.
build_dep() {
    local name="$1" version="$2" url="$3" sha="$4" file src build marker key
    shift 4
    file="$TL_TEST_DIR/dl/$(basename "$url")"
    key=$(printf '%s\n' "$name" "$version" "$sha" "$@" | sha256sum | cut -d' ' -f1)
    marker="$TL_TEST_DIR/.installed-dep-$name"
    if [ "$(cat "$marker" 2>/dev/null || true)" = "$key" ]; then
        return 0
    fi
    src="$TL_TEST_DIR/deps/$name-src"
    build="$TL_TEST_DIR/deps/$name-build"
    mkdir -p "$TL_TEST_DIR/dl"
    if [ ! -f "$file" ]; then
        echo "Fetching $name $version..."
        curl -fsSL -o "$file.tmp" "$url"
        mv "$file.tmp" "$file"
    fi
    echo "$sha  $file" | sha256sum -c - >/dev/null || { echo "error: $name tarball sha256 differs" >&2; exit 1; }
    rm -rf "$src" "$build" "$marker"
    mkdir -p "$src"
    tar -xf "$file" -C "$src" --strip-components=1
    echo "Building $name $version..."
    meson setup "$build" "$src" --prefix="$prefix" --libdir=lib --buildtype=release "$@" >"$TL_TEST_DIR/deps/$name.log" 2>&1 \
        || { tail -n 40 "$TL_TEST_DIR/deps/$name.log" >&2; echo "error: meson setup failed for $name" >&2; exit 1; }
    { ninja -C "$build" -j"$jobs" && meson install -C "$build"; } >>"$TL_TEST_DIR/deps/$name.log" 2>&1 \
        || { tail -n 40 "$TL_TEST_DIR/deps/$name.log" >&2; echo "error: building $name failed" >&2; exit 1; }
    echo "$key" > "$marker"
}

# want_dep <name>: false when --deps-only=a,b was given and the name is not in the list.
want_dep() {
    [ -z "$deps_only_names" ] || case "$deps_only_names" in *" $1 "*) true ;; *) false ;; esac
}

# The dependencies below noble's versions, in build order (wayland before wayland-protocols' scanner
# use, libxkbcommon and the rest independent). required = the highest minimum among phoc 0.58.0,
# wlroots 0.20.2 and phosh 0.58.0 (as the harness builds them).
build_deps() {
    local gnome=https://download.gnome.org/sources
    # phoc >= 1.23.1, wlroots >= 1.24.0 (noble 1.22.0)
    want_dep wayland && build_dep wayland 1.24.0 \
        https://gitlab.freedesktop.org/wayland/wayland/-/releases/1.24.0/downloads/wayland-1.24.0.tar.xz \
        82892487a01ad67b334eca83b54317a7c86a03a89cfadacfef5211f11a5d0536 \
        -Dlibraries=true -Dscanner=true -Dtests=false -Ddocumentation=false -Ddtd_validation=false
    # wlroots >= 1.47 (noble 1.34, 1.45 in -updates)
    want_dep wayland-protocols && build_dep wayland-protocols 1.47 \
        https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/1.47/downloads/wayland-protocols-1.47.tar.xz \
        5fd4349bcbc9bab9a46f8cf77d1f434296a7a052c87440a094f63fcf62a58e20 \
        -Dtests=false
    # phoc >= 0.43.4, wlroots >= 0.43.0 (noble 0.42.2)
    want_dep pixman && build_dep pixman 0.43.4 \
        https://www.cairographics.org/releases/pixman-0.43.4.tar.gz \
        a0624db90180c7ddb79fc7a9151093dc37c646d8c38d3f232f767cf64b85a226 \
        -Dgtk=disabled -Dlibpng=disabled -Dtests=disabled -Ddemos=disabled
    # wlroots >= 2.4.129 (noble 2.4.120, 2.4.125 in -updates); no GPU drivers, no tests
    want_dep libdrm && build_dep libdrm 2.4.129 \
        https://dri.freedesktop.org/libdrm/libdrm-2.4.129.tar.xz \
        5978183f978d697e26a50ba066174964efb0ab97caa1ecaa1b861fbe5ddf77dc \
        -Dauto_features=disabled -Dtests=false -Dudev=false -Dinstall-test-programs=false
    # wlroots >= 1.8.0 (noble 1.6.0). The keymap data stays the system's.
    want_dep libxkbcommon && build_dep libxkbcommon 1.8.1 \
        https://github.com/xkbcommon/libxkbcommon/archive/refs/tags/xkbcommon-1.8.1.tar.gz \
        c65c668810db305c4454ba26a10b6d84a96b5469719fe3c729e1c6542b8d0d87 \
        -Denable-tools=false -Denable-x11=false -Denable-wayland=false -Denable-docs=false \
        -Denable-xkbregistry=false -Denable-bash-completion=false \
        -Dxkb-config-root=/usr/share/X11/xkb -Dx-locale-root=/usr/share/X11/locale
    # phosh >= 47 (noble 46.0, 46.1 in -updates)
    want_dep gsettings-desktop-schemas && build_dep gsettings-desktop-schemas 47.1 \
        "$gnome/gsettings-desktop-schemas/47/gsettings-desktop-schemas-47.1.tar.xz" \
        a60204d9c9c0a1b264d6d0d134a38340ba5fc6076a34b84da945d8bfcc7a2815 \
        -Dintrospection=false
    # phosh >= 3.6 (noble 3.4.4)
    want_dep libsoup && build_dep libsoup 3.6.5 \
        "$gnome/libsoup/3.6/libsoup-3.6.5.tar.xz" \
        6891765aac3e949017945c3eaebd8cc8216df772456dc9f460976fbdb7ada234 \
        -Dgssapi=disabled -Dntlm=disabled -Dbrotli=disabled -Dtls_check=false \
        -Dintrospection=disabled -Dvapi=disabled -Ddocs=disabled -Dsysprof=disabled -Dtests=false
    return 0
}

# fetch_tree <name> <url> <sha256> <version>: tarball, checksum, patch stack in file-name order.
fetch_tree() {
    local name="$1" url="$2" sha="$3" version="$4" p
    local src="$TL_TEST_DIR/$name-src" tarball="$TL_TEST_DIR/$name-$version.tar.gz" patches=()
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

if [ "$deps_only" = 1 ]; then
    build_deps
    echo "run-headless: dependencies built into $prefix"
    exit 0
fi
if [ "$self_test" = 0 ]; then
    build_deps
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
    # shellcheck source=lib.sh
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
cp /usr/share/glib-2.0/schemas/org.gnome.desktop*.xml "$schemas/"
cp "$prefix"/share/glib-2.0/schemas/*.xml "$prefix"/share/glib-2.0/schemas/*.override "$schemas/" 2>/dev/null || true
glib-compile-schemas "$schemas" 2>&1 | grep -v 'non-existent schema' || true
export GSETTINGS_SCHEMA_DIR="$schemas" GSETTINGS_BACKEND=memory
export XDG_DATA_DIRS="$prefix/share:/usr/local/share:/usr/share"
export XDG_CURRENT_DESKTOP=Phosh
LD_LIBRARY_PATH="$prefix/lib:$prefix/lib/$multiarch${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
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
