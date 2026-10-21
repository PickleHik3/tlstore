#!/bin/bash
# fetch-herdr.sh — herdr for TL_ARCH (aarch64 by default, or x86_64): its own Linux build from its
# GitHub release, as one .tar.gz app tree with a launcher script in front of it.
#
# herdr is not built here. Upstream publishes one static musl binary per processor
# (herdr-linux-aarch64 is a static executable, herdr-linux-x86_64 a static PIE): no interpreter, no
# NEEDED entries, no prefix baked in, so it runs on Android as it is and one copy serves every
# launcher edition. Device-verified on Pong (A065, Android 16), 2026-10-09: the v0.9.3 aarch64
# asset, byte for byte, runs in the launcher's terminal. It is mirrored as a bins-… asset rather
# than read from upstream so it is pinned by digest beside the others and reaches x86_64 too.
#
# The asset is an archive item (docs/SPEC.md, Revision 14), not the bare binary:
#
#   libexec/herdr   upstream's binary, byte for byte, checked against the digest below
#   bin/herdr       what the catalog's exe= runs: inside Termux Launcher it tells herdr it is in
#                   kitty (KITTY_WINDOW_ID), so herdr's [ui.toast] delivery = "terminal" writes
#                   kitty's OSC 99, which the launcher shows as an Android notification; herdr
#                   writes nothing for a terminal it does not know. Anywhere else it changes nothing
#
# The archive's top level is the app root (bin/, libexec/; no leading directory), with sorted
# names, one fixed mtime, numeric owner 0 and gzip -n, so the same pin gives the same bytes.
set -euo pipefail

# scripts/upstream-watch.sh moves the pins below to upstream's latest release; keep their shape.
HERDR_VERSION=${HERDR_VERSION:-v0.9.5}
TL_ARCH=${TL_ARCH:-aarch64}
# Each processor's asset, pinned by digest. A new version is downloaded once from
# https://github.com/herdrdev/herdr/releases/download/<version>/herdr-linux-<arch> and its sha256
# written here.
case "$TL_ARCH" in
    aarch64) HERDR_SHA256=17d7536f2da50859523680ef279dffcac8e4a235f4e46fe8da6c2ec44141897c ;;
    x86_64)  HERDR_SHA256=14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d ;;
    *) echo "error: no pinned herdr build for $TL_ARCH" >&2; exit 2 ;;
esac
# Every entry's mtime in the archive (2026-10-21, when the launcher script was added). A fixed
# date, not the time of the run, so a rebuild of the same pin is the same asset.
HERDR_MTIME=1792540800

TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-herdr"}

mkdir -p "$TL_OUT" "$TL_BUILD_DIR"
file="$TL_BUILD_DIR/herdr-linux-$TL_ARCH-$HERDR_VERSION"
[ -f "$file" ] || curl -fsSL -o "$file" \
    "https://github.com/herdrdev/herdr/releases/download/$HERDR_VERSION/herdr-linux-$TL_ARCH"
echo "$HERDR_SHA256  $file" | sha256sum -c - >/dev/null

# --- the app tree -------------------------------------------------------------------------------
stage="$TL_BUILD_DIR/stage-$TL_ARCH"
rm -rf "$stage"
mkdir -p "$stage/bin" "$stage/libexec"
# The basename stays herdr, the name upstream's binary has always run under here.
install -m 755 "$file" "$stage/libexec/herdr"

cat > "$stage/bin/herdr" <<'EOF'
#!/bin/sh
# herdr as tlstore ships it: upstream's own binary, in ../libexec.
SELF="$0"
while [ -L "$SELF" ]; do
  LINK="$(readlink "$SELF")"
  case "$LINK" in
    /*) SELF="$LINK" ;;
    *) SELF="$(dirname -- "$SELF")/$LINK" ;;
  esac
done
ROOT="$(CDPATH= cd -- "$(dirname -- "$SELF")/.." && pwd -P)"

# herdr's terminal notifications ([ui.toast] delivery = "terminal") are written only for the
# terminals on its allowlist (Ghostty, iTerm2, WezTerm, kitty); for any other it writes nothing.
# Termux Launcher shows kitty's OSC 99 in the Android shade, so in the launcher herdr is told it
# runs in a kitty window. herdr reads KITTY_WINDOW_ID for nothing else, and removes it from every
# pane it starts, so the programs in its panes never see it.
if [ "${TERM_PROGRAM:-}" = termux-launcher ] && [ -z "${KITTY_WINDOW_ID+set}" ]; then
  export KITTY_WINDOW_ID=1
fi

exec "$ROOT/libexec/herdr" "$@"
EOF
chmod 755 "$stage/bin/herdr"

# --- the archive --------------------------------------------------------------------------------
rm -f "$TL_OUT/herdr"
(
    cd "$stage"
    find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort \
        | tar --no-recursion -T - -cf - --format=gnu --mtime="@$HERDR_MTIME" \
            --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w'
) | gzip -9n > "$TL_OUT/herdr"

echo
echo "Fetched: $TL_OUT/herdr (herdr $HERDR_VERSION for $TL_ARCH, as an app tree)"
ls -l "$TL_OUT/herdr"
sha256sum "$TL_OUT/herdr"
