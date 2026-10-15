#!/bin/bash
# fetch-launcher-skills.sh — Termux Launcher's agent skills, packed the way the launcher packs them:
# one .tar.gz per skill, each holding the skill's directory as its only top-level entry, for
# tlstore's skill items (docs/SPEC.md, Revision 18).
#
# Nothing is built. PickleHik3/termux-launcher is fetched at one pinned commit and its own
# scripts/pack-agent-skills.sh writes the tarballs: termux-launcher.tar.gz (the skill, with the
# user guide as docs/, which its help.md points into) and termux-launcher-speak.tar.gz. The pack
# is byte-for-byte reproducible from the commit (sorted names, one mtime, root ownership, no name
# or time in the gzip header), so the commit is the pin. The skills are text and shell scripts:
# one pack serves every processor and every launcher edition.
#
# A new pin: a commit on the launcher's origin, its full hash written here, and the catalog's
# version for both rows (scripts/items.tsv) moved to its first eight characters.
set -euo pipefail

LAUNCHER_COMMIT=${LAUNCHER_COMMIT:-09cd37739aeb55852b4bd7241dc48ab2b0dde051}
LAUNCHER_REPO=${LAUNCHER_REPO:-https://github.com/PickleHik3/termux-launcher.git}

TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-launcher-skills"}

mkdir -p "$TL_OUT" "$TL_BUILD_DIR"
src="$TL_BUILD_DIR/termux-launcher"
if [ ! -d "$src/.git" ]; then
    rm -rf "$src"
    git init -q "$src"
    git -C "$src" remote add origin "$LAUNCHER_REPO"
fi
if [ "$(git -C "$src" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$LAUNCHER_COMMIT" ]; then
    git -C "$src" fetch -q --depth 1 origin "$LAUNCHER_COMMIT"
    git -C "$src" checkout -q --detach FETCH_HEAD
fi
[ "$(git -C "$src" rev-parse HEAD)" = "$LAUNCHER_COMMIT" ] || {
    echo "error: the launcher checkout is not at $LAUNCHER_COMMIT" >&2
    exit 1
}

rm -f "$TL_OUT/termux-launcher.tar.gz" "$TL_OUT/termux-launcher-speak.tar.gz"
bash "$src/scripts/pack-agent-skills.sh" "$TL_OUT"

for name in termux-launcher termux-launcher-speak; do
    # What tlstore checks on the phone: one top-level entry, the folder named like the item.
    top="$(tar -tzf "$TL_OUT/$name.tar.gz" | cut -d/ -f1 | sort -u)"
    [ "$top" = "$name" ] || {
        echo "error: $name.tar.gz holds $(printf '%s' "$top" | tr '\n' ' ')instead of one $name folder" >&2
        exit 1
    }
done

echo
echo "Fetched: the agent skills at termux-launcher $LAUNCHER_COMMIT"
ls -l "$TL_OUT/termux-launcher.tar.gz" "$TL_OUT/termux-launcher-speak.tar.gz"
