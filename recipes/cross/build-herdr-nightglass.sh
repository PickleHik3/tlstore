#!/bin/bash
# build-herdr-nightglass.sh — the Nightglass layouts for the Herdr desktop app, packed as an app
# tree for tlstore's herdr-nightglass item (an archive item: bin/herdr-nightglass on top).
#
# Nothing is compiled. PickleHik3/herdr-nightglass (MIT; its LICENSE is packed at the top) is fetched at one pinned commit (the commit
# hash is the pin) and its layouts/, mods/ and themes/ (tracked files only, without the editor
# typings and the mods' .state folders) are staged under share/nightglass beside the item's
# wrapper, recipes/cross/herdr-nightglass/herdr-nightglass. share/nightglass/BUILD is the
# first seven characters of the commit and a hash of everything staged, so the wrapper's sync
# copies again whenever the payload or the wrapper changes. The tarball is byte-for-byte
# reproducible from the commit (sorted names, the commit's own time, root ownership, no name or
# time in the gzip header). The files are text: one pack serves every processor and edition.
#
# A new pin: a commit on the repository's origin, its full hash written here, and the catalog's
# version for the item's rows (scripts/items.tsv) moved with it.
set -euo pipefail

NIGHTGLASS_COMMIT=${NIGHTGLASS_COMMIT:-ce590328803d16892db366521d5f8bac76c4e4ed}
NIGHTGLASS_REPO=${NIGHTGLASS_REPO:-https://github.com/PickleHik3/herdr-nightglass.git}

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-herdr-nightglass"}

mkdir -p "$TL_OUT" "$TL_BUILD_DIR"
src="$TL_BUILD_DIR/src"
if [ ! -d "$src/.git" ]; then
    rm -rf "$src"
    git init -q "$src"
    git -C "$src" remote add origin "$NIGHTGLASS_REPO"
fi
if [ "$(git -C "$src" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$NIGHTGLASS_COMMIT" ]; then
    git -C "$src" fetch -q --depth 1 origin "$NIGHTGLASS_COMMIT"
    git -C "$src" checkout -q --detach FETCH_HEAD
fi
[ "$(git -C "$src" rev-parse HEAD)" = "$NIGHTGLASS_COMMIT" ] || {
    echo "error: the Nightglass checkout is not at $NIGHTGLASS_COMMIT" >&2
    exit 1
}
APP_MTIME=$(git -C "$src" log -1 --format=%ct HEAD)

stage="$TL_BUILD_DIR/stage"
rm -rf "$stage"
mkdir -p "$stage/share/nightglass" "$stage/bin"
git -C "$src" archive HEAD layouts mods themes | tar -x -C "$stage/share/nightglass"
find "$stage/share/nightglass" \( -name gpui-kit.d.ts -o -name jsconfig.json \) -type f -delete
find "$stage/share/nightglass" -name .state -type d -prune -exec rm -rf {} +

for f in layouts/nightglass.json layouts/nightglass-phone.json mods/nightglass/mod.json \
    mods/nightglass-phone/mod.json mods/toast/mod.json; do
    [ -f "$stage/share/nightglass/$f" ] || {
        echo "error: $f is missing from the Nightglass checkout" >&2
        exit 1
    }
done

cp "$src/README.md" "$stage/README.md"
[ -f "$src/LICENSE" ] || {
    echo "error: the Nightglass checkout has no LICENSE" >&2
    exit 1
}
cp "$src/LICENSE" "$stage/LICENSE"
printf 'PickleHik3/herdr-nightglass at %s\n' "$NIGHTGLASS_COMMIT" > "$stage/SOURCE"
cp "$SCRIPT_DIR/herdr-nightglass/herdr-nightglass" "$stage/bin/herdr-nightglass"
chmod 755 "$stage/bin/herdr-nightglass"

# The build id, last: any change to the payload or the wrapper changes it.
digest="$(cd "$stage" && find share/nightglass/layouts share/nightglass/mods share/nightglass/themes bin -type f \
    | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-12)"
printf '%s-%s\n' "${NIGHTGLASS_COMMIT:0:7}" "$digest" > "$stage/share/nightglass/BUILD"

rm -f "$TL_OUT/herdr-nightglass"
(
    cd "$stage"
    find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort \
        | tar --no-recursion -T - -cf - --format=gnu --mtime="@$APP_MTIME" \
            --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w'
) | gzip -9n > "$TL_OUT/herdr-nightglass"

listing="$(tar -tzf "$TL_OUT/herdr-nightglass")"
printf '%s\n' "$listing" | grep -Eqx '(\./)?bin/herdr-nightglass' || {
    echo "error: the tarball has no bin/herdr-nightglass" >&2
    exit 1
}

count=$(find "$stage/share/nightglass/layouts" "$stage/share/nightglass/mods" "$stage/share/nightglass/themes" -type f | wc -l)
echo
echo "Built: $TL_OUT/herdr-nightglass (Nightglass layouts at $NIGHTGLASS_COMMIT, $count payload files, build $(cat "$stage/share/nightglass/BUILD"))"
ls -l "$TL_OUT/herdr-nightglass"
sha256sum "$TL_OUT/herdr-nightglass"
