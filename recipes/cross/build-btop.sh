#!/bin/bash
# build-btop.sh — cross-compile btop for Android (aarch64, or x86_64 with TL_ARCH=x86_64) from a
# Linux host, fully static.
#
# btop is a privileged item: Termux:Launcher stages the binary under /data/local/tmp/tl and starts
# it as the Shizuku shell uid (2000), outside any Termux prefix, with PATH=/system/bin and nothing
# else on hand. So the binary carries everything it needs — linked -static against the NDK's Bionic
# libc.a and libc++_static, no interpreter, no NEEDED entries, and no prefix baked in anywhere. One
# build serves every edition.
#
# Static NDK rather than a musl cross build: btop wants only libc, libc++ and pthreads, which the
# NDK ships as static archives, and a Bionic binary reads Android's /proc, /sys and getpwuid() the
# way the system's own tools do. termux-packages has no btop package (checked 2026-09-25), so there
# are no Android patches to inherit; the patches applied here are this repository's own:
#   0001  read network counters from /proc/net/dev when /sys/class/net/*/statistics is refused
#   0002  drop kill, terminate, the signal menu and renice — the shell uid cannot signal other uids
#   0003  hide /apex/* loop mounts from the disks box and show /data right after /
#   0004  Bionic has no pthread_cancel or pthread_timedjoin_np; join with a timeout, never cancel
#   0005  probe paths with the non-throwing fs::exists, so a /sys file the shell uid may not stat
#         reads as absent instead of ending btop; skip use_fstab when there is no /etc/fstab
#   0006  stack the boxes at full width when the terminal is too narrow for mem/net beside proc (a
#         phone is 63x28), let the cpu box go down to 44 columns, and default to "cpu mem proc" on
#         Android with "p" stepping past presets that do not fit
#
# Requires: the Android NDK, GNU make, patch and git.
set -euo pipefail

BTOP_URL="https://github.com/aristocratos/btop.git"
BTOP_COMMIT="6e39144aaf5a6bc01b9f795010b0914431067183"   # v1.4.7
BTOP_VERSION="1.4.7"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCHES=(
    "$SCRIPT_DIR/0001-btop-proc-net-dev-fallback.patch"
    "$SCRIPT_DIR/0002-btop-no-process-signals.patch"
    "$SCRIPT_DIR/0003-btop-android-mounts.patch"
    "$SCRIPT_DIR/0004-btop-bionic-threads.patch"
    "$SCRIPT_DIR/0005-btop-no-throw-fs-probes.patch"
    "$SCRIPT_DIR/0006-btop-narrow-layout.patch"
)

TL_NDK=${TL_NDK:-"$HOME/Android/Sdk/ndk/29.0.14206865"}
TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-btop"}
# 29, not the launcher's minSdk 26: Bionic's headers only declare getloadavg() from API 29, which
# btop calls. The link is static, so the function is the binary's own copy (it reads /proc/loadavg)
# and the result still runs on every Android the launcher supports.
TL_ANDROID_API=${TL_ANDROID_API:-29}

NDK_BIN="$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
TL_ARCH=${TL_ARCH:-aarch64}
TL_TRIPLE=${TL_TRIPLE:-$TL_ARCH-linux-android}
CXX="$NDK_BIN/$TL_TRIPLE$TL_ANDROID_API-clang++"
[ -x "$CXX" ] || { echo "error: NDK compiler not found at $CXX (set TL_NDK)" >&2; exit 1; }
for patch in "${PATCHES[@]}"; do
    [ -f "$patch" ] || { echo "error: patch not found at $patch" >&2; exit 1; }
done

mkdir -p "$TL_OUT" "$TL_BUILD_DIR"
source_dir="$TL_BUILD_DIR/source"

if [ ! -d "$source_dir/.git" ]; then
    echo "Fetching btop v$BTOP_VERSION ($BTOP_COMMIT)..."
    git init -q "$source_dir"
    git -C "$source_dir" remote add origin "$BTOP_URL"
    git -C "$source_dir" fetch -q --depth 1 origin "$BTOP_COMMIT"
    git -C "$source_dir" checkout -q --detach FETCH_HEAD
    for patch in "${PATCHES[@]}"; do
        echo "Applying $(basename "$patch")..."
        patch -p1 -s -d "$source_dir" < "$patch"
    done
fi

# btop's own Makefile does the right thing once it is told what it is building for: PLATFORM=Linux
# picks the Linux collector, ARCH is the processor, and STATIC=true adds -static and -DSTATIC_BUILD.
# GPU support, which upstream enables only for a dynamic linux x86_64 build (it loads the desktop
# GPU vendors' libraries at run time, which a static binary cannot and a phone does not have), is
# off on both processors; GPU_SUPPORT=false says so rather than leaning on STATIC=true for it.
# The Makefile compile-tests each
# hardening flag before using it, so -fcf-protection (x86 only) is used on x86_64 and drops out on
# aarch64 on its own. CXX is the NDK's clang++ wrapper for
# the API level, which is what makes -static pick Bionic's libc.a and libc++_static.
echo "Building..."
make -C "$source_dir" QUIET=true STATIC=true PLATFORM=Linux ARCH="$TL_ARCH" GPU_SUPPORT=false \
    CXX="$CXX" -j"${TL_BUILD_JOBS:-$(nproc)}"

"$NDK_BIN/llvm-strip" -o "$TL_OUT/btop" "$source_dir/bin/btop"

readelf="$NDK_BIN/llvm-readelf"
# The lane copies one file and runs it with PATH=/system/bin: a dynamic binary would die in the
# linker before main. No PT_INTERP and no NEEDED is what "fully static" means here.
if "$readelf" -l "$TL_OUT/btop" | grep -q INTERP || "$readelf" -d "$TL_OUT/btop" | grep -q NEEDED; then
    echo "error: btop is not static — it would not start under the privileged lane" >&2
    exit 1
fi

# Each patch leaves a mark in the binary exactly when it took: the procfs path the network fallback
# reads, the mount prefix the Android disk filter skips, and the help line for a key that must no
# longer exist.
if ! grep -qa 'net/dev' "$TL_OUT/btop"; then
    echo "error: the /proc/net/dev fallback is missing from the build — network graphs would stay at zero" >&2
    exit 1
fi
if grep -qa 'Kill selected process' "$TL_OUT/btop"; then
    echo "error: the kill and terminate keys are still in the build — they cannot work as the shell uid" >&2
    exit 1
fi
if ! grep -qa '/apex/' "$TL_OUT/btop"; then
    echo "error: the Android mount filter is missing from the build — the disks box would fill with apex images" >&2
    exit 1
fi

echo
echo "Built: $TL_OUT/btop (v$BTOP_VERSION, static, edition-agnostic)"
"$readelf" -d "$TL_OUT/btop" | grep -E "NEEDED|RUNPATH" || echo "no NEEDED, no RUNPATH"
