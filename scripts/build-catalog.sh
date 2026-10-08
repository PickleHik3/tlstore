#!/usr/bin/env bash
# Builds dist/catalog.tsv from scripts/items.tsv.
#
#   scripts/build-catalog.sh [path/to/SHA256SUMS]
#
# Digests are never hand-written: a launcher: source is hashed from the file
# at `launcher:<path>@<ref>` in PickleHik3/termux-launcher (a local checkout
# named by TLSTORE_LAUNCHER_REPO, else GitHub) (see engine/tlstore's `launcher:` handling — this
# script only ever hashes a binaries:/launcher: source out of a SHA256SUMS or
# the file itself), a binaries: source is looked up in the SHA256SUMS passed as
# the first argument (this repository's own SHA256SUMS by default), and a
# plain http(s) source is downloaded once and hashed here (so building needs
# the network when one of those changes). pkg, bundle, fisher, npm-musl and
# npm-android items carry no digest — apt, fisher and the npm registry's own
# sha512 are the check there. A source whose digest cannot be computed stops the build: an
# unpinned payload must never reach a phone. An item's picture, pinned readme
# and demo are each hashed the same way (always a launcher:/binaries: source,
# or "-" when there is none) and their digests ride alongside them as their own
# columns, the way the item's own source and digest columns already do.
#
# A binaries: source with a slash in its asset (e.g. binaries:readme/dawn.md@tag)
# names a path in this repository directly, looked up in SHA256SUMS by that
# exact repo-relative path; a bare asset (e.g. binaries:dawn@tag) is looked up
# as "<asset>-aarch64", the release asset .github/workflows/build.yml publishes
# under that tag (scripts/bins-record.sh writes its SHA256SUMS line).
#
# x86_64 (docs/SPEC.md, Revision 12): a binary row's own columns are its aarch64
# build. When SHA256SUMS also has "<asset>-x86_64" for its bare binaries: source
# (or the row names an x86_64:source= of its own), the row gets
# `x86_64:digest=<sha256>` appended to its options, and tlstore shows it on
# x86_64. Without that line it gets nothing and stays hidden there, so the
# catalog is right both before and after the x86_64 build is published. Like
# every digest, x86_64:digest is never hand-written in items.tsv.
#
# A plain URL must name an immutable revision — a tag or a commit — for the same
# reason a launcher: source does.
#
# The serial is YYYYMMDDNN and only ever moves forward; a second build on the
# same day gets NN + 1, because tlstore accepts a refreshed catalog only when
# its serial is higher than the one it already has.
#
# After building, sign it: scripts/sign.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
items="$here/items.tsv"
out="$repo/dist/catalog.tsv"
sums="${1:-$repo/SHA256SUMS}"

[ -f "$items" ] || { echo "missing $items" >&2; exit 1; }

# --- serial ---------------------------------------------------------------
today="$(date +%Y%m%d)"
seq=1
if [ -f "$out" ]; then
    old="$(sed -n 's/^#.*serial=\([0-9][0-9]*\).*$/\1/p' "$out" | head -1)"
    if [ -n "$old" ] && [ "${old:0:8}" = "$today" ]; then
        seq=$((10#${old:8:2} + 1))
    fi
fi
serial="$(printf '%s%02d' "$today" "$seq")"

# --- digests --------------------------------------------------------------
declare -A binary_digest=()
if [ -n "$sums" ]; then
    [ -f "$sums" ] || { echo "no SHA256SUMS at $sums" >&2; exit 1; }
    while read -r digest name; do
        [ -n "${name:-}" ] || continue
        binary_digest["$name"]="$digest"
    done < "$sums"
fi

fetched="$(mktemp -d)"
trap 'rm -rf "$fetched"' EXIT

# source_digest <source> <name> [arch] — the digest of any launcher:/binaries:/http(s)
# source, whatever column it lives in. "-" (no source) passes straight through. A
# bare binaries: asset is the build for [arch], aarch64 unless told otherwise.
source_digest() {
    local source="$1" name="$2" arch="${3:-aarch64}" path tag asset key
    case "$source" in
        -) echo "-"; return 0 ;;
        launcher:*)
            # A file in PickleHik3/termux-launcher, hashed at the ref the phone will fetch:
            # from a local launcher checkout when TLSTORE_LAUNCHER_REPO names one and it has
            # the ref, else from GitHub.
            path="${source#launcher:}"
            local ref="${path##*@}"
            path="${path%@*}"
            if [ -n "${TLSTORE_LAUNCHER_REPO:-}" ] \
                && git -C "$TLSTORE_LAUNCHER_REPO" cat-file -e "$ref:$path" 2>/dev/null; then
                git -C "$TLSTORE_LAUNCHER_REPO" show "$ref:$path" | sha256sum | cut -d' ' -f1
            else
                local out="$fetched/$name.launcher"
                if ! curl -fsSL -o "$out" "https://raw.githubusercontent.com/PickleHik3/termux-launcher/$ref/$path"; then
                    rm -f "$out"
                    echo "$name: could not fetch launcher:$path@$ref (set TLSTORE_LAUNCHER_REPO to a launcher checkout to work offline)" >&2
                    return 1
                fi
                sha256sum "$out" | cut -d' ' -f1
            fi
            ;;
        binaries:*)
            tag="${source#binaries:}"
            asset="${tag%@*}"
            if [ -z "$sums" ]; then
                echo "$name needs a SHA256SUMS argument for $asset" >&2
                return 1
            fi
            case "$asset" in
                */*) key="$asset" ;;
                *) key="$asset-$arch" ;;
            esac
            if [ -z "${binary_digest["$key"]:-}" ]; then
                echo "$key is not in $sums (for $name)" >&2
                return 1
            fi
            echo "${binary_digest["$key"]}"
            ;;
        http://*|https://*)
            path="$fetched/$name.payload"
            if [ ! -f "$path" ]; then
                if ! curl -fsSL -o "$path" "$source"; then
                    rm -f "$path"
                    echo "$name: could not download $source" >&2
                    return 1
                fi
            fi
            sha256sum "$path" | cut -d' ' -f1
            ;;
        *)
            echo "$name: cannot compute a digest for $source" >&2
            return 1
            ;;
    esac
}

digest_for() {
    local kind="$1" source="$2" name="$3"
    case "$kind" in
        pkg|bundle|fisher|npm-musl|npm-android) echo "-"; return 0 ;;
    esac
    source_digest "$source" "$name"
}

# optval <options> <key> — one ;-separated option's value, empty when unset.
optval() {
    local part parts
    IFS=';' read -ra parts <<<"$1"
    for part in "${parts[@]}"; do
        case "$part" in "$2="*) printf '%s' "${part#"$2="}"; return 0 ;; esac
    done
}

# x86_64_digest <kind> <source> <options> <name> — the digest of a binary's x86_64
# build, or nothing when there is none to offer. An x86_64:source= the row names
# itself must resolve (a failure stops the build, like any other pinned source);
# the row's own bare binaries: asset counts only once SHA256SUMS has its
# <asset>-x86_64 line, which bins-record.sh writes when that build is published.
x86_64_digest() {
    local kind="$1" source="$2" options="$3" name="$4" own asset
    [ "$kind" = binary ] || return 0
    own="$(optval "$options" x86_64:source)"
    if [ -n "$own" ]; then
        source_digest "$own" "$name (x86_64)" x86_64
        return
    fi
    case "$source" in
        binaries:*) asset="${source#binaries:}"; asset="${asset%@*}" ;;
        *) return 0 ;;
    esac
    case "$asset" in */*) return 0 ;; esac
    printf '%s' "${binary_digest["$asset-x86_64"]:-}"
}

# --- rows -----------------------------------------------------------------
tmp="$(mktemp)"
trap 'rm -f "$tmp"; rm -rf "$fetched"' EXIT

{
    printf '# tlstore catalog\tserial=%s\n' "$serial"
    printf '# generated by scripts/build-catalog.sh from scripts/items.tsv — do not edit\n'
    printf '# name\tkind\tversion\tprefixes\tsource\tdigest\ttarget\trequires\toptions\tsummary\t'
    printf 'category\tupstream\tsetup\tstandfirst\tdoes1\tdoes2\tdoes3\ttry\tnotes\t'
    printf 'author\tlicence\tsize\tpicture\tpicture-digest\tdemo\tfeatured\treadme-skip\t'
    printf 'readme\treadme-digest\tdemo-digest\n'
} > "$tmp"

failed=0
count=0
featured_names=""
while IFS=$'\t' read -r name kind version prefixes source target requires options summary \
    category upstream setup standfirst does1 does2 does3 try notes \
    author licence size picture demo featured readme_skip readme || [ -n "${name:-}" ]; do
    [ -n "${name:-}" ] || continue
    case "$name" in \#*) continue ;; esac
    if [ -z "${readme:-}" ]; then
        echo "$name: expected 26 tab-separated columns" >&2
        failed=1
        continue
    fi
    case "$name" in
        [a-z0-9]*) ;;
        *) echo "$name: a name is [a-z0-9][a-z0-9-]*" >&2; failed=1; continue ;;
    esac
    case "$kind" in
        pkg|binary|file|file-once|fisher|npm-musl|npm-android|bundle) ;;
        *) echo "$name: unknown kind $kind" >&2; failed=1; continue ;;
    esac
    # priv=shizuku means "a binary the launcher runs as the Shizuku shell user";
    # the engine only honours it on a binary, so anything else is a mistake here.
    case ";$options;" in
        *";priv=shizuku;"*)
            if [ "$kind" != binary ]; then
                echo "$name: priv=shizuku is only for a binary, not a $kind" >&2
                failed=1
                continue
            fi
            ;;
        *";priv="*) echo "$name: priv= must be shizuku" >&2; failed=1; continue ;;
    esac
    # A retired row must also be hidden=1: old engines already on phones
    # (which do not know retired= at all) must never offer it, only ever see
    # it as a part they leave alone.
    case ";$options;" in
        *";retired=1;"*)
            case ";$options;" in
                *";hidden=1;"*) ;;
                *) echo "$name: retired=1 needs hidden=1 too" >&2; failed=1; continue ;;
            esac
            ;;
    esac
    case "$category" in
        -|"Note taking"|Tools|AI) ;;
        *) echo "$name: unknown category $category" >&2; failed=1; continue ;;
    esac
    case "$setup" in
        0|1) ;;
        *) echo "$name: setup must be 0 or 1, not $setup" >&2; failed=1; continue ;;
    esac
    case "$featured" in
        0|1) ;;
        *) echo "$name: featured must be 0 or 1, not $featured" >&2; failed=1; continue ;;
    esac
    if [ "$featured" = 1 ]; then
        case " $featured_names " in
            *" $name "*) ;;
            *) featured_names="$featured_names $name" ;;
        esac
    fi
    if ! digest="$(digest_for "$kind" "$source" "$name")"; then
        failed=1
        continue
    fi
    if ! picture_digest="$(source_digest "$picture" "$name (picture)")"; then
        failed=1
        continue
    fi
    if ! readme_digest="$(source_digest "$readme" "$name (readme)")"; then
        failed=1
        continue
    fi
    if ! demo_digest="$(source_digest "$demo" "$name (demo)")"; then
        failed=1
        continue
    fi
    case ";$options;" in
        *";x86_64:digest="*)
            echo "$name: x86_64:digest is written by build-catalog.sh, never by hand" >&2
            failed=1
            continue
            ;;
    esac
    if ! x86_digest="$(x86_64_digest "$kind" "$source" "$options" "$name")"; then
        failed=1
        continue
    fi
    if [ -n "$x86_digest" ]; then
        if [ "$options" = "-" ]; then
            options="x86_64:digest=$x86_digest"
        else
            options="$options;x86_64:digest=$x86_digest"
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t' \
        "$name" "$kind" "$version" "$prefixes" "$source" "$digest" \
        "$target" "$requires" "$options" "$summary" >> "$tmp"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t' \
        "$category" "$upstream" "$setup" "$standfirst" "$does1" "$does2" "$does3" "$try" "$notes" >> "$tmp"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t' \
        "$author" "$licence" "$size" "$picture" "$picture_digest" "$demo" "$featured" "$readme_skip" >> "$tmp"
    printf '%s\t%s\t%s\n' "$readme" "$readme_digest" "$demo_digest" >> "$tmp"
    count=$((count + 1))
done < "$items"

if [ "$failed" = 0 ] && [ "$(printf '%s' "$featured_names" | wc -w)" != 1 ]; then
    echo "exactly one item must be featured=1, found:$featured_names" >&2
    failed=1
fi

if [ "$failed" != 0 ]; then
    echo "refusing to write $out" >&2
    exit 1
fi

mkdir -p "$(dirname "$out")"
cp "$tmp" "$out"
chmod 644 "$out"
echo "wrote $out — $count items, serial=$serial"
echo "sign it with scripts/sign.sh before it ships"
