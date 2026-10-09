#!/usr/bin/env bash
# Cuts a tlstore release: builds dist/ from the sources (engine/tlstore, engine/trusted.pub,
# scripts/items.tsv, ui/) and, once dist/ is signed, records it in SHA256SUMS and prints the lock
# block the launcher pins a tag against.
#
#   scripts/release.sh <tag> --prepare   copy sources into dist/, build the catalog, check
#                                        dist/tlstore-ui-<abi> freshness, write the UI digests
#                                        into dist/tlstore (scripts/embed-ui-digests.sh) — no signing
#   scripts/release.sh <tag>             verify both signatures and the embedded UI digests,
#                                        write SHA256SUMS, print the lock
#
# Two passes because signing needs the developer's passphrase (scripts/sign.sh runs by hand,
# between them, and never inside this script): --prepare never touches a key, and the second pass
# only ever reads dist/ and engine/trusted.pub, never signs anything itself.
#
# Run scripts/build-ui.sh --install first if ui/ changed since the last release — --prepare
# refuses (through scripts/check-dist.sh) when dist/tlstore-ui-<abi> is stale or missing.
#
# Never tags or pushes: that is the orchestrator's call once the lock block below is in hand.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
dist="$repo/dist"

tag="${1:-}"
mode="${2:-}"
[ -n "$tag" ] || { echo "usage: scripts/release.sh <tag> [--prepare]" >&2; exit 2; }
case "$mode" in
    ""|--prepare) ;;
    *) echo "usage: scripts/release.sh <tag> [--prepare]" >&2; exit 2 ;;
esac

FILES="tlstore tlstore.minisig catalog.tsv catalog.tsv.minisig trusted.pub tlstore-ui-arm64-v8a tlstore-ui-x86_64"

if [ "$mode" = "--prepare" ]; then
    mkdir -p "$dist"
    cp "$repo/engine/tlstore" "$dist/tlstore"
    cp "$repo/engine/trusted.pub" "$dist/trusted.pub"
    echo "copied engine/tlstore -> dist/tlstore, engine/trusted.pub -> dist/trusted.pub"

    "$here/build-catalog.sh"
    "$here/check-dist.sh"
    # The script names the tlstore-ui built beside it, so a phone's self-update takes the two
    # together; the signature made next covers those lines.
    "$here/embed-ui-digests.sh" "$dist"

    # Phones already on a release take a new script (and the UI it names) only when its
    # TLSTORE_VERSION is newer than theirs, so a script that changed under the same version
    # reaches them only with an APK update. dist/tlstore as committed is the last release's.
    prev="$(git -C "$repo" show HEAD:dist/tlstore 2>/dev/null || true)"
    if [ -n "$prev" ] && [ "$prev" != "$(cat "$dist/tlstore")" ]; then
        prev_version="$(printf '%s\n' "$prev" | sed -n 's/^TLSTORE_VERSION=//p' | head -1)"
        version="$(sed -n 's/^TLSTORE_VERSION=//p' "$dist/tlstore" | head -1)"
        if [ "$prev_version" = "$version" ]; then
            echo "dist/tlstore changed since the last release but TLSTORE_VERSION is still $version:" >&2
            echo "phones would never self-update to it. Raise TLSTORE_VERSION in engine/tlstore." >&2
            exit 1
        fi
    fi

    echo
    echo "dist/ is prepared for tag $tag."
    echo "Now sign it by hand:  bash scripts/sign.sh"
    echo "Then finish the release:  scripts/release.sh $tag"
    exit 0
fi

# --- second pass: verify, record, print the lock block ---------------------

command -v minisign >/dev/null 2>&1 || { echo "release.sh needs minisign installed" >&2; exit 1; }

for f in tlstore catalog.tsv trusted.pub tlstore-ui-arm64-v8a tlstore-ui-x86_64; do
    [ -f "$dist/$f" ] || { echo "missing dist/$f — run 'scripts/release.sh $tag --prepare' first" >&2; exit 1; }
done
for f in tlstore.minisig catalog.tsv.minisig; do
    [ -f "$dist/$f" ] || { echo "missing dist/$f — run 'bash scripts/sign.sh' first" >&2; exit 1; }
done

if ! minisign -Q -V -m "$dist/tlstore" -p "$repo/engine/trusted.pub" >/dev/null 2>&1; then
    echo "dist/tlstore does not check out against dist/tlstore.minisig — sign it again" >&2
    exit 1
fi
if ! minisign -Q -V -m "$dist/catalog.tsv" -p "$repo/engine/trusted.pub" >/dev/null 2>&1; then
    echo "dist/catalog.tsv does not check out against dist/catalog.tsv.minisig — sign it again" >&2
    exit 1
fi

"$here/check-dist.sh"
"$here/embed-ui-digests.sh" --check "$dist"

# --- SHA256SUMS: replace existing dist/ lines, keep every other line as it was ---
sums="$repo/SHA256SUMS"
tmp="$(mktemp)"
if [ -f "$sums" ]; then
    grep -v '  dist/' "$sums" > "$tmp" || true
else
    : > "$tmp"
fi
for f in $FILES; do
    printf '%s  dist/%s\n' "$(sha256sum "$dist/$f" | cut -d' ' -f1)" "$f" >> "$tmp"
done
mv "$tmp" "$sums"
echo "updated $sums"

echo
echo "tag $tag"
for f in $FILES; do
    printf '%s  %s\n' "$(sha256sum "$dist/$f" | cut -d' ' -f1)" "$f"
done
