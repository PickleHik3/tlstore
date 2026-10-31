#!/bin/bash
# build-tuios.sh — cross-compile tuios, a terminal window manager, for Android (arm64, or amd64
# with TL_GOARCH=amd64) from a Linux host.
#
# tuios is pure Go (the plain build, not the tuios-ghostty one, which links libghostty-vt through
# cgo), and its releases are linux/darwin/windows/BSD only. The target here is android/<arch> for
# the reason build-kitten.sh spells out: Go's os/exec.LookPath uses faccessat2 on GOOS=linux, which
# Android's seccomp filter kills, and Android's x86_64 filter kills the legacy syscalls (poll, pipe,
# dup2, epoll_wait, access) a linux/amd64 Go runtime still issues. android/arm64 links without
# cgo; android/amd64 needs the NDK's clang as the external linker (TL_CGO_CC), exactly as kitten.
# Either way the result is a PIE bound to /system/bin/linker64.
#
# The ldflags are the ones .goreleaser.yml gives the `tuios` build (-s -w, main.version/commit/date),
# so `tuios --version` reports the release. main.builtBy is set to "tlstore", not goreleaser's
# "goreleaser": `tuios update` replaces a binary only when it says "goreleaser", and what it would
# download is upstream's linux build, which dies on Android. With "tlstore" it refuses instead.
# GOWORK=off as in goreleaser: build the libraries at the versions go.mod pins.
#
# Requires: Go (go.mod's `go`/`toolchain` lines; GOTOOLCHAIN=auto fetches a newer one when the
# host's is older), git, and network access.
set -euo pipefail

TUIOS_URL="https://github.com/Gaurav-Gosain/tuios.git"
# scripts/upstream-watch.sh moves the pin below to upstream's latest release; keep its shape.
TUIOS_TAG=${TUIOS_TAG:-v0.12.0}

TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-tuios"}
TL_GOOS=${TL_GOOS:-android}
TL_GOARCH=${TL_GOARCH:-arm64}
# See build-kitten.sh: only the amd64 build names the NDK's clang, which then only links.
TL_CGO_CC=${TL_CGO_CC:-}
if [ -n "$TL_CGO_CC" ]; then cgo=1; else cgo=0; fi
export GOTOOLCHAIN=${GOTOOLCHAIN:-auto}

for tool in go git; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: missing required tool: $tool" >&2; exit 1; }
done

mkdir -p "$TL_OUT" "$TL_BUILD_DIR"
source_dir="$TL_BUILD_DIR/source"

if [ ! -d "$source_dir/.git" ]; then
    echo "Cloning tuios $TUIOS_TAG..."
    git clone --depth 1 --branch "$TUIOS_TAG" "$TUIOS_URL" "$source_dir"
fi

# The CPU meter reads /proc/stat, which Android closes to an app uid. The patch adds an Android-only
# fallback that reads the samples of tuios-cpu (build-tuios-cpu.sh), which the launcher's
# privileged lane runs as the shell uid; without that helper the meter shows n/a. It touches no
# other platform. Skipped when a reused source tree already has it.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if ! git -C "$source_dir" apply --reverse --check "$SCRIPT_DIR/0001-tuios-android-cpu.patch" 2>/dev/null; then
    git -C "$source_dir" apply "$SCRIPT_DIR/0001-tuios-android-cpu.patch"
fi

revision=$(git -C "$source_dir" rev-parse HEAD)
date=$(git -C "$source_dir" show -s --format=%cI HEAD)
output="$TL_OUT/tuios-$TL_GOOS-$TL_GOARCH"

echo "Building tuios for $TL_GOOS/$TL_GOARCH..."
(
    cd "$source_dir"
    GOWORK=off CGO_ENABLED=$cgo CC="${TL_CGO_CC:-cc}" GOOS="$TL_GOOS" GOARCH="$TL_GOARCH" go build -trimpath \
        -ldflags "-s -w -X main.version=${TUIOS_TAG#v} -X main.commit=$revision -X main.date=$date -X main.builtBy=tlstore" \
        -o "$output" ./cmd/tuios
)

echo
echo "Built: $output"
file "$output"
