#!/bin/bash
# zig-prefetch.sh — put every package a Zig build will fetch into Zig's global cache first, with
# curl, so the build itself downloads nothing. Zig 0.16's own HTTP client is fragile (504s,
# HttpConnectionClosing) and has no timeout: a stalled fetch hangs a CI job for hours.
#
# usage: ZIG=<zig> ZIG_GLOBAL_CACHE_DIR=<dir> zig-prefetch.sh <source-dir>
#
# Reads every `.url = "..."` of the build.zig.zon files under <source-dir>: the top-level one,
# pkg/*/ and zig-pkg/*/. Each http(s) url is downloaded with retries and a hard time limit, then
# seeded with `zig fetch` (the cache keeps it as p/<hash>.tar.*); the hash zig computes must equal
# the one the .zon expects. The top-level build.zig.zon inside each package just seeded is read in
# turn, until no new url appears, so dependencies of dependencies are covered. Urls already seeded
# are skipped (listed in <cache>/tl-prefetched-urls; their .zon files in <cache>/tl-zons).
# Any failure is fatal. Run it after the source (and any patches to it) is in place.
set -euo pipefail

src=${1:?usage: zig-prefetch.sh <source-dir>}
: "${ZIG:?set ZIG to the zig binary}"
: "${ZIG_GLOBAL_CACHE_DIR:?set ZIG_GLOBAL_CACHE_DIR}"
cache=$ZIG_GLOBAL_CACHE_DIR
mkdir -p "$cache"
done_list="$cache/tl-prefetched-urls"
touch "$done_list"
zon_dir="$cache/tl-zons"
mkdir -p "$zon_dir"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# `zig fetch` insists on finding a build.zig in or above its working directory.
mkdir -p "$work/stub"
echo 'pub fn build(b: *@import("std").Build) void { _ = b; }' > "$work/stub/build.zig"

# "<url> <expected hash>" for every dependency of the .zon files on stdin's argument list.
zon_pairs() {
    awk '
        /\.url *= *"/ { u = $0; sub(/.*\.url *= *"/, "", u); sub(/".*/, "", u); next }
        /\.hash *= *"/ { h = $0; sub(/.*\.hash *= *"/, "", h); sub(/".*/, "", h);
                         if (u != "") print u, h; u = "" }
    ' "$@"
}

fetched=0
while :; do
    zons=()
    for f in "$src/build.zig.zon" "$src"/pkg/*/build.zig.zon "$src"/zig-pkg/*/build.zig.zon \
             "$zon_dir"/*.zon; do
        [ -f "$f" ] && zons+=("$f")
    done
    [ ${#zons[@]} -gt 0 ] || break
    pending="$work/pending"
    zon_pairs "${zons[@]}" | sort -u | while read -r url want; do
        grep -qxF "$url" "$done_list" || echo "$url $want"
    done > "$pending"
    [ -s "$pending" ] || break
    while read -r url want; do
        case "$url" in
            http://*|https://*) ;;
            *) echo "zig-prefetch: skipping $url (not an http(s) tarball)" >&2
               echo "$url" >> "$done_list"; continue ;;
        esac
        file="$work/$(printf '%s' "$url" | cksum | cut -d' ' -f1)-${url##*/}"
        echo "zig-prefetch: $url"
        curl --fail --silent --show-error --location --retry 5 --retry-all-errors \
            --connect-timeout 20 --max-time 300 -o "$file" "$url" || {
            echo "error: zig-prefetch: download failed after retries: $url" >&2
            exit 1
        }
        got=$(cd "$work/stub" && "$ZIG" fetch --global-cache-dir "$cache" "$file")
        echo "zig-prefetch:   expected $want"
        echo "zig-prefetch:   zig fetch $got"
        [ "$got" = "$want" ] || {
            echo "error: zig-prefetch: hash mismatch for $url" >&2
            exit 1
        }
        # Keep the package's own top-level build.zig.zon: its dependencies are next.
        inner=$(tar -tf "$file" 2>/dev/null | awk -F/ '$NF == "build.zig.zon" && NF <= 3 { print NF, $0 }' \
            | sort -n | head -1 | cut -d' ' -f2-)
        if [ -n "$inner" ]; then
            tar -xOf "$file" "$inner" > "$zon_dir/$(basename "$file").zon"
        fi
        rm -f "$file"
        echo "$url" >> "$done_list"
        fetched=$((fetched + 1))
    done < "$pending"
done
echo "zig-prefetch: $fetched package(s) fetched, the rest already in $cache"
