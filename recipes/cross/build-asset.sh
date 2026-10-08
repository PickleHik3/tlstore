#!/bin/bash
# build-asset.sh — one release asset from the recipes in this directory, under the name the
# tlstore catalog installs it by.
#
#   ./build-asset.sh <tool> [edition]
#
#   tool      btop | tl-priv | kitten | sigye | fastfetch | dawn | musl-loader | musl-runtime
#   edition   com.termux (default) | io.vaj.tl — only for fastfetch, dawn and musl-loader, the
#             three whose binary carries the edition's prefix (README.md, "One build per
#             launcher edition"); the others build once for every edition
#
# Runs the tool's recipe (assembling the edition's Termux sysroot first where one is needed)
# and copies the result into $TL_ASSETS as <tool>-<arch>, or <tool>-<package>-<arch> for an
# edition other than com.termux — the asset name a bare `binaries:<tool>@<tag>` source resolves
# to on a phone with that processor. musl-runtime yields two, musl-libgcc-<arch> and
# musl-libstdcxx-<arch>.
#
# This is what .github/workflows/build.yml runs, one job per (tool, edition, arch), and it runs
# the same way on a laptop. Env:
#   TL_ARCH     aarch64 (default) or x86_64: the processor to build for. Everything that names
#               it — the NDK triple, ANDROID_ABI, compiler-rt, GOARCH, the Rust target, the
#               Termux and Alpine package architecture, the asset suffix — is derived from this
#               one value here and handed to the recipes. The io.vaj.tl edition is aarch64 only.
#   TL_NDK      the Android NDK (default $ANDROID_NDK_HOME, else $ANDROID_HOME/ndk/29.0.14206865)
#   TL_WORK     where sources, sysroots and build trees go (default $PWD); the sysroot and the
#               .deb cache for an edition are TL_WORK/sysroot-<edition>-<arch> and
#               TL_WORK/debs-<edition>-<arch>, so a second tool for the same edition reuses them
#   TL_ASSETS   where the finished assets land (default $TL_WORK/assets)
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
tool="${1:-}"
edition="${2:-com.termux}"
[ -n "$tool" ] || { echo "usage: build-asset.sh <tool> [edition]" >&2; exit 2; }
[ "$edition" != "-" ] || edition=com.termux

TL_WORK=${TL_WORK:-"$PWD"}
TL_ASSETS=${TL_ASSETS:-"$TL_WORK/assets"}
NDK_VERSION=29.0.14206865
# The launcher's minSdk: what the compilers this script picks itself are pointed at.
MIN_API=26
if [ -z "${TL_NDK:-}" ]; then
    if [ -n "${ANDROID_NDK_HOME:-}" ]; then
        TL_NDK="$ANDROID_NDK_HOME"
    else
        TL_NDK="${ANDROID_HOME:-$HOME/Android/Sdk}/ndk/$NDK_VERSION"
    fi
fi
export TL_NDK

# The processor, and every name the toolchains give it.
TL_ARCH=${TL_ARCH:-aarch64}
# TL_GO_LINK_NDK: Go links android/arm64 itself, but refuses to link android/amd64 without an
# external linker, so the x86_64 kitten is linked by the NDK's clang (build-kitten.sh).
# TL_MUSL_TARGET: the clang target the musl loader is compiled for. musl brings its own headers
# and ABI; the Android aarch64 target agrees with it (and is what has always shipped), but
# Android's x86_64 ABI makes long double 128-bit where musl's x86_64 code is x87's 80-bit, so
# there the loader is compiled for x86_64-linux-musl.
case "$TL_ARCH" in
    aarch64) TL_ANDROID_ABI=arm64-v8a; TL_GOARCH=arm64; TL_GO_LINK_NDK=0
        TL_MUSL_TARGET="aarch64-linux-android$MIN_API" ;;
    x86_64) TL_ANDROID_ABI=x86_64; TL_GOARCH=amd64; TL_GO_LINK_NDK=1
        TL_MUSL_TARGET=x86_64-linux-musl ;;
    *) echo "build-asset: unknown TL_ARCH $TL_ARCH (aarch64 or x86_64)" >&2; exit 2 ;;
esac
# The NDK's clang triple and the Rust target are both <arch>-linux-android, and Termux's and
# Alpine's package repositories name the architecture exactly as TL_ARCH does.
TL_TRIPLE="$TL_ARCH-linux-android"
TL_TERMUX_ARCH="$TL_ARCH"
TL_ALPINE_ARCH="$TL_ARCH"
export TL_ARCH TL_ANDROID_ABI TL_GOARCH TL_TRIPLE TL_TERMUX_ARCH TL_ALPINE_ARCH

case "$edition" in
    com.termux)
        TERMUX_REPO="https://packages.termux.dev/apt/termux-main"
        suffix=""
        ;;
    io.vaj.tl)
        TERMUX_REPO="https://repo.pathayam.xyz"
        suffix="-$edition"
        # Its package repository and bootstrap are aarch64 only, and so is its APK.
        if [ "$TL_ARCH" != aarch64 ]; then
            echo "build-asset: the io.vaj.tl edition is aarch64 only" >&2
            exit 2
        fi
        ;;
    *) echo "build-asset: unknown edition $edition (com.termux or io.vaj.tl)" >&2; exit 2 ;;
esac
TERMUX_PREFIX="/data/data/$edition/files/usr"
TERMUX_HOME="/data/data/$edition/files/home"
export TERMUX_PREFIX TERMUX_HOME

per_edition() {
    case "$tool" in
        fastfetch|dawn|musl-loader) return 0 ;;
    esac
    if [ "$edition" != com.termux ]; then
        echo "build-asset: $tool is built once for every edition; drop the edition argument" >&2
        exit 2
    fi
    return 1
}
if per_edition; then asset="$tool$suffix-$TL_ARCH"; else asset="$tool-$TL_ARCH"; fi

# Per arch as well as per edition: a build tree configured for one processor must never be
# reused for the other.
export TL_OUT="$TL_WORK/out-$tool-$edition-$TL_ARCH"
export TL_BUILD_DIR="$TL_WORK/build-$tool-$edition-$TL_ARCH"
mkdir -p "$TL_ASSETS" "$TL_OUT" "$TL_BUILD_DIR"

# sysroot <packages…> — the edition's Termux sysroot, from its own repository. Re-running it
# over a cached .deb directory extracts again without touching the network.
sysroot() {
    export TL_SYSROOT="$TL_WORK/sysroot-$edition-$TL_ARCH"
    TL_CACHE="$TL_WORK/debs-$edition-$TL_ARCH" TL_TERMUX_REPO="$TERMUX_REPO" \
        "$SCRIPT_DIR/termux-sysroot.sh" "$@"
}

# The NDK's clang for one target, callable as plain `clang`: build-musl-loader.sh was written for
# Termux's own clang (it names `clang` and a compiler-rt it finds under $PREFIX), and the NDK's
# wrapper scripts cannot be symlinked under another name (they locate the toolchain from $0).
ndk_clang_as_clang() {
    local target="$1" bin="$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin" wrap="$TL_BUILD_DIR/cc"
    [ -x "$bin/clang" ] || { echo "build-asset: no NDK clang at $bin (set TL_NDK)" >&2; exit 1; }
    mkdir -p "$wrap"
    printf '#!/bin/sh\nexec "%s/clang" --target=%s "$@"\n' "$bin" "$target" > "$wrap/clang"
    chmod 755 "$wrap/clang"
    PATH="$wrap:$PATH"
    export PATH
    # The arithmetic helpers musl links in. For an Android target, the NDK's compiler-rt. The NDK
    # has none for x86_64-linux-musl (its x86_64 builtins are Android's, without the 80-bit long
    # double ones such as __mulxc3), so there it is the build host's own x86_64 libgcc.a, which
    # is what musl's configure picks by itself on any x86_64 Linux.
    case "$target" in
        *-android*)
            LIBCC=$(find "$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/lib/clang" \
                \( -name "libclang_rt.builtins-$TL_ARCH-android.a" -o -path "*/$TL_ARCH/libclang_rt.builtins-android.a" \) \
                2>/dev/null | head -1)
            ;;
        x86_64-linux-*)
            [ "$(uname -m)" = x86_64 ] && LIBCC=$(gcc -print-libgcc-file-name 2>/dev/null) || LIBCC=""
            [ -f "$LIBCC" ] || LIBCC=""
            ;;
        *) LIBCC="" ;;
    esac
    [ -n "$LIBCC" ] || { echo "build-asset: no compiler-rt builtins for $target (the x86_64 musl build needs gcc on an x86_64 host)" >&2; exit 1; }
    export LIBCC
}

echo "== $tool for $edition on $TL_ARCH -> $asset"
case "$tool" in
    btop)
        "$SCRIPT_DIR/build-btop.sh"
        cp "$TL_OUT/btop" "$TL_ASSETS/$asset"
        ;;
    tl-priv)
        "$SCRIPT_DIR/build-tl-priv.sh"
        cp "$TL_OUT/tl-priv" "$TL_ASSETS/$asset"
        ;;
    kitten)
        if [ "$TL_GO_LINK_NDK" = 1 ]; then
            TL_CGO_CC="$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/$TL_TRIPLE$MIN_API-clang"
            [ -x "$TL_CGO_CC" ] || { echo "build-asset: no NDK clang at $TL_CGO_CC (set TL_NDK)" >&2; exit 1; }
            export TL_CGO_CC
        fi
        "$SCRIPT_DIR/build-kitten.sh"
        cp "$TL_OUT/kitten-android-$TL_GOARCH" "$TL_ASSETS/$asset"
        ;;
    sigye)
        "$SCRIPT_DIR/build-sigye.sh"
        cp "$TL_OUT/sigye" "$TL_ASSETS/$asset"
        ;;
    fastfetch)
        sysroot
        "$SCRIPT_DIR/build-fastfetch.sh"
        cp "$TL_OUT/fastfetch" "$TL_ASSETS/$asset"
        ;;
    dawn)
        sysroot libcurl openssl zlib libnghttp2
        "$SCRIPT_DIR/build-dawn.sh"
        cp "$TL_OUT/dawn" "$TL_ASSETS/$asset"
        ;;
    musl-loader)
        ndk_clang_as_clang "$TL_MUSL_TARGET"
        # Its shebang is Termux's sh; the script itself is POSIX.
        sh "$SCRIPT_DIR/build-musl-loader.sh"
        cp "$TL_OUT/$asset" "$TL_ASSETS/$asset"
        ;;
    musl-runtime)
        "$SCRIPT_DIR/fetch-musl-runtime.sh"
        cp "$TL_OUT/musl-libgcc" "$TL_ASSETS/musl-libgcc-$TL_ARCH"
        cp "$TL_OUT/musl-libstdcxx" "$TL_ASSETS/musl-libstdcxx-$TL_ARCH"
        ;;
    *)
        echo "build-asset: unknown tool $tool" >&2
        exit 2
        ;;
esac

echo
for f in "$TL_ASSETS"/*-"$TL_ARCH"; do
    [ -f "$f" ] || continue
    printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(basename "$f")"
done
