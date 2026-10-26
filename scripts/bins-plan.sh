#!/usr/bin/env bash
# The build matrix for .github/workflows/build.yml: which (tool, edition, arch) builds to run for
# a comma list of tools, and which release assets each produces.
#
#   scripts/bins-plan.sh all
#   scripts/bins-plan.sh dawn,btop
#   scripts/bins-plan.sh --list          the tools this knows, one per line
#
# Prints one JSON object, {"include":[{"tool":…,"edition":…,"arch":…,"asset":…},…]}, the shape a
# workflow's strategy.matrix takes. Every tool is built for each processor in ARCHS. A tool built
# once per launcher edition (its binary carries the edition's prefix — recipes/cross/README.md)
# gets one entry per edition and processor, with the asset name recipes/cross/build-asset.sh
# gives that build: <tool>-<arch> for com.termux, <tool>-<package>-<arch> for any other.
# musl-runtime is the pair of GCC libraries fetch-musl-runtime.sh takes out of Alpine, published
# as two assets from one job. A tool whose editions column is `any` is the same bytes on every
# processor and edition: one job, arch "any", whose assets are each name under every processor's
# suffix (launcher-skills, the launcher's agent skills, recipes/cross/fetch-launcher-skills.sh).
set -euo pipefail

# The processors tlstore serves (engine/tlstore, ARCH). One run builds every tool it is asked for
# on all of them, so a tool's assets always share one bins-… tag.
ARCHS='aarch64 x86_64'
# Editions whose launcher, bootstrap and package repository are aarch64 only.
AARCH64_ONLY_EDITIONS='io.vaj.tl'

# tool  editions (- = one build for every edition, any = one build for everything)
#       assets without the -<arch> suffix (for - and any)
TOOLS='
btop         -                     btop
tl-priv      -                     tl-priv
tuios-cpu    -                     tuios-cpu
kitten       -                     kitten
tuios        -                     tuios
sigye        -                     sigye
herdr        -                     herdr
terminal-browser -                 terminal-browser
phosh        -                     phosh
fastfetch    com.termux,io.vaj.tl  -
dawn         com.termux,io.vaj.tl  -
musl-loader  com.termux,io.vaj.tl  -
musl-runtime -                     musl-libgcc,musl-libstdcxx
launcher-skills any                skill-termux-launcher,skill-termux-launcher-speak
'

known() { printf '%s\n' "$TOOLS" | awk 'NF { print $1 }'; }

if [ "${1:-}" = "--list" ]; then
    known
    exit 0
fi

want="${1:-}"
[ -n "$want" ] || { echo "usage: scripts/bins-plan.sh all|<tool>[,<tool>…]" >&2; exit 2; }
if [ "$want" = all ]; then
    want="$(known | paste -sd, -)"
fi

first=1
entry() {
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"tool":"%s","edition":"%s","arch":"%s","asset":"%s"}' "$1" "$2" "$3" "$4"
}

printf '{"include":['
IFS=, read -ra asked <<<"$want"
for tool in "${asked[@]}"; do
    tool="${tool// /}"
    [ -n "$tool" ] || continue
    line="$(printf '%s\n' "$TOOLS" | awk -v t="$tool" '$1 == t')"
    if [ -z "$line" ]; then
        echo "bins-plan: unknown tool $tool (one of: $(known | paste -sd' ' -))" >&2
        exit 2
    fi
    read -r _ editions bases <<<"$line"
    if [ "$editions" = any ]; then
        IFS=, read -ra names <<<"$bases"
        assets=""
        for name in "${names[@]}"; do
            for arch in $ARCHS; do assets="$assets$name-$arch,"; done
        done
        entry "$tool" - any "${assets%,}"
        continue
    fi
    for arch in $ARCHS; do
        if [ "$editions" = "-" ]; then
            IFS=, read -ra names <<<"$bases"
            assets="$(printf '%s,' "${names[@]/%/-$arch}")"
            entry "$tool" - "$arch" "${assets%,}"
            continue
        fi
        IFS=, read -ra eds <<<"$editions"
        for ed in "${eds[@]}"; do
            case " $AARCH64_ONLY_EDITIONS " in
                *" $ed "*) [ "$arch" = aarch64 ] || continue ;;
            esac
            case "$ed" in
                com.termux) asset="$tool-$arch" ;;
                *) asset="$tool-$ed-$arch" ;;
            esac
            entry "$tool" "$ed" "$arch" "$asset"
        done
    done
done
printf ']}\n'
