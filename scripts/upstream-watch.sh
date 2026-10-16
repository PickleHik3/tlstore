#!/usr/bin/env bash
# Which of the catalog's upstream-pinned items are behind their upstream's latest stable release,
# and the bump that moves one of them. .github/workflows/upstream-watch.yml runs it once a day and
# carries a bump through build.yml and release.yml; it runs the same on a laptop.
#
#   scripts/upstream-watch.sh --check            ours against theirs, one line per item; no writes
#   scripts/upstream-watch.sh --check --tsv      the same, tab separated, for the workflow
#   scripts/upstream-watch.sh --bump <item> [<tag>]
#                                                pin <item> to <tag> (default: theirs) in its
#                                                recipe and its scripts/items.tsv rows
#   scripts/upstream-watch.sh --list             the items this watches, one per line
#
# Theirs is the tag of the upstream's latest release as GitHub's releases/latest names it: the
# newest release that is neither a draft nor a prerelease, so herdr's "Preview build" releases
# never count. A tag that does not read as a plain version (v1.2.3, 4.4.8) is reported as an error
# rather than followed. An item is behind when theirs sorts after ours (sort -V); an upstream that
# went backwards is reported, never followed.
#
# Ours is what the recipe pins, and every items.tsv row of the item must carry the same version
# (the tag without its leading v): a row that disagrees is reported as a mismatch for a hand to
# settle, and the watch leaves the item alone. --tsv adds what the last store release carries
# (dist/catalog.tsv, committed by release.yml) and whether a release is owed: the item's version
# on main is ahead of the release and, for a built item, its items.tsv source has moved to a new
# bins-… tag too (built and recorded, not yet released). A version that moved without a build is
# "unbuilt", never released on its own.
#
# A bump writes only the item's recipe lines and the version column (and, for a url item, the
# source) of its items.tsv rows. The binary itself, its bins-… tag and its SHA256SUMS lines are
# build.yml's to move (scripts/bins-record.sh), so a bump is what makes phones see the rebuild as
# an update (docs/maintainer/catalog.md, "Rebuilding a binary"). A bump that cannot verify what it
# pins — a tag that does not resolve, an asset whose digest GitHub does not publish or does not
# match the download, a url that does not answer — writes nothing and exits non-zero.
#
# Needs gh (authenticated, or GH_TOKEN set), git, curl and sha256sum.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
items="$here/items.tsv"
released_catalog="$repo/dist/catalog.tsv"

# One line per watched item. Adding an item is a line here, in one of the styles below, plus the
# item's row in items.tsv and (for a built one) its recipe in recipes/cross and scripts/bins-plan.sh.
#
#   item       its name in items.tsv
#   upstream   owner/repo on GitHub
#   style      how the recipe pins it:
#     commit     <VAR>_COMMIT="<sha>"   # v<version>   and   <VAR>_VERSION="<version>"
#                (the tag's commit is pinned, so a moved tag never changes a build silently)
#     tag        <VAR>=${<VAR>:-<tag>}
#     asset=<name>
#                upstream's own build, fetched: <VAR>_VERSION=${<VAR>_VERSION:-<tag>} and one
#                `<arch>) <VAR>_SHA256=<hex> ;;` line per processor; <name> is the release asset,
#                {arch} standing for aarch64 and x86_64. The digests come from the download and
#                must equal the ones GitHub publishes for the asset
#     url        nothing to build: the items.tsv source is a URL with the tag as one path segment
#   file       the recipe, from the repository root (- for url)
#   var        the variable prefix or name above (- for url)
#   tool       the build.yml tool that rebuilds it (- for none)
#
# Not here: dawn and terminal-browser, built from our own forks (an upstream release needs a hand
# merge first); npm items, which follow `latest`; pkg items; the launcher-pinned files and skills;
# the musl loader and runtime.
WATCH='
herdr      herdrdev/herdr           asset=herdr-linux-{arch}  recipes/cross/fetch-herdr.sh      HERDR      herdr
btop       aristocratos/btop        commit                    recipes/cross/build-btop.sh       BTOP       btop
fastfetch  fastfetch-cli/fastfetch  commit                    recipes/cross/build-fastfetch.sh  FASTFETCH  fastfetch
kitten     kovidgoyal/kitty         tag                       recipes/cross/build-kitten.sh     KITTY_TAG  kitten
sigye      am2rican5/sigye          commit                    recipes/cross/build-sigye.sh      SIGYE      sigye
fisher     jorgebucaran/fisher      url                       -                                 -          -
'

# The processors an asset-style item is pinned for (build.yml builds every tool for both).
ARCHS='aarch64 x86_64'

die() { echo "upstream-watch: $*" >&2; exit 1; }

usage() {
    sed -n '6,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

watched() { printf '%s\n' "$WATCH" | awk 'NF && $1 !~ /^#/ { print $1 }'; }

# Sets upstream, style, file, var, tool for an item.
load() {
    local line
    line="$(printf '%s\n' "$WATCH" | awk -v i="$1" '$1 == i')"
    [ -n "$line" ] || die "not a watched item: $1 (one of: $(watched | paste -sd' ' -))"
    read -r _ upstream style file var tool <<<"$line"
}

is_version() { [[ "$1" =~ ^v?[0-9]+(\.[0-9]+)*$ ]]; }

# Exit 0 when $2 is a later version than $1.
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]; }

# The tag of the upstream's latest release (never a draft or a prerelease).
latest_tag() {
    gh api "repos/$1/releases/latest" --jq .tag_name
}

# The version every items.tsv row of the item carries, or "mixed" when they differ.
row_version() {
    awk -F '\t' -v i="$1" '
        /^#/ || NF < 5 { next }
        $1 == i { if (v == "") v = $3; else if (v != $3) v = "mixed" }
        END { print (v == "" ? "-" : v) }' "$items"
}

# A column of the item's first items.tsv row, or of its first row in the released catalog.
row_field() {
    awk -F '\t' -v i="$2" -v c="$3" '!/^#/ && $1 == i { print $c; exit }' "$1"
}

# What the recipe (or, for a url item, items.tsv) pins: the version, without a leading v.
ours() {
    local v=""
    case "$style" in
        commit) v="$(sed -n "s/^${var}_VERSION=\"\\([^\"]*\\)\".*/\\1/p" "$repo/$file")" ;;
        tag)    v="$(sed -n "s/^${var}=\\\${${var}:-\\([^}]*\\)}.*/\\1/p" "$repo/$file")" ;;
        asset=*) v="$(sed -n "s/^${var}_VERSION=\\\${${var}_VERSION:-\\([^}]*\\)}.*/\\1/p" "$repo/$file")" ;;
        url)    v="$(row_version "$item")" ;;
        *) die "$item: unknown style $style" ;;
    esac
    [ "$(printf '%s\n' "$v" | grep -c .)" = 1 ] || die "$item: no single pin in ${file/#-/scripts\/items.tsv}"
    printf '%s\n' "${v#v}"
}

check() {
    local tsv="$1" item upstream style file var tool our row theirs tag status released owed
    if [ "$tsv" = 1 ]; then
        printf '# item\tours\ttheirs\ttag\tstatus\treleased\towed\ttool\n'
    fi
    for item in $(watched); do
        load "$item"
        our="$(ours)"
        row="$(row_version "$item")"
        tag="-"; theirs="-"
        if ! tag="$(latest_tag "$upstream" 2>/dev/null)" || [ -z "$tag" ]; then
            tag="-"; status=error
        elif ! is_version "$tag"; then
            status=error
        else
            theirs="${tag#v}"
            if [ "$row" != "$our" ]; then status=mismatch
            elif newer "$our" "$theirs"; then status=behind
            elif [ "$our" = "$theirs" ]; then status=current
            else status=ahead
            fi
        fi
        released="-"; owed=no
        if [ -f "$released_catalog" ]; then
            released="$(row_field "$released_catalog" "$item" 3)"
            released="${released:--}"
        fi
        if [ "$row" = "$our" ] && [ "$released" != - ] && newer "$released" "$our"; then
            owed=yes
            # A built item is owed only once build.yml recorded a new binary for it.
            if [ "$tool" != - ] && [ "$(row_field "$items" "$item" 5)" = "$(row_field "$released_catalog" "$item" 5)" ]; then
                owed=unbuilt
            fi
        fi
        if [ "$tsv" = 1 ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$item" "$our" "$theirs" "$tag" "$status" "$released" "$owed" "$tool"
        else
            local note=""
            [ "$status" != mismatch ] || note=" (items.tsv says $row)"
            [ "$status" != error ] || note=" (upstream latest: $tag)"
            [ "$owed" = no ] || note="$note, release owed: $owed (released $released)"
            printf '%-10s ours %-9s theirs %-9s %s%s\n' "$item" "$our" "$theirs" "$status" "$note"
        fi
    done
}

# Rewrites one line of a file through sed, insisting that exactly one line matched and changed.
rewrite() {
    local path="$1" match="$2" expr="$3" tmp
    [ "$(grep -c -- "$match" "$path")" = 1 ] || die "$item: expected one line matching $match in $path"
    tmp="$(mktemp)"
    sed -- "$expr" "$path" > "$tmp"
    if cmp -s "$path" "$tmp"; then rm -f "$tmp"; die "$item: $path did not change at $match"; fi
    cat "$tmp" > "$path"
    rm -f "$tmp"
}

bump() {
    local item="$1" tag="${2:-}" our ver commit url="" from arch asset digest want got dir tmp_items files
    load "$item"
    our="$(ours)"
    [ "$(row_version "$item")" = "$our" ] || die "$item: items.tsv says $(row_version "$item"), the recipe $our; settle that by hand first"
    if [ -z "$tag" ]; then
        tag="$(latest_tag "$upstream")" || die "$item: could not read the latest release of $upstream"
    fi
    is_version "$tag" || die "$item: upstream tag $tag does not read as a version"
    ver="${tag#v}"
    if [ "$ver" = "$our" ]; then
        echo "$item: already at $our"
        return 0
    fi
    newer "$our" "$ver" || die "$item: $tag is not later than ours ($our)"

    # Everything is resolved and verified before the first write.
    declare -A sums=()
    case "$style" in
        commit)
            commit="$(git ls-remote "https://github.com/$upstream.git" "refs/tags/$tag" "refs/tags/$tag^{}" |
                awk '$2 ~ /\^\{\}$/ { peeled = $1 } { plain = $1 } END { print (peeled != "" ? peeled : plain) }')"
            [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "$item: tag $tag not found in $upstream"
            ;;
        asset=*)
            dir="$(mktemp -d)"
            # shellcheck disable=SC2064
            trap "rm -rf '$dir'" EXIT
            for arch in $ARCHS; do
                asset="${style#asset=}"; asset="${asset//\{arch\}/$arch}"
                digest="$(gh api "repos/$upstream/releases/tags/$tag" \
                    --jq ".assets[] | select(.name == \"$asset\") | .digest // \"\"")" ||
                    die "$item: could not read release $tag of $upstream"
                want="${digest#sha256:}"
                [[ "$digest" == sha256:* && "$want" =~ ^[0-9a-f]{64}$ ]] ||
                    die "$item: GitHub publishes no sha256 for $asset in $tag, so the download cannot be verified"
                url="https://github.com/$upstream/releases/download/$tag/$asset"
                curl -fsSL --retry 3 -o "$dir/$asset" "$url" || die "$item: could not download $url"
                got="$(sha256sum "$dir/$asset" | cut -d' ' -f1)"
                [ "$got" = "$want" ] || die "$item: $asset downloads as $got, GitHub says $want"
                sums[$arch]="$got"
            done
            ;;
        tag) ;;
        url)
            url="$(row_field "$items" "$item" 5)"
            from="/$our/"
            case "$url" in
                */"$our"/*) ;;
                */v"$our"/*) from="/v$our/" ;;
                *) die "$item: its source $url has no /$our/ segment to move" ;;
            esac
            url="${url/"$from"/"/$tag/"}"
            curl -fsSL --retry 3 -o /dev/null "$url" || die "$item: $url does not answer"
            ;;
    esac

    case "$style" in
        commit)
            rewrite "$repo/$file" "^${var}_COMMIT=\"" \
                "s/^${var}_COMMIT=\"[0-9a-f]*\".*/${var}_COMMIT=\"$commit\"   # v$ver/"
            rewrite "$repo/$file" "^${var}_VERSION=\"" "s/^${var}_VERSION=\"[^\"]*\"/${var}_VERSION=\"$ver\"/"
            ;;
        tag)
            rewrite "$repo/$file" "^${var}=\\\${${var}:-" "s/^${var}=\\\${${var}:-[^}]*}/${var}=\${${var}:-$tag}/"
            ;;
        asset=*)
            rewrite "$repo/$file" "^${var}_VERSION=\\\${${var}_VERSION:-" \
                "s/^${var}_VERSION=\\\${${var}_VERSION:-[^}]*}/${var}_VERSION=\${${var}_VERSION:-$tag}/"
            for arch in $ARCHS; do
                rewrite "$repo/$file" "^ *$arch) *${var}_SHA256=" \
                    "s/^\\( *$arch) *${var}_SHA256=\\)[0-9a-f]*/\\1${sums[$arch]}/"
            done
            ;;
    esac

    tmp_items="$(mktemp)"
    awk -F '\t' -v OFS='\t' -v i="$item" -v ver="$ver" -v url="$url" -v style="$style" '
        /^#/ || NF < 5 || $1 != i { print; next }
        { $3 = ver; if (style == "url") $5 = url; print }' "$items" > "$tmp_items"
    cat "$tmp_items" > "$items"
    rm -f "$tmp_items"
    [ "$(row_version "$item")" = "$ver" ] || die "$item: items.tsv did not move to $ver"

    files="scripts/items.tsv"
    [ "$file" = - ] || files="$file, $files"
    echo "$item: $our -> $ver ($tag): $files"
}

case "${1:-}" in
    --check)
        command -v gh >/dev/null 2>&1 || die "needs gh"
        case "${2:-}" in
            --tsv) check 1 ;;
            "") check 0 ;;
            *) usage ;;
        esac
        ;;
    --bump)
        [ -n "${2:-}" ] || usage
        command -v gh >/dev/null 2>&1 || die "needs gh"
        bump "$2" "${3:-}"
        ;;
    --list) watched ;;
    *) usage ;;
esac
