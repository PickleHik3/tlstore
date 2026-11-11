#!/bin/bash
# build-herdr-gui.sh — the Herdr desktop app (herdr-app) for TL_ARCH (aarch64 by default, or
# x86_64), built from source for <arch>-linux-android (bionic), as one .tar.gz app tree. It draws
# in an X11 window (Termux:X11 or the launcher's own X server) through Vulkan; the terminals it
# shows run in herdr-core, the catalog's hidden herdr-core item (build-herdr-core.sh).
#
# The archive (an archive item, docs/SPEC.md Revision 14), top level = the app root:
#
#   bin/herdr-app    a start script, what the catalog's exe= runs: it picks the Vulkan driver
#                    the launcher recommends, or says how to get one, then execs ../libexec
#   libexec/herdr-app  the stripped binary
#   share/herdr-app.svg  upstream's app icon, named by the launcher's desktop entry
#                    (desktop/herdr-app.<edition>.desktop, the herdr-gui-desktop part)
#   LICENSE, THIRD-PARTY-NOTICES
#
# No prefix is baked in, so one copy serves every launcher edition: the binary finds Termux's
# libraries (libxcb, libxkbcommon; fontconfig and Vulkan are dlopen()ed) through a RUNPATH
# relative to itself, $ORIGIN/../../../../../usr/lib, which from ~/.local/lib/herdr-gui/libexec is
# the edition's $PREFIX/lib. It is linked against com.termux's packages (the libraries are the
# same on every edition; only their .pc files name a prefix).
#
# What it takes, all of it in this script and its patches:
#   - upstream's Rust from the pinned commit below (upstream tags no releases in git), with the
#     cargo target <arch>-linux-android linked by the NDK's clang at API 29 (libghostty-vt's
#     Zig TLS; see build-herdr-core.sh and build-herdr.sh);
#   - libghostty-vt from vendor/ghostty, built by crates/ghostty-sys/build.rs with Zig 0.16.0
#     for <arch>-linux-android, SIMD off; bindgen for its header and for quickjs-jit-sys, pointed
#     at the NDK's sysroot; 0001-ghostty-android-no-libc-stubs.patch keeps wuffs' calloc/free
#     stubs out of it (see build-herdr-core.sh);
#   - a Termux sysroot ($TL_SYSROOT, from termux-sysroot.sh via build-asset.sh) for libxcb and
#     libxkbcommon, found through pkg-config;
#   - 0001-herdr-app-android.patch: the Linux cfgs also true on Android across the app and its
#     vendored gpui, X11 reached through the socket under $TMPDIR/$PREFIX (Termux's libxcb only
#     knows its build-time prefix), no libgcc_s, and no upstream core installer (the store
#     installs herdr-core). The app's own updater is off already: only upstream's release
#     packaging sets HERDR_APP_RELEASE;
#   - four crates.io crates the port patches (0002-herdr-app-<crate>.patch), fetched and checked
#     against the sha256 below into termux-vendor/<crate>, where the app patch's [patch.crates-io]
#     points.
#
# Requires: rustup with the <arch>-linux-android target, the Android NDK, git, curl, xz, GNU tar,
# gzip, pkg-config, and an x86_64 Linux host.
set -euo pipefail

APP_URL="https://github.com/herdrdev/herdr-app.git"
APP_COMMIT="adf94cb2c9b6f1cadbb31c51f84114b1aa332f0a"   # 0.1.13 on master
APP_VERSION="0.1.13"
ZIG_VERSION="0.16.0"
ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
# name version sha256 — crates.io crates patched by 0002-herdr-app-<name>.patch
VENDORED='
gpui-pre-platform 0.3.8 e200b7b78836f1a0fc70767d971768e88f29d8b91b697285c15fb8e373635a3e
wayland-cursor 0.31.14 4a52d18780be9b1314328a3de5f930b73d2200112e3849ca6cb11822793fb34d
x11rb-protocol 0.13.2 ea6fc2961e4ef194dcbfe56bb845534d0dc8098940c7e5c012a258bfec6701bd
zed-scap 0.0.8-zed b6b338d705ae33a43ca00287c11129303a7a0aa57b101b72a1c08c863f698ac8
'
# Every entry's mtime in the archive: a fixed date, so a rebuild of the same pin is the same asset.
APP_MTIME=1794009600

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCH="$SCRIPT_DIR/0001-herdr-app-android.patch"
GHOSTTY_PATCH="$SCRIPT_DIR/0001-ghostty-android-no-libc-stubs.patch"

TL_NDK=${TL_NDK:-"$HOME/Android/Sdk/ndk/29.0.14206865"}
TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-herdr-gui"}
TL_SYSROOT=${TL_SYSROOT:?set TL_SYSROOT to a Termux sysroot (build-asset.sh assembles one)}
TL_ANDROID_API=${TL_ANDROID_API:-29}
TL_ARCH=${TL_ARCH:-aarch64}
case "$TL_ARCH" in
    aarch64|x86_64) ;;
    *) echo "error: no herdr-gui build for $TL_ARCH" >&2; exit 2 ;;
esac
TL_TRIPLE=${TL_TRIPLE:-$TL_ARCH-linux-android}
triple_env=${TL_TRIPLE//-/_}
triple_env_upper=${triple_env^^}
# The sysroot's own prefix: termux-sysroot.sh keeps the packages' absolute layout.
sysroot_prefix="$TL_SYSROOT/data/data/com.termux/files/usr"
[ -f "$sysroot_prefix/lib/pkgconfig/xcb.pc" ] || {
    echo "error: no libxcb in $TL_SYSROOT (build-asset.sh's sysroot step installs it)" >&2
    exit 1
}

NDK_BIN="$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
[ -d "$NDK_BIN" ] || { echo "error: NDK not found at $TL_NDK (set TL_NDK)" >&2; exit 1; }

export RUSTUP_TOOLCHAIN=${RUSTUP_TOOLCHAIN:-stable}
rustup target list --installed 2>/dev/null | grep -qx "$TL_TRIPLE" || {
    echo "error: rust target missing — run: rustup target add $TL_TRIPLE" >&2
    exit 1
}

mkdir -p "$TL_OUT" "$TL_BUILD_DIR"

# --- Zig ----------------------------------------------------------------------------------------
if [ -z "${ZIG:-}" ]; then
    [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] || {
        echo "error: no pinned Zig download for this host; set ZIG to a Zig $ZIG_VERSION" >&2
        exit 1
    }
    zig_dir="$TL_BUILD_DIR/zig-$ZIG_VERSION"
    if [ ! -x "$zig_dir/zig" ]; then
        tarball="$TL_BUILD_DIR/zig-x86_64-linux-$ZIG_VERSION.tar.xz"
        [ -f "$tarball" ] || curl -fsSL -o "$tarball" \
            "https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz"
        echo "$ZIG_SHA256  $tarball" | sha256sum -c - >/dev/null || {
            echo "error: the Zig tarball does not match its pinned sha256" >&2
            rm -f "$tarball"
            exit 1
        }
        rm -rf "$zig_dir" "$zig_dir.tmp"
        mkdir -p "$zig_dir.tmp"
        tar -xJf "$tarball" -C "$zig_dir.tmp" --strip-components=1
        mv "$zig_dir.tmp" "$zig_dir"
    fi
    ZIG="$zig_dir/zig"
fi
[ "$("$ZIG" version)" = "$ZIG_VERSION" ] || {
    echo "error: Zig $("$ZIG" version) at $ZIG, libghostty-vt needs $ZIG_VERSION" >&2
    exit 1
}
export ZIG
export ZIG_GLOBAL_CACHE_DIR="$TL_BUILD_DIR/zig-cache"

# --- the source ---------------------------------------------------------------------------------
source_dir="$TL_BUILD_DIR/source"
patches_sum=$(cat "$PATCH" "$GHOSTTY_PATCH" "$SCRIPT_DIR"/0002-herdr-app-*.patch | sha256sum | cut -d' ' -f1)
prepared="$APP_COMMIT $patches_sum $(sha256sum < "${BASH_SOURCE[0]}" | cut -d' ' -f1)"
if [ "$(cat "$source_dir/.tl-prepared" 2>/dev/null || true)" != "$prepared" ]; then
    rm -rf "$source_dir"
    echo "Fetching herdr-app $APP_VERSION ($APP_COMMIT)..."
    git init -q "$source_dir"
    git -C "$source_dir" remote add origin "$APP_URL"
    git -C "$source_dir" fetch -q --depth 1 origin "$APP_COMMIT"
    git -C "$source_dir" checkout -q --detach FETCH_HEAD
    [ "$(git -C "$source_dir" rev-parse HEAD)" = "$APP_COMMIT" ] || {
        echo "error: fetched a commit other than $APP_COMMIT" >&2
        exit 1
    }
    git -C "$source_dir" submodule update -q --init --depth 1
    echo "Applying the Android patch..."
    git -C "$source_dir" apply "$PATCH" || {
        echo "error: 0001-herdr-app-android.patch does not apply to herdr-app $APP_VERSION; rebase it" >&2
        exit 1
    }
    echo "Patching ghostty's wuffs libc stubs out of the Android build..."
    git -C "$source_dir/vendor/ghostty" apply "$GHOSTTY_PATCH" || {
        echo "error: 0001-ghostty-android-no-libc-stubs.patch does not apply to vendor/ghostty; rebase it" >&2
        exit 1
    }
    echo "Fetching and patching the vendored crates..."
    printf '%s\n' "$VENDORED" | while read -r name version sha; do
        [ -n "$name" ] || continue
        crate="$TL_BUILD_DIR/$name-$version.crate"
        [ -f "$crate" ] || curl -fsSL -o "$crate" "https://static.crates.io/crates/$name/$name-$version.crate"
        echo "$sha  $crate" | sha256sum -c - >/dev/null || {
            echo "error: $name-$version.crate does not match its pinned sha256" >&2
            rm -f "$crate"
            exit 1
        }
        dest="$source_dir/termux-vendor/$name"
        mkdir -p "$dest"
        tar -xzf "$crate" -C "$dest" --strip-components=1
        patch -s -p1 -d "$dest" < "$SCRIPT_DIR/0002-herdr-app-$name.patch" || {
            echo "error: 0002-herdr-app-$name.patch does not apply to $name $version" >&2
            exit 1
        }
    done
    printf '%s\n' "$prepared" > "$source_dir/.tl-prepared"
fi

echo "Building..."
(
    cd "$source_dir"
    ndk_sysroot="$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    export "CARGO_TARGET_${triple_env_upper}_LINKER=$NDK_BIN/$TL_TRIPLE$TL_ANDROID_API-clang"
    export "CC_${triple_env}=$NDK_BIN/$TL_TRIPLE$TL_ANDROID_API-clang"
    export "CXX_${triple_env}=$NDK_BIN/$TL_TRIPLE$TL_ANDROID_API-clang++"
    export "AR_${triple_env}=$NDK_BIN/llvm-ar"
    # bindgen (ghostty-sys, quickjs-jit-sys) parses headers for the target: the NDK's sysroot and
    # its clang's own builtin headers (stdbool.h and the like).
    resource_dir=$("$NDK_BIN/clang" -print-resource-dir)
    # bindgen also asks the first clang on PATH for its include paths and adds them; on a CI
    # runner that is llvm-18, whose builtin headers then sit between these and bionic's, and
    # clang 21's stdint.h include_nexts into clang 18's, which its guard skips. Naming bionic's
    # include directories here, right after the builtins, keeps that clang's out of the way.
    # The NDK's own libclang parses them, the same version as the builtins.
    export LIBCLANG_PATH="$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/lib"
    export "BINDGEN_EXTRA_CLANG_ARGS_${triple_env}=--target=$TL_TRIPLE$TL_ANDROID_API --sysroot=$ndk_sysroot -isystem $resource_dir/include -isystem $ndk_sysroot/usr/include/$TL_TRIPLE -isystem $ndk_sysroot/usr/include"
    # quickjs-jit-sys also runs bindgen for the build host; a libclang without a clang beside it
    # lacks the builtin headers, and Zig ships the same ones.
    if ! command -v clang >/dev/null 2>&1; then
        export BINDGEN_EXTRA_CLANG_ARGS_x86_64_unknown_linux_gnu="-isystem $(dirname "$ZIG")/lib/include"
    fi
    export PKG_CONFIG_ALLOW_CROSS=1
    export PKG_CONFIG_SYSROOT_DIR="$TL_SYSROOT"
    export "PKG_CONFIG_LIBDIR_${triple_env}=$sysroot_prefix/lib/pkgconfig:$sysroot_prefix/share/pkgconfig"
    # $ORIGIN stays literal: the dynamic linker expands it.
    # shellcheck disable=SC2016
    export "CARGO_TARGET_${triple_env_upper}_RUSTFLAGS=-L $sysroot_prefix/lib -C link-arg=-Wl,-rpath,\$ORIGIN/../../../../../usr/lib"
    # Fat LTO over gpui needs more memory than a CI runner has.
    export CARGO_PROFILE_RELEASE_LTO=off
    cargo build --release --locked --target "$TL_TRIPLE" --bin herdr-app
)

# --- the app tree -------------------------------------------------------------------------------
stage="$TL_BUILD_DIR/stage-$TL_ARCH"
rm -rf "$stage"
mkdir -p "$stage/bin" "$stage/libexec" "$stage/share"
"$NDK_BIN/llvm-strip" -o "$stage/libexec/herdr-app" "$source_dir/target/$TL_TRIPLE/release/herdr-app"
chmod 755 "$stage/libexec/herdr-app"

cat > "$stage/bin/herdr-app" <<'EOF'
#!/bin/sh
# herdr-app as tlstore ships it: built from upstream's source for Android, in ../libexec.
SELF="$0"
while [ -L "$SELF" ]; do
  LINK="$(readlink "$SELF")"
  case "$LINK" in
    /*) SELF="$LINK" ;;
    *) SELF="$(dirname -- "$SELF")/$LINK" ;;
  esac
done
ROOT="$(CDPATH= cd -- "$(dirname -- "$SELF")/.." && pwd -P)"
# ~/.local/lib/herdr-gui -> the edition's $PREFIX, the same walk as the binary's RUNPATH.
USR="${PREFIX:-$ROOT/../../../../usr}"

# The store installs no Vulkan driver: in Termux Launcher it is the one Graphics acceleration
# sets up. When nothing chose one already (a launch from the app drawer carries the profile's own
# environment), take the driver the launcher recommends, only if that driver is installed, with
# the Vulkan settings that go with it (Turnip's TU_DEBUG, Mesa's MESA_VK_*). Its OpenGL ones
# (Zink, virgl) are left out: this app draws through Vulkan alone.
if [ -z "${VK_ICD_FILENAMES:-}${VK_DRIVER_FILES:-}" ] && command -v launcherctl >/dev/null 2>&1; then
  GPU_ENV="$(launcherctl x11 gpu --env 2>/dev/null)"
  ICD="$(printf '%s\n' "$GPU_ENV" | sed -n 's/^export VK_ICD_FILENAMES=//p' | head -n 1)"
  if [ -n "$ICD" ] && [ -f "$ICD" ]; then
    export VK_ICD_FILENAMES="$ICD"
    for line in $(printf '%s\n' "$GPU_ENV" | sed -n -e 's/^export \(TU_DEBUG=[^ ]*\)$/\1/p' -e 's/^export \(MESA_VK_[A-Z_]*=[^ ]*\)$/\1/p'); do
      export "${line?}"
    done
  fi
fi
# A virgl profile (a drawer launch on a phone whose GPU has no Mesa driver, such as an Intel one)
# sends Mesa's OpenGL to the virgl server, which the launcher starts for OpenGL apps only. This
# app opens EGL while it starts, and Mesa aborts the whole process when that server is not there,
# so its OpenGL goes back to Mesa's own choice; the drawing stays on Vulkan either way.
[ "${GALLIUM_DRIVER:-}" != virpipe ] || unset GALLIUM_DRIVER
# The same profile's LIBGL_KOPPER_DISABLE=1 steers the app off a hardware Vulkan driver it would
# otherwise pick (an Intel ANV beside lavapipe ends up unused), and it is an OpenGL knob this
# Vulkan app has no use for.
unset LIBGL_KOPPER_DISABLE

# A terminal opened while the display was down has no DISPLAY, and without one the app runs with
# no window at all. The launcher's display is :0, its socket under the edition's own tmp.
if [ -z "${DISPLAY:-}" ] && [ -S "$USR/tmp/.X11-unix/X0" ]; then
  export DISPLAY=:0
fi
# The app looks for the display's socket under TMPDIR, and a launcher terminal's TMPDIR is a
# folder in HOME, where there is none: the clipboard's own connection then times out and the app
# stops. Point it at the tmp the socket is in.
if [ ! -d "${TMPDIR:-/nonexistent}/.X11-unix" ] && [ -d "$USR/tmp/.X11-unix" ]; then
  export TMPDIR="$USR/tmp"
fi
# No Xcursor theme is on the app's search path here, so a cursor asked for by name comes back
# empty and every cursor stays an arrow. The "core" theme takes them from the X server's cursor
# font, where the text caret is named xterm: the name the launcher's tap-on-text keyboard rule
# reads.
: "${XCURSOR_THEME:=core}"
export XCURSOR_THEME

found=
for f in "$USR"/share/vulkan/icd.d/*.json; do
  [ -f "$f" ] && found=1 && break
done
if [ -z "$found" ]; then
  echo "herdr-app: no Vulkan driver is installed, and it draws through Vulkan." >&2
  if command -v launcherctl >/dev/null 2>&1; then
    echo "  Open Settings > Linux apps > Graphics acceleration and run the benchmark." >&2
  else
    echo "  On an Adreno GPU: pkg install mesa-vulkan-icd-freedreno" >&2
    echo "  On any other:     pkg install vulkan-icd   (software, slower)" >&2
  fi
  exit 1
fi

exec "$ROOT/libexec/herdr-app" "$@"
EOF
chmod 755 "$stage/bin/herdr-app"
cp "$source_dir/LICENSE" "$source_dir/THIRD-PARTY-NOTICES" "$stage/"
cp "$source_dir/assets/icons/herdr-ui-icon-clean.svg" "$stage/share/herdr-app.svg"

rm -f "$TL_OUT/herdr-gui"
(
    cd "$stage"
    find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort \
        | tar --no-recursion -T - -cf - --format=gnu --mtime="@$APP_MTIME" \
            --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w'
) | gzip -9n > "$TL_OUT/herdr-gui"

echo
echo "Built: $TL_OUT/herdr-gui (herdr-app $APP_VERSION for $TL_ARCH, as an app tree)"
"$NDK_BIN/llvm-readelf" -d "$stage/libexec/herdr-app" | grep -E "NEEDED|RUNPATH" || true
ls -l "$TL_OUT/herdr-gui"
sha256sum "$TL_OUT/herdr-gui"
