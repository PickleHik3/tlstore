#!/bin/bash
# build-phosh.sh — the native phosh desktop for TL_ARCH (aarch64 by default, or x86_64), as one
# .tar.gz archive tree (bin/, lib/, share/; docs/PHOSH.md, "Packaging"), built against a Termux
# sysroot with the NDK's clang.
#
# One function per upstream tree, built in this order, each with its own ordered patch directory
# next to this script, applied with `patch -p1` in file-name order:
#
#   phoc                    recipes/cross/phoc/                   built (M0)
#   gmobile, libfeedback    meson subprojects of phoc and phosh, pinned below, not trees of their own
#   phosh                   recipes/cross/phosh/                  built (M1)
#   phosh-mobile-settings   recipes/cross/phosh-mobile-settings/  built (M4)
#   tl-feedbackd            recipes/cross/tl-feedbackd/           built (M3)
#
# TL_PHOSH_TREES names the trees to build, in order (default: phoc phosh phosh-mobile-settings tl-feedbackd).
# A tree that is not written yet stops the build instead of being skipped.
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
#   0006  the keymap's shm file is a sealed memfd on Android (a wlroots patch file; no /proc
#         re-open, which SELinux denies), and phoc survives a keymap that failed to allocate
#   0007  Xwayland on Android (a wlroots patch file): the X11 sockets and lock files in
#         $TERMUX_PREFIX/tmp, where Termux's libxcb looks (Android has no /tmp), Xwayland's device
#         path compiled in (not the sysroot's copy pkg-config answers), and a display whose
#         socket answers (the launcher's own, :0) is never taken over
# and, from the recipe, not a patch: org.gnome.mutter.keybindings (phoc/*.gschema.xml) and the
# archive's compiled share/glib-2.0/schemas/gschemas.compiled.
#
# M1 builds phosh 0.58.0 the same way: the tag, plus the numbered patches in recipes/cross/phosh/
# (commits on the tag too, exported with `git format-patch`). They are of three kinds:
#   - the subprojects' wraps, moved to the revisions pinned below (gmobile as phoc has it; the
#     wraps in the tag name v0.1.0 and feedbackd v0.7.0, which are not what 0.58 is written for);
#   - Bionic and Termux fixes: the libintl.h stand-in (as in phoc's), memfd_create by system call
#     in place of shm_open, no exp10, libfeedback found next to the binary;
#   - meson options, all on by default (that is upstream), that compile out what the launcher does
#     not ship (docs/PHOSH.md, "Keep, drop, bridge"). This build turns them all off, so there is no
#     library to stub and no system bus to fake:
#       -Dlockscreen=false     lock screen, PIN, lock-screen plugins, PAM: phosh starts unlocked
#       -Dpolkit=false         polkit agent
#       -Dlogind=false         libsystemd/elogind, logind inhibitors, sd_notify
#       -Dosk=false            the on-screen keyboard manager (sm.puri.OSK0)
#       -Deds=false            evolution-data-server, the calendar server and its plugins
#       -Dcalls=false          calls, call UI (libcall-ui), emergency calls, cell broadcasts
#       -Dbluetooth=false      gnome-bluetooth, the Bluetooth tile and status page
#       -Dlocation=false       GeoClue, the location manager
#       -Dvpn=false            the VPN manager and tile        (also off with networkmanager)
#       -Dhotspot=false        the Wi-Fi hotspot setting      (also off with networkmanager)
#       -Dnetworkmanager=false libnm: Wi-Fi, connectivity, network authentication. Termux has no
#                              libnm, so the providers docs/PHOSH.md wants to keep for now cannot
#                              be built. The Wi-Fi and WWAN managers are the ones with nothing to
#                              report (wifi-manager-none.c, wwan-manager-none.c): "no hardware",
#                              what phosh itself says when NetworkManager is not on the bus
#       -Dmodemmanager=false   mm-glib (not in Termux either); the oFono backend stays
#       -Dgudev=false          libgudev (nor this): udev monitoring, sysfs backlight and torch
#       -Dsearchd=false        upstream's search service
#     UPower, iio-sensor-proxy and the torch manager stay: they only look for their D-Bus names.
#     -Dtl-debug stays false (its default): the TlState and TlTile test hooks on DebugControl
#     (patches 0023 and 0033) are for tests/phosh/run-headless.sh only, never in the archive.
# Not in the archive yet: the session script, the session files and the compiled gschemas, which
# are the "session-file step" of docs/PHOSH.md ("Packaging"). The schemas are checked here, with
# the overrides of data/90_tl.gschema.override, not compiled into the archive.
#
# What is built in:
#   - wlroots 0.20.2, the subproject phoc's wlroots.wrap names, linked statically: backends=x11
#     only (no DRM, libinput, session), renderers=vulkan (the Vulkan renderer, and pixman, which
#     wlroots always has; no GLES2), no allocators (no gbm, no udmabuf; the shm allocator is
#     always built), no libliftoff or color management, and xcb-errors off (Termux has no
#     xcb-util-errors; it only gives the X11 backend and the X window manager readable error
#     names). Xwayland is on (docs/PHOSH.md story 18, X11-only apps inside phosh): wlroots starts
#     Termux's $TERMUX_PREFIX/bin/Xwayland (the xwayland part) when the first X client connects,
#     and links libxcb's composite, res and xfixes and xcb-util-wm's ewmh and icccm. The Vulkan
#     renderer links libvulkan.so (Termux's vulkan-loader-generic, with mesa-vulkan-icd-freedreno
#     for the GPU: a hidden part of the archive's package) and compiles its shaders with the
#     host's glslang (glslang-tools in CI). At start phoc tries Vulkan on the GPU and falls back
#     to pixman, logging the choice; WLR_RENDERER=pixman|vulkan forces one;
#   - gmobile v0.6.0_beta1 and gvdb, meson subprojects too, static;
#   - phoc's own xwayland option on, with wlroots': phoc sets DISPLAY for phosh and the apps it
#     starts to the Xwayland display (the first free one after the launcher's :0);
#   - for phosh: gmobile (static), libgvc (static, over Termux's libpulse), feedbackd's libfeedback
#     (a shared library, because its meson says so: lib/libfeedback-0.0.so in the archive, found
#     through the binary's $ORIGIN/../lib), and everything else from the Termux sysroot (gtk3,
#     libhandy, gcr, gnome-desktop3, appstream, libsoup3, upower's client library, libpulse).
# The subprojects are fetched by meson from the wraps the trees ship; their commits are pinned
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
# files say; a host without glib-mkenums or gdbus-codegen, as Arch is, gets one made from the
# sysroot's glib, see host_glib_tools), TL_BUILD_JOBS.
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

PHOSH_VERSION="0.58.0"
PHOSH_URL="https://gitlab.gnome.org/World/Phosh/phosh/-/archive/v$PHOSH_VERSION/phosh-v$PHOSH_VERSION.tar.gz"
PHOSH_SHA256=685ca53406b3692bba2f501b92f694759162864869ca0f272763c1a9b5f317cf
PHOSH_COMMIT="991730023a5b12c0cd203a98abd1abcea99d3159"   # v0.58.0, the tag's commit
# What recipes/cross/phosh/0001 points phosh's wraps at (the commits the tags peel to).
GMOBILE_COMMIT="dcc1c4ebf13e985300f8a448530b29e82acad527"       # v0.6.0_beta1, as in phoc's wrap
LIBFEEDBACK_COMMIT="f14642cb0408af9b6bf963eff3bc61eff6b0a1b2"   # feedbackd v0.8.1
GVC_COMMIT="d2442f455844e5292cb4a74ffc66ecc8d7595a9f"           # libgnome-volume-control, as phosh's wrap

# M4: phosh-mobile-settings 0.58.0, the settings app (patches in recipes/cross/phosh-mobile-settings/;
# the build is described above build_phosh_mobile_settings).
PMS_VERSION="0.58.0"
PMS_URL="https://gitlab.gnome.org/World/Phosh/phosh-mobile-settings/-/archive/v$PMS_VERSION/phosh-mobile-settings-v$PMS_VERSION.tar.gz"
PMS_SHA256=cc7966be26f0d3ef7e090051a9be5de9d5d8c5f2c382da673491904173a5ee9e
PMS_COMMIT="38168614f14a3ce69c34dc89e72354783a97fa3b"   # v0.58.0, the commit the tag peels to

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
TL_PHOSH_TREES=${TL_PHOSH_TREES:-phoc phosh phosh-mobile-settings tl-feedbackd}
TL_SYSROOT=${TL_SYSROOT:-}
[ -d "$TL_SYSROOT$TERMUX_PREFIX/lib/pkgconfig" ] || {
    echo "error: no Termux sysroot at '$TL_SYSROOT$TERMUX_PREFIX' (TL_SYSROOT; build it with termux-sysroot.sh -f phosh-deps.txt)" >&2
    exit 1
}
NDK_BIN="$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
[ -d "$NDK_BIN" ] || { echo "error: NDK not found at $TL_NDK (set TL_NDK)" >&2; exit 1; }
for tool in meson ninja pkg-config git curl patch tar gzip wayland-scanner msgfmt glib-compile-schemas; do
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

# host_glib_tools — meson finds glib-mkenums, glib-genmarshal and gdbus-codegen through the
# *host's* glib-2.0.pc and gio-2.0.pc (they are build-machine tools). A build machine that has no
# glib development tools (Arch splits them out) fails there. The sysroot's glib has the same tools,
# as Python scripts that run as they are (glib-compile-resources and glib-compile-schemas are ELF
# files for the phone, and the host's own are found by name), so a native pkg-config path holding
# copies of the two .pc files, with the three scripts' variables pointing into the sysroot, stands
# in. Everything else of glib the build machine needs, its own .pc files give.
host_glib_tools() {
    local src="$TL_SYSROOT$TERMUX_PREFIX" dir="$TL_BUILD_DIR/hostpc" pc
    if command -v glib-mkenums >/dev/null 2>&1 && command -v gdbus-codegen >/dev/null 2>&1; then
        return 0
    fi
    mkdir -p "$dir"
    for pc in glib-2.0 gio-2.0; do
        [ -f "$src/lib/pkgconfig/$pc.pc" ] || { echo "error: no $pc.pc in the sysroot" >&2; exit 1; }
        sed -E -e 's#^prefix=.*#prefix=/usr#' \
            -e "s#^((glib_genmarshal|glib_mkenums|gdbus_codegen)=)\\\$\\{bindir\\}/#\\1$src/bin/#" \
            -e '/^Requires\.private:/d' "$src/lib/pkgconfig/$pc.pc" > "$dir/$pc.pc"
    done
    printf "[built-in options]\npkg_config_path = ['%s']\n" "$dir" > "$TL_BUILD_DIR/native-glib.ini"
    TL_NATIVE_FILE="$TL_BUILD_DIR/native-glib.ini"
}
[ -n "${TL_NATIVE_FILE:-}" ] || host_glib_tools

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
        -Dxwayland=enabled \
        -Dwlroots:default_library=static -Dgmobile:default_library=static \
        -Dwlroots:backends=x11 -Dwlroots:renderers=vulkan -Dwlroots:allocators= \
        -Dwlroots:session=disabled -Dwlroots:xcb-errors=disabled -Dwlroots:xwayland=enabled \
        -Dwlroots:color-management=disabled -Dwlroots:libliftoff=disabled \
        -Dwlroots:examples=false
    check_pin "$SOURCE_DIR/subprojects/wlroots-0.20.x" "$WLROOTS_COMMIT" "wlroots"

    echo "Building phoc..."
    ninja -C "$build" -j"$jobs"

    echo "Installing phoc into the stage..."
    DESTDIR="$stage" meson install -C "$build" --no-rebuild --strip >/dev/null

    # phoc opens org.gnome.mutter.keybindings, which no Termux package ships; the schemas it opens
    # besides (org.gnome.desktop.*) come from Termux's gsettings-desktop-schemas. The archive
    # carries its own compiled set (phoc's schema and the mutter one), self-contained.
    local schemas="$stage/share/glib-2.0/schemas"
    mkdir -p "$schemas"
    cp "$SCRIPT_DIR/phoc/org.gnome.mutter.keybindings.gschema.xml" "$schemas/"
    rm -f "$schemas/gschemas.compiled"
    glib-compile-schemas --strict "$schemas"
}

# phosh's options: every feature the launcher does not ship is off (see the top of this file).
PHOSH_FEATURES_OFF=(
    lockscreen polkit logind osk eds calls bluetooth location vpn hotspot networkmanager
    modemmanager gudev
)

build_phosh() {
    fetch_tree phosh "$PHOSH_URL" "$PHOSH_SHA256" "$PHOSH_VERSION" "$PHOSH_COMMIT"
    local build="$TL_BUILD_DIR/phosh/build-$TL_ARCH" native=() opts=() feature
    [ -z "${TL_NATIVE_FILE:-}" ] || native=(--native-file "$TL_NATIVE_FILE")
    for feature in "${PHOSH_FEATURES_OFF[@]}"; do opts+=("-D$feature=false"); done

    echo "Configuring phosh $PHOSH_VERSION for $TL_ARCH..."
    rm -rf "$build"
    # --libexecdir=bin puts the binary at bin/phosh, next to phoc. The plugins are off: a plugin
    # is found at a path compiled into phosh, which the archive does not know (it lands under
    # the user's home), and their preferences are GTK 4 programs.
    meson setup "$build" "$SOURCE_DIR" --cross-file "$cross_file" "${native[@]}" \
        --prefix=/ --libexecdir=bin --buildtype=release --wrap-mode=default \
        -Dtests=false -Dtools=false -Dgtk_doc=false -Dman=false \
        "${opts[@]}" \
        -Dsearchd=false -Dlockscreen-plugins=false -Dquick-setting-plugins=false \
        -Dstatus-icon-plugins=false -Dtl-debug=false \
        -Dgmobile:default_library=static -Dlibfeedback:default_library=static \
        -Dlibfeedback:udev=false -Dlibfeedback:vapi=false
    check_pin "$SOURCE_DIR/subprojects/gmobile" "$GMOBILE_COMMIT" "gmobile (for phosh)"
    check_pin "$SOURCE_DIR/subprojects/feedbackd" "$LIBFEEDBACK_COMMIT" "feedbackd"
    check_pin "$SOURCE_DIR/subprojects/gvc" "$GVC_COMMIT" "libgvc"

    echo "Building phosh..."
    ninja -C "$build" -j"$jobs"

    echo "Installing phosh into the stage..."
    DESTDIR="$stage" meson install -C "$build" --no-rebuild --strip >/dev/null

    # What upstream installs for a systemd and gnome-session desktop. The launcher's own session
    # script and session file are a later step (docs/PHOSH.md, "Packaging"), and a script of the
    # same name from here would be taken for it.
    rm -rf "$stage/lib/systemd" "$stage/share/gnome-session" "$stage/share/wayland-sessions" \
        "$stage/bin/phosh-session"

    # Schemas phosh opens that no Termux package provides (gnome-settings-daemon's power and
    # touchscreen ones, GNOME Shell's keybindings): GLib aborts the shell without them.
    cp "$SCRIPT_DIR"/phosh/*.gschema.xml "$stage/share/glib-2.0/schemas/"
}
# phosh-mobile-settings (M4): the four panels this build keeps are the overview (app filter, hidden
# apps), the compositor (display scale), the top bar (quick settings layout) and feedback; every
# other panel is compiled out by the options below, so there is no library to stub:
#   -Dlang-panel=false        accountsservice and polkit (and libpms)
#   -Dalerts-panel=false      libcellbroadcast
#   -Dlockscreen-panel=false  phosh has no lock screen
#   -Dosk-panel=false         phosh has no on-screen keyboard manager (libpms)
#   -Dupdates-panel=false     systemd-sysupdate (libpms)
#   -Dwelcome-panel, -Dconvergence-panel, -Dsensors-panel, -Dfeatures-panel, -Dabout-panel=false
# libnm is needed only by the panels taken from GNOME Settings (-Dgcc-panels, off), and the device
# plugin (librem5, libsensors) and the tests are off. It is built after phosh, in the same stage:
# it needs phosh's installed headers and .pc files (phosh-plugins, phosh-settings) and its
# libfeedback, which the stage still has before the app tree below drops include/ and
# lib/pkgconfig. They are copied to $TL_SYSROOT/tl-phosh-dev, with .pc files in the sysroot's
# pkgconfig directory, because the cross file's pkg-config takes every path to be inside the sysroot;
# both go away after the build. The compositor panel's display scale is the gsettings key
# mobi.phosh.MobileSettings display-scale, which the session script turns into PHOSH_SCALE for phoc
# (recipes/cross/phosh-mobile-settings/0013).
PMS_PANELS_OFF=(
    welcome lang alerts lockscreen osk convergence sensors features updates about
)

build_phosh_mobile_settings() {
    fetch_tree phosh-mobile-settings "$PMS_URL" "$PMS_SHA256" "$PMS_VERSION" "$PMS_COMMIT"
    local build="$TL_BUILD_DIR/phosh-mobile-settings/build-$TL_ARCH" native=() opts=() panel
    local prefix="$TL_SYSROOT$TERMUX_PREFIX" dev="$TL_SYSROOT/tl-phosh-dev" pc
    [ -z "${TL_NATIVE_FILE:-}" ] || native=(--native-file "$TL_NATIVE_FILE")
    for panel in "${PMS_PANELS_OFF[@]}"; do opts+=("-D$panel-panel=false"); done

    # phosh's headers, .pc files and libfeedback, from the stage phosh was installed into
    [ -f "$stage/lib/libfeedback-0.0.so" ] && [ -d "$stage/include/phosh" ] || {
        echo "error: phosh-mobile-settings is built after phosh (TL_PHOSH_TREES), in the same stage" >&2
        exit 1
    }
    rm -rf "$dev"
    mkdir -p "$dev/include" "$dev/lib"
    cp -a "$stage/include/phosh" "$stage/include/libfeedback-0.0" "$dev/include/"
    cp -a "$stage"/lib/libfeedback-0.0.so* "$dev/lib/"
    for pc in phosh-plugins phosh-settings libfeedback-0.0; do
        sed -e 's#^prefix=/$#prefix=/tl-phosh-dev#' "$stage/lib/pkgconfig/$pc.pc" \
            > "$prefix/lib/pkgconfig/$pc.pc"
    done

    echo "Configuring phosh-mobile-settings $PMS_VERSION for $TL_ARCH..."
    rm -rf "$build"
    meson setup "$build" "$SOURCE_DIR" --cross-file "$cross_file" "${native[@]}" \
        --prefix=/ --buildtype=release --wrap-mode=default \
        -Dtests=false -Dplugins=false -Dintrospection=false -Dexamples=false -Dman=false \
        "${opts[@]}" \
        -Dgmobile:default_library=static
    check_pin "$SOURCE_DIR/subprojects/gmobile" "$GMOBILE_COMMIT" "gmobile (for phosh-mobile-settings)"
    check_pin "$SOURCE_DIR/subprojects/gvc" "$GVC_COMMIT" "libgvc (for phosh-mobile-settings)"

    echo "Building phosh-mobile-settings..."
    ninja -C "$build" -j"$jobs"

    echo "Installing phosh-mobile-settings into the stage..."
    DESTDIR="$stage" meson install -C "$build" --no-rebuild --strip >/dev/null

    rm -rf "$dev"
    for pc in phosh-plugins phosh-settings libfeedback-0.0; do rm -f "$prefix/lib/pkgconfig/$pc.pc"; done
}
# tl-feedbackd (M3, #13): this repository's own daemon, GLib and GIO only; it owns
# org.sigxcpu.Feedback and turns feedback events into launcherctl vibrate calls. It goes to
# bin/tl-feedbackd, with its D-Bus activation file in share/dbus-1/services/. D-Bus wants an absolute
# Exec= and the archive's root is wherever the store unpacks it ($HOME/.local/lib/phosh, as the
# session script's fallback has it), so the file's Exec is a shell line that finds it from $HOME.
build_tl_feedbackd() {
    local build="$TL_BUILD_DIR/tl-feedbackd/build-$TL_ARCH" native=() exec_line
    [ -z "${TL_NATIVE_FILE:-}" ] || native=(--native-file "$TL_NATIVE_FILE")
    exec_line="$TERMUX_PREFIX/bin/sh -c 'exec \"\${PHOSH_APP:-\$HOME/.local/lib/phosh}/bin/tl-feedbackd\"'"
    echo "Configuring tl-feedbackd for $TL_ARCH..."
    rm -rf "$build"
    meson setup "$build" "$SCRIPT_DIR/tl-feedbackd" --cross-file "$cross_file" "${native[@]}" \
        --prefix=/ --buildtype=release "-Dservice_exec=$exec_line"
    echo "Building tl-feedbackd..."
    ninja -C "$build" -j"$jobs"
    DESTDIR="$stage" meson install -C "$build" --no-rebuild --strip >/dev/null
}

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
# stage; none is needed to run phoc (wlroots is inside the binary) or phosh (gmobile and libgvc are
# inside the binary too). libfeedback's shared library stays: phosh needs it at run time.
rm -rf "$stage/include" "$stage/lib/pkgconfig" "$stage/lib/udev" "$stage"/lib/*.a "$stage"/lib/libgmobile*
find "$stage" -mindepth 1 -type d -empty -delete
# The launcher's session script (upstream's own was dropped in build_phosh): the archive's exe=.
mkdir -p "$stage/bin"
install -m 755 "$SCRIPT_DIR/phosh-session" "$stage/bin/phosh-session"

# --- checks ---------------------------------------------------------------------------------
readelf="$NDK_BIN/llvm-readelf"
check_phoc() {
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
    # Xwayland is in, with the device's paths (phoc patch 0007): the binary Termux installs, the
    # sockets where Termux's libxcb looks, and no path of the build machine's sysroot.
    grep -qa "$TERMUX_PREFIX/bin/Xwayland" "$stage/bin/phoc" || {
        echo "error: phoc has no Xwayland, or not $TERMUX_PREFIX/bin/Xwayland" >&2
        exit 1
    }
    grep -qa "$TERMUX_PREFIX/tmp/.X11-unix" "$stage/bin/phoc" || {
        echo "error: phoc's Xwayland sockets are not in $TERMUX_PREFIX/tmp/.X11-unix" >&2
        exit 1
    }
    if grep -qa "$TL_SYSROOT$TERMUX_PREFIX/bin/Xwayland" "$stage/bin/phoc"; then
        echo "error: phoc has the build sysroot's Xwayland path compiled in" >&2
        exit 1
    fi
    # meson install drops the build and sysroot directories from RUNPATH; only the device prefix stays.
    if "$readelf" -d "$stage/bin/phoc" | grep -E 'RUNPATH|RPATH' | grep -q "$TL_BUILD_DIR\|$TL_SYSROOT"; then
        echo "error: phoc's RUNPATH names a build directory" >&2
        exit 1
    fi
}

check_tl_feedbackd() {
    local svc="$stage/share/dbus-1/services/org.sigxcpu.Feedback.service"
    [ -x "$stage/bin/tl-feedbackd" ] || { echo "error: no bin/tl-feedbackd in the stage" >&2; exit 1; }
    [ -f "$svc" ] || { echo "error: no D-Bus activation file for tl-feedbackd" >&2; exit 1; }
    grep -q '^Name=org.sigxcpu.Feedback$' "$svc" && grep -q '^Exec=.*tl-feedbackd' "$svc" || {
        echo "error: the activation file of tl-feedbackd is wrong" >&2
        exit 1
    }
    # GLib and GIO only (plus libc): no libsoup, libcurl or json-glib crept in.
    if "$readelf" -d "$stage/bin/tl-feedbackd" | grep NEEDED | grep -vE 'libglib-2|libgio-2|libgobject-2|libgmodule-2|libc\.so|libm\.so|libdl\.so|libintl|libpcre|libffi|libiconv|libz'; then
        echo "error: tl-feedbackd links a library beyond GLib" >&2
        exit 1
    fi
}

check_phosh() {
    local needed
    [ -x "$stage/bin/phosh" ] || { echo "error: no bin/phosh in the stage" >&2; exit 1; }
    [ -f "$stage/lib/libfeedback-0.0.so" ] || { echo "error: no lib/libfeedback-0.0.so in the stage" >&2; exit 1; }
    # No library of a feature that is compiled out, and none of the ones Termux does not have.
    needed=$("$readelf" -d "$stage/bin/phosh" | grep NEEDED)
    if printf '%s\n' "$needed" | grep -E 'libsystemd|libelogind|libpam|libnm|libpolkit|libgudev|libudev|libmm-glib|libecal|libedataserver|libgnome-bluetooth|libcall-ui|libsecret|libgeoclue'; then
        echo "error: phosh links a library of a feature that is compiled out" >&2
        exit 1
    fi
    if "$readelf" -d "$stage/bin/phosh" | grep -E 'RUNPATH|RPATH' | grep -q "$TL_BUILD_DIR\|$TL_SYSROOT"; then
        echo "error: phosh's RUNPATH names a build directory" >&2
        exit 1
    fi
    "$readelf" -d "$stage/bin/phosh" | grep -E 'RUNPATH' | grep -q '\$ORIGIN/../lib' || {
        echo "error: phosh does not look for libfeedback in ../lib" >&2
        exit 1
    }
    # The test hooks are not in: TlState and TlTile answer "not supported" (patch 0033).
    grep -qa 'Built without -Dtl-debug' "$stage/bin/phosh" || {
        echo "error: phosh has the TlState and TlTile test hooks (-Dtl-debug); a phone's build must not" >&2
        exit 1
    }
    check_phosh_schemas
}

# check_phosh_value <schema> <key> <wanted> — what the compiled schemas say, read with the
# memory backend so that no user setting gets in.
check_phosh_value() {
    local got
    got=$(XDG_CURRENT_DESKTOP=Phosh GSETTINGS_SCHEMA_DIR="$TL_BUILD_DIR/schema-check" \
          GSETTINGS_BACKEND=memory gsettings get "$1" "$2")
    case "$got" in
        "$3"|"@as $3") ;;
        *) echo "error: $1 $2 is '$got', not $3" >&2; exit 1 ;;
    esac
}

# The schemas phosh installs, compiled the way the launcher's session will compile them (the
# archive's next to the system's), with this build's overrides. It checks that they compile and
# that the three defaults the build is meant to change are changed; it is not part of the archive.
check_phosh_schemas() {
    local dir="$TL_BUILD_DIR/schema-check" sys="$TL_SYSROOT$TERMUX_PREFIX/share/glib-2.0/schemas"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp "$stage"/share/glib-2.0/schemas/* "$dir/"
    cp "$sys"/org.gnome.desktop*.xml "$dir/"
    # 00_mobi.Phosh.gschema.override also names gnome-settings-daemon's schemas, which are not here
    glib-compile-schemas "$dir" 2>&1 | grep -v 'non-existent schema' || true
    [ -f "$dir/gschemas.compiled" ] || { echo "error: phosh's schemas do not compile" >&2; exit 1; }
    if command -v gsettings >/dev/null 2>&1; then
        check_phosh_value sm.puri.phosh app-filter-mode '[]'
        check_phosh_value org.gnome.desktop.screensaver lock-enabled false
        check_phosh_value org.gnome.desktop.a11y.applications screen-keyboard-enabled false
    fi
}

check_phosh_mobile_settings() {
    local bin="$stage/bin/phosh-mobile-settings" panel type desktop="$stage/share/applications/mobi.phosh.MobileSettings.desktop"
    local dir="$TL_BUILD_DIR/pms-schema-check" got
    [ -x "$bin" ] || { echo "error: no bin/phosh-mobile-settings in the stage" >&2; exit 1; }
    # No library of a panel that is compiled out, and none of the ones Termux does not have.
    if "$readelf" -d "$bin" | grep NEEDED | grep -E 'libaccountsservice|libpolkit|libnm|libcellbroadcast|libpms|libgudev|libsystemd|libgmobile'; then
        echo "error: phosh-mobile-settings links a library of a panel that is compiled out" >&2
        exit 1
    fi
    "$readelf" -d "$bin" | grep NEEDED | grep -q libfeedback || {
        echo "error: phosh-mobile-settings does not link libfeedback" >&2
        exit 1
    }
    if "$readelf" -d "$bin" | grep -E 'RUNPATH|RPATH' | grep -q "$TL_BUILD_DIR\|$TL_SYSROOT"; then
        echo "error: phosh-mobile-settings' RUNPATH names a build directory" >&2
        exit 1
    fi
    "$readelf" -d "$bin" | grep -E 'RUNPATH' | grep -q '\$ORIGIN/../lib' || {
        echo "error: phosh-mobile-settings does not look for libfeedback in ../lib" >&2
        exit 1
    }
    # The four panels are in the binary, and the ones that are off are not (the type names are in
    # the GType registration, and the GtkBuilder files in the resource are filtered the same way).
    for type in MsOverviewPanel MsCompositorPanel MsTopbarPanel MsFeedbackPanel; do
        grep -qa "$type" "$bin" || { echo "error: phosh-mobile-settings has no $type" >&2; exit 1; }
    done
    for type in MsLangPanel MsAlertsPanel MsLockscreenPanel MsOskPanel MsUpdatesPanel MsWelcomePanel \
                MsConvergencePanel MsSensorPanel MsFeaturesPanel MsAboutPanel; do
        if grep -qa "$type" "$bin"; then
            echo "error: phosh-mobile-settings still has $type, which is compiled out" >&2
            exit 1
        fi
    done
    # Its desktop file is in the archive, so that phosh's grid lists it, and it starts the binary
    # directly (the D-Bus service file is not installed).
    [ -f "$desktop" ] || { echo "error: no share/applications/mobi.phosh.MobileSettings.desktop in the stage" >&2; exit 1; }
    grep -q '^Exec=phosh-mobile-settings$' "$desktop" && grep -q '^DBusActivatable=false$' "$desktop" || {
        echo "error: the desktop file of phosh-mobile-settings is not the one the patches write" >&2
        exit 1
    }
    [ ! -e "$stage/share/dbus-1/services/mobi.phosh.MobileSettings.service" ] || {
        echo "error: phosh-mobile-settings installs a D-Bus service file with a path of the build" >&2
        exit 1
    }
    # (desktop-file-validate rejects OnlyShowIn=Phosh, which freedesktop.org has not registered)
    grep -q '^OnlyShowIn=Phosh;$' "$desktop" || {
        echo "error: the desktop file of phosh-mobile-settings is not shown in Phosh" >&2
        exit 1
    }
    # Its schema compiles on its own, and display-scale (what the compositor panel writes and the
    # session script turns into PHOSH_SCALE) is 0.0, automatic, by default.
    rm -rf "$dir"
    mkdir -p "$dir"
    cp "$stage/share/glib-2.0/schemas/mobi.phosh.MobileSettings.gschema.xml" "$dir/"
    glib-compile-schemas --strict "$dir" || { echo "error: the schema of phosh-mobile-settings does not compile" >&2; exit 1; }
    if command -v gsettings >/dev/null 2>&1; then
        got=$(GSETTINGS_SCHEMA_DIR="$dir" GSETTINGS_BACKEND=memory gsettings get mobi.phosh.MobileSettings display-scale)
        [ "$got" = "0.0" ] || { echo "error: display-scale is '$got', not 0.0" >&2; exit 1; }
    fi
}

for tree in $TL_PHOSH_TREES; do
    case "$tree" in
        phoc) check_phoc ;;
        phosh) check_phosh ;;
        phosh-mobile-settings) check_phosh_mobile_settings ;;
        tl-feedbackd) check_tl_feedbackd ;;
    esac
done

# --- the archive ----------------------------------------------------------------------------
rm -f "$TL_OUT/phosh"
(
    cd "$stage"
    find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort \
        | tar --no-recursion -T - -cf - --format=gnu --mtime="@$PHOSH_MTIME" \
            --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w'
) | gzip -9n > "$TL_OUT/phosh"

echo
echo "Built: $TL_OUT/phosh (phoc $PHOC_VERSION, phosh $PHOSH_VERSION for $TL_ARCH: $TL_PHOSH_TREES)"
for tree in $TL_PHOSH_TREES; do
    if [ -x "$stage/bin/$tree" ]; then
        echo "-- $tree"
        "$readelf" -d "$stage/bin/$tree" | grep -E "NEEDED|RUNPATH" || true
    fi
done
file "$stage/bin/"* 2>/dev/null || true
ls -l "$TL_OUT/phosh"
sha256sum "$TL_OUT/phosh"
