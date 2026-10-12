#!/usr/bin/env bash
# Host tests for Revision 15 (docs/SPEC.md): what large Termux packages take, said before
# install, and a package that adds a package source installed first with the lists read again.
# No framework, as scripts/test.sh: a sandbox HOME, a fake prefix, a catalog of file:// sources,
# and fake package managers. Nothing here touches the network, a device or the real HOME.
#
#   scripts/test-weight.sh [shell...]
#
# With no arguments it runs under every POSIX shell it can find, as scripts/test.sh does, which
# also runs this file. Name shells to run only those, e.g. scripts/test-weight.sh /bin/dash
#
# The phone is an apt host, played by fakes that keep state in files under $ROOT:
#   pkg       installs every package it is given into have/, or nothing at all when one of
#             them is unknown, as apt does: electron42 is unknown until lists-x11 exists, and a
#             package named in broken/ always fails.
#   apt-get   `update` creates lists-x11 once x11-repo is installed (have/x11-repo), as reading
#             the lists again after x11-repo does on a phone; `install` (only ever the size
#             question) prints apt-out and exits with apt-rc when a test wrote them, and else
#             answers as apt would: unknown electron42 before lists-x11, nothing to do after.
#   dpkg      -s <name> says whether have/<name> exists.
# The host's own pacman, apt and dpkg are kept off PATH (sys/ is the host's tools without them);
# the pacman tests put a fake pacman in front.
# The apt outputs below are written to apt 2's and apt 3's documented formats (apt-private's
# "Need to get" / "After this operation" lines, and apt 3's "Download size" / "Space needed"
# summary), not captured from a phone.

# Shell code for the sourced engine is written in single quotes on purpose: it expands there.
# shellcheck disable=SC2016
set -u

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TLSTORE="$repo/engine/tlstore"
[ -f "$TLSTORE" ] || { echo "missing $TLSTORE" >&2; exit 1; }

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

pass() { PASS=$((PASS + 1)); }
fail() {
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("[$SHELL_LABEL] $1")
    echo "  FAIL  $1"
    [ $# -lt 2 ] || printf '        %s\n' "$2"
    [ -z "${OUT:-}" ] || printf '        output: %s\n' "$(printf '%s' "$OUT" | head -8 | tr '\n' '|')"
}
skip() { SKIP=$((SKIP + 1)); echo "  SKIP  $1${2:+ — $2}"; }

sha() { sha256sum "$1" | cut -d' ' -f1; }

expect_status() { if [ "$ST" = "$2" ]; then pass; else fail "$1" "expected exit $2, got $ST"; fi; }
expect_out() { if printf '%s' "$OUT" | grep -q -- "$2"; then pass; else fail "$1" "expected output matching: $2"; fi; }
expect_no_out() { if printf '%s' "$OUT" | grep -q -- "$2"; then fail "$1" "did not expect: $2"; else pass; fi; }

# The Revision 5/6 columns after summary, all unknown, so every row is 30 columns wide.
R5_NONE="-	-	0	-	-	-	-	-	-	-	-	-	-	-	-	0	-	-	-	-"
BIG_WHAT="Termux's Electron and the libraries it needs"
BIG_LINE="Also installs $BIG_WHAT: about 153 MB to download, 862 MB on disk (less if you already have some of them)."

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

build_fixture() {
    ROOT="$(mktemp -d)"
    FX="$ROOT/fixtures"
    TESTHOME="$ROOT/home"
    TPREFIX="$ROOT/data/data/com.termux/files/usr"
    FIXBIN="$ROOT/bin"
    PACBIN="$ROOT/pacbin"
    SYS="$ROOT/sys"
    mkdir -p "$FX" "$TESTHOME" "$TPREFIX/bin" "$TPREFIX/libexec/termux-launcher/tlstore" \
        "$FIXBIN" "$PACBIN" "$SYS"
    ln -sf /bin/sh "$TPREFIX/bin/sh"

    # The host's tools, without any package manager of its own.
    ln -s /usr/bin/* /bin/* "$SYS/" 2>/dev/null
    rm -f "$SYS/pacman" "$SYS/apt" "$SYS/apt-get" "$SYS/apt-cache" "$SYS/dpkg" "$SYS/dpkg-query" "$SYS/pkg"

    cat > "$FIXBIN/pkg" <<EOF
#!/bin/sh
echo "pkg \$*" >> "$ROOT/pkg.log"
[ "\${1:-}" = install ] || exit 0
shift
[ "\${1:-}" = -y ] && shift
for p in "\$@"; do
    if [ "\$p" = electron42 ] && [ ! -e "$ROOT/lists-x11" ]; then
        echo "E: Unable to locate package \$p"; exit 100
    fi
    [ ! -e "$ROOT/broken/\$p" ] || { echo "E: \$p could not be installed"; exit 100; }
done
for p in "\$@"; do : > "$ROOT/have/\$p"; done
exit 0
EOF
    cat > "$FIXBIN/apt-get" <<EOF
#!/bin/sh
echo "apt-get \$* LC_ALL=\${LC_ALL:-}" >> "$ROOT/pkg.log"
case "\${1:-}" in
    update)
        [ ! -e "$ROOT/have/x11-repo" ] || : > "$ROOT/lists-x11"
        exit 0
        ;;
    install)
        if [ -f "$ROOT/apt-out" ]; then
            cat "$ROOT/apt-out"
            exit "\$(cat "$ROOT/apt-rc" 2>/dev/null || echo 0)"
        fi
        for p in "\$@"; do
            if [ "\$p" = electron42 ] && [ ! -e "$ROOT/lists-x11" ]; then
                echo "E: Unable to locate package \$p"; exit 100
            fi
        done
        echo "0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded."
        exit 0
        ;;
esac
exit 0
EOF
    cat > "$FIXBIN/dpkg" <<EOF
#!/bin/sh
[ "\${1:-}" = -s ] && [ -e "$ROOT/have/\${2:-}" ]
EOF
    cat > "$PACBIN/pacman" <<EOF
#!/bin/sh
echo "pacman \$*" >> "$ROOT/pkg.log"
case "\${1:-}" in
    -Q) [ -e "$ROOT/have/\${2:-}" ]; exit ;;
    -Sy) shift; [ "\${1:-}" = --needed ] && shift; [ "\${1:-}" = --noconfirm ] && shift
        for p in "\$@"; do : > "$ROOT/have/\$p"; done ;;
esac
exit 0
EOF
    chmod +x "$FIXBIN/pkg" "$FIXBIN/apt-get" "$FIXBIN/dpkg" "$PACBIN/pacman"
    RUNPATH="$FIXBIN:$SYS"
    PACPATH="$PACBIN:$FIXBIN:$SYS"

    # terminal-browser's shape: an archive that requires electron42, which requires x11-repo,
    # whose package adds the source electron42 comes from.
    mkdir -p "$FX/bigsrc/bin"
    printf '#!/bin/sh\necho big app\n' > "$FX/bigsrc/bin/app"
    chmod 755 "$FX/bigsrc/bin/app"
    tar czf "$FX/big.tgz" -C "$FX/bigsrc" .
    printf 'a small file\n' > "$FX/note.conf"
    write_catalog "$TPREFIX/libexec/termux-launcher/tlstore/catalog.tsv" 2026101201 1
}

# write_catalog <file> <serial> <big's version> [extra requires for big]
write_catalog() {
    local deps="electron42${4:+,$4}"
    {
        printf '# tlstore catalog\tserial=%s\n' "$2"
        printf 'big\tarchive\t%s\t*\tfile://%s/big.tgz\t%s\t-\t%s\texe=bin/app;pkg-size=153,862;pkg-what=%s\tA browser that needs Electron.\t%s\n' \
            "$3" "$FX" "$(sha "$FX/big.tgz")" "$deps" "$BIG_WHAT" "$R5_NONE"
        printf 'x11-repo\tpkg\t-\t*\tx11-repo\t-\t-\t-\thidden=1;repo=1\tTurns on the x11 package source.\t%s\n' "$R5_NONE"
        printf 'electron42\tpkg\t-\t*\telectron42\t-\t-\tx11-repo\thidden=1\tTermux'"'"'s Electron.\t%s\n' "$R5_NONE"
        printf 'newheavy\tpkg\t-\t*\tnewheavy\t-\t-\t-\thidden=1\tA part a later list adds.\t%s\n' "$R5_NONE"
        printf 'small\tpkg\t-\t*\tsmallpkg\t-\t-\t-\t-\tA small package.\t%s\n' "$R5_NONE"
        printf 'light\tfile\t1\t*\tfile://%s/note.conf\t%s\t~/.config/light.conf\t-\tpkg-size=10,20\tUnder the threshold.\t%s\n' \
            "$FX" "$(sha "$FX/note.conf")" "$R5_NONE"
        printf 'oddsize\tfile\t1\t*\tfile://%s/note.conf\t%s\t~/.config/oddsize.conf\t-\tpkg-size=1,2,3\tA pkg-size that is not two numbers.\t%s\n' \
            "$FX" "$(sha "$FX/note.conf")" "$R5_NONE"
        printf 'plainheavy\tfile\t1\t*\tfile://%s/note.conf\t%s\t~/.config/plainheavy.conf\t-\tpkg-size=60,0\tHeavy, with no pkg-what.\t%s\n' \
            "$FX" "$(sha "$FX/note.conf")" "$R5_NONE"
    } > "$1"
}

# fresh — nothing installed, no package here, no answers from apt queued.
fresh() {
    rm -rf "$TESTHOME" "$ROOT/have" "$ROOT/broken" "$ROOT/lists-x11" "$ROOT/apt-out" "$ROOT/apt-rc"
    mkdir -p "$TESTHOME" "$ROOT/have" "$ROOT/broken"
    : > "$ROOT/pkg.log"
}

# apt_says <exit status> — apt-get install prints what is on stdin and exits so.
apt_says() {
    cat > "$ROOT/apt-out"
    printf '%s\n' "$1" > "$ROOT/apt-rc"
}

tl_env() {
    env -i HOME="$TESTHOME" PATH="${PATH_KNOB:-$RUNPATH}" \
        TLSTORE_PREFIX="$TPREFIX" TLSTORE_HOST=termux TLSTORE_ARCH=aarch64 \
        TLSTORE_CATALOG_URL="file://$ROOT/no-such-catalog" \
        TLSTORE_RELEASE_BASE="file://$ROOT/no-such-release" \
        TLSTORE_SOURCE_ONLY="${SOURCE_KNOB:-0}" \
        "$@"
}

# tl [args...] — stdin from STDIN_TEXT (else /dev/null), stdout and stderr together.
tl() {
    OUT="$(printf '%s' "${STDIN_TEXT:-}" | tl_env "${SHCMD[@]}" "$TLSTORE" "$@" 2>&1)"
    ST=$?
    STDIN_TEXT=""
    PATH_KNOB=""
}

# tl_stdout [args...] — stdout alone.
tl_stdout() {
    OUT="$(tl_env "${SHCMD[@]}" "$TLSTORE" "$@" < /dev/null 2>/dev/null)"
    ST=$?
    PATH_KNOB=""
}

# tl_fn <shell code> — the engine sourced (TLSTORE_SOURCE_ONLY=1), then the code.
tl_fn() {
    OUT="$(SOURCE_KNOB=1 tl_env "${SHCMD[@]}" -c '. "$0"; '"$1" "$TLSTORE" < /dev/null 2>&1)"
    ST=$?
    PATH_KNOB=""
}

# parse_is <what> <apt output> <expected> — weigh_parse on that output.
parse_is() {
    OUT="$(printf '%s\n' "$2" | SOURCE_KNOB=1 tl_env "${SHCMD[@]}" -c '. "$0"; weigh_parse' "$TLSTORE" 2>&1)"
    if [ "$OUT" = "$3" ]; then pass; else fail "$1" "expected '$3', got '$OUT'"; fi
}

log_line() { grep -n -- "$1" "$ROOT/pkg.log" | head -1 | cut -d: -f1; }

# ---------------------------------------------------------------------------
# The suite
# ---------------------------------------------------------------------------

run_suite() {
    build_fixture

    # --- weigh_parse: apt's two figures, in whatever units it chose ---
    parse_is "apt 2: download and disk, in MB" \
        $'Reading package lists...\nNeed to get 75.3 MB of archives.\nAfter this operation, 414 MB of additional disk space will be used.\nDo you want to continue? [Y/n] N\nAbort.' "75 414"
    parse_is "kB, with the part already in apt's cache after the slash" \
        $'Need to get 1,234 kB/75.3 MB of archives.\nAfter this operation, 2048 kB of additional disk space will be used.' "1 2"
    parse_is "GB" \
        $'Need to get 1.2 GB of archives.\nAfter this operation, 3.4 GB of additional disk space will be used.' "1200 3400"
    parse_is "Need to get 0 B: everything is in apt's cache already" \
        $'Need to get 0 B/75.3 MB of archives.\nAfter this operation, 414 MB of additional disk space will be used.' "0 414"
    parse_is "space freed counts as none" \
        $'Need to get 0 B of archives.\nAfter this operation, 12.3 MB disk space will be freed.' "0 0"
    parse_is "apt 3's summary" \
        $'Summary:\n  Upgrading: 0, Installing: 97, Removing: 0, Not Upgrading: 3\n  Download size: 152 MB\n  Space needed: 862 MB / 50.2 GB available' "152 862"
    parse_is "nothing to install says nothing" \
        $'electron42 is already the newest version (42.7.1).\n0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.' ""
    parse_is "an apt error says nothing" $'E: Unable to locate package electron42' ""

    # --- weigh_apt: what apt says, never an install ---
    fresh
    apt_says 1 <<'EOF'
Need to get 75.3 MB of archives.
After this operation, 414 MB of additional disk space will be used.
Do you want to continue? [Y/n] N
Abort.
EOF
    tl_fn 'weigh_apt electron42; echo "rc=$? dl=$wa_dl disk=$wa_disk"'
    expect_out "apt's answer is read even though it said no to itself" "rc=0 dl=75 disk=414"
    if grep -q -- '--print-uris' "$ROOT/pkg.log" && grep -q -- '--assume-no' "$ROOT/pkg.log"; then pass; else fail "apt is asked with --print-uris and --assume-no, so it never installs" "$(cat "$ROOT/pkg.log")"; fi
    if grep -q -- "LC_ALL=C" "$ROOT/pkg.log"; then pass; else fail "in the C locale" "$(cat "$ROOT/pkg.log")"; fi
    apt_says 0 <<'EOF'
0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.
EOF
    tl_fn 'weigh_apt smallpkg; echo "rc=$? dl=$wa_dl disk=$wa_disk"'
    expect_out "nothing missing is 0 and 0" "rc=0 dl=0 disk=0"
    apt_says 100 <<'EOF'
E: Unable to locate package electron42
EOF
    tl_fn 'weigh_apt electron42; echo "rc=$?"'
    expect_out "apt that cannot work it out is a failure" "rc=1"
    : > "$ROOT/pkg.log"
    PATH_KNOB="$PACPATH" tl_fn 'weigh_apt electron42; echo "rc=$?"'
    expect_out "on pacman, apt is not asked at all" "rc=1"
    if grep -q '^apt-get' "$ROOT/pkg.log"; then fail "and apt-get is never run there"; else pass; fi

    # --- install: the line before the question, from the catalog when apt cannot say ---
    fresh
    STDIN_TEXT=$'n\n' tl install big
    expect_status "install big, answered no" 0
    expect_out "a stock Termux: apt does not know electron42 yet, so the catalog's figures" "$BIG_LINE"
    expect_out "then the usual question" "Go ahead?"
    expect_out "and no means nothing" "Nothing was installed."
    if grep -q '^pkg install' "$ROOT/pkg.log"; then fail "nothing was installed" "$(cat "$ROOT/pkg.log")"; else pass; fi
    if [ "$(printf '%s\n' "$OUT" | grep -n "$BIG_WHAT" | cut -d: -f1)" -lt "$(printf '%s\n' "$OUT" | grep -n 'Go ahead?' | cut -d: -f1)" ]; then pass; else fail "the line comes before the question"; fi

    fresh
    apt_says 1 <<'EOF'
Need to get 75.3 MB of archives.
After this operation, 414 MB of additional disk space will be used.
EOF
    tl install big -y
    expect_out "where apt can say, what this phone still needs" "The packages this needs from Termux take 75 MB to download and 414 MB more on disk."
    expect_no_out "and not the catalog's figures" "$BIG_LINE"
    expect_no_out "-y asks nothing" "Go ahead?"

    fresh
    apt_says 1 <<'EOF'
Need to get 2.1 MB of archives.
After this operation, 6 MB of additional disk space will be used.
EOF
    tl install small
    expect_status "a small package installs" 0
    expect_no_out "below the threshold nothing more is said" "MB"
    expect_out "the question is the usual one" "Installing: small"

    fresh
    apt_says 0 <<'EOF'
0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.
EOF
    : > "$ROOT/lists-x11"; : > "$ROOT/have/x11-repo"; : > "$ROOT/have/electron42"
    tl install big --dry-run
    expect_no_out "apt says it is all here: nothing is said, whatever the catalog says" "Also installs"

    fresh
    apt_says 100 <<'EOF'
E: Unable to locate package electron42
EOF
    tl install big --dry-run
    expect_status "the dry run" 0
    expect_out "says it too" "$BIG_LINE"
    expect_out "and changes nothing" "Nothing was changed."
    if grep -q '^pkg' "$ROOT/pkg.log"; then fail "the dry run installs nothing" "$(cat "$ROOT/pkg.log")"; else pass; fi

    fresh
    apt_says 100 <<'EOF'
E: Unable to locate package newheavy
EOF
    STDIN_TEXT=$'n\n' tl install plainheavy
    expect_no_out "no packages in the plan: nothing to weigh" "Also installs"

    # Under --progress the line is narration (stderr); stdout stays the machine stream.
    fresh
    tl_stdout install big --progress
    expect_no_out "--progress keeps the line off stdout" "Also installs"
    expect_out "and asks nothing" $'^done\tbig\t'

    # --- the package source: x11-repo first, the lists read again, then electron42 ---
    fresh
    tl install big -y
    expect_status "big installs on a stock Termux" 0
    a="$(log_line '^pkg install -y x11-repo$')"
    b="$(log_line '^apt-get update')"
    c="$(log_line '^pkg install -y.* electron42')"
    if [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]; then pass; else fail "x11-repo alone, then apt-get update, then electron42" "$(cat "$ROOT/pkg.log")"; fi
    expect_out "it says why x11-repo goes first" "Installing x11-repo first"
    if [ -x "$TESTHOME/.local/bin/big" ]; then pass; else fail "and big itself is in place"; fi

    fresh
    : > "$ROOT/have/x11-repo"; : > "$ROOT/lists-x11"
    tl install big -y
    expect_status "with the source already there" 0
    if grep -q '^apt-get update' "$ROOT/pkg.log"; then fail "the lists are not read again for nothing" "$(cat "$ROOT/pkg.log")"; else pass; fi
    if [ "$(grep -c '^pkg install' "$ROOT/pkg.log")" = 1 ]; then pass; else fail "one package-manager call, as before" "$(cat "$ROOT/pkg.log")"; fi

    fresh
    : > "$ROOT/broken/x11-repo"
    tl install big small -y
    expect_status "x11-repo failing fails the install" 1
    if grep -q '^apt-get update' "$ROOT/pkg.log"; then fail "no refresh after a failed x11-repo" "$(cat "$ROOT/pkg.log")"; else pass; fi
    if grep -q '^pkg install.*electron42' "$ROOT/pkg.log"; then fail "electron42 is not asked for without its source" "$(cat "$ROOT/pkg.log")"; else pass; fi
    if [ -e "$ROOT/have/smallpkg" ]; then pass; else fail "what does not need the source still installs" "$(cat "$ROOT/pkg.log")"; fi
    expect_out "and big is skipped for what it needs" "skipped big: needs electron42"

    fresh
    PATH_KNOB="$PACPATH" tl install big -y
    expect_status "on pacman" 0
    if grep -q '^pacman -Sy --needed --noconfirm x11-repo$' "$ROOT/pkg.log"; then pass; else fail "x11-repo goes in a call of its own there too" "$(cat "$ROOT/pkg.log")"; fi
    if grep -q '^apt-get' "$ROOT/pkg.log"; then fail "and apt-get is never run on pacman" "$(cat "$ROOT/pkg.log")"; else pass; fi

    # The same order with pm_run itself faked: what plan_packages asks for, call by call.
    fresh
    tl_fn 'pm_run() { echo "pm: $*" >&3; [ "$1" != pkg ] || for p in "$@"; do : > "'"$ROOT"'/have/$p"; done; return 0; }
        pa_pkg_bad=""; pa_tools_bad=""
        pick_catalog; plan_build install big >/dev/null && plan_packages 3>&1 >/dev/null 2>&1
        echo "bad=$pa_pkg_bad"'
    expect_out "pm_run: x11-repo first" "pm: pkg install -y x11-repo"
    expect_out "pm_run: then the lists" "pm: apt-get update"
    if printf '%s\n' "$OUT" | grep -n '^pm:' | tr '\n' ' ' | grep -q '1:pm: pkg install -y x11-repo 2:pm: apt-get update 3:pm: pkg install -y x11-repo electron42'; then pass; else fail "pm_run: in that order, the rest last" "$OUT"; fi
    expect_out "pm_run: every pkg row is there afterwards" "bad=$"

    # --- update: asks only when the packages it needs are large ---
    fresh
    : > "$ROOT/have/x11-repo"; : > "$ROOT/lists-x11"
    tl install big -y
    mkdir -p "$TESTHOME/.local/share/tlstore"
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026101202 2 newheavy
    apt_says 1 <<'EOF'
Need to get 120 MB of archives.
After this operation, 300 MB of additional disk space will be used.
EOF
    : > "$ROOT/pkg.log"
    STDIN_TEXT=$'n\n' tl update big --offline
    expect_out "an update that needs large packages says so" "take 120 MB to download and 300 MB more on disk"
    expect_out "and asks" "Go ahead?"
    expect_out "no leaves it" "Nothing was updated."
    if grep -q '^pkg install' "$ROOT/pkg.log"; then fail "and installs nothing" "$(cat "$ROOT/pkg.log")"; else pass; fi
    apt_says 1 <<'EOF'
Need to get 1 MB of archives.
After this operation, 2 MB of additional disk space will be used.
EOF
    tl update big --offline
    expect_status "a small one" 0
    expect_no_out "asks nothing, as before" "Go ahead?"

    # --- the item page: info and snapshot carry the line over the threshold only ---
    fresh
    tl info big --tsv
    expect_out "info --tsv: the line" $'^Packages\t'"$BIG_LINE"
    expect_out "and its figures" $'^Packages-size\t153,862$'
    tl info big
    expect_out "plain info shows it" "Packages *$BIG_LINE"
    tl info light --tsv
    expect_no_out "under the threshold, no line" "Packages"
    tl info oddsize --tsv
    expect_no_out "a pkg-size that is not two numbers is ignored" "Packages"
    tl info plainheavy --tsv
    expect_out "without pkg-what, the plain words" "Also installs packages from Termux: about 60 MB to download, 0 MB on disk"
    tl snapshot --tsv
    expect_out "the snapshot carries the same line" $'^field\tbig\tPackages\t'"$BIG_LINE"
    expect_out "and the figures" $'^field\tbig\tPackages-size\t153,862$'
    expect_no_out "and none for an item under the threshold" $'^field\tlight\tPackages'

    rm -rf "$ROOT"
}

# ---------------------------------------------------------------------------
# Shells
# ---------------------------------------------------------------------------

shells=()
if [ $# -gt 0 ]; then
    for s in "$@"; do shells+=("$s"); done
else
    shells+=("/bin/sh")
    command -v dash >/dev/null 2>&1 && shells+=("$(command -v dash)")
    command -v busybox >/dev/null 2>&1 && shells+=("$(command -v busybox) sh")
    command -v mksh >/dev/null 2>&1 && shells+=("$(command -v mksh)")
    shells+=("/bin/bash --posix")
fi

for entry in "${shells[@]}"; do
    IFS=' ' read -r -a SHCMD <<< "$entry"
    if ! command -v "${SHCMD[0]}" >/dev/null 2>&1; then
        echo "== $entry — not installed, skipped"
        SKIP=$((SKIP + 1))
        continue
    fi
    SHELL_LABEL="$entry"
    before_fail=$FAIL
    echo "== $entry"
    run_suite
    [ "$FAIL" != "$before_fail" ] || echo "   all checks passed"
done

# ---------------------------------------------------------------------------
# Older engines: the dev branch's released tlstore (dist/, what phones run) and its engine
# (the last one before this Revision). An unknown option is skipped, so the new rows read as
# before; terminal-browser's parts then fail cleanly in one package-manager call (electron42 is
# unknown until the x11 source is read), and nothing is written.
# ---------------------------------------------------------------------------

echo
echo "== older engines read the new rows"
SHELL_LABEL="older engines"
for ref in dev:dist/tlstore dev:engine/tlstore; do
    OLD="$(mktemp)"
    if ! git -C "$repo" show "$ref" > "$OLD" 2>/dev/null; then
        skip "$ref" "not reachable from this checkout"
        rm -f "$OLD"
        continue
    fi
    build_fixture
    fresh
    old() { OUT="$(tl_env /bin/sh "$OLD" "$@" < /dev/null 2>&1)"; ST=$?; }
    old list
    expect_status "$ref: list" 0
    expect_out "$ref: lists big" "big"
    expect_no_out "$ref: the hidden parts stay hidden" "x11-repo"
    old info big
    expect_status "$ref: info" 0
    old install light -y
    expect_status "$ref: an item with pkg-size= installs as before" 0
    old install small -y
    expect_status "$ref: a small package installs as before" 0
    old install big -y
    if [ "$ST" != 0 ]; then pass; else fail "$ref: big cannot be installed" "$OUT"; fi
    if [ -e "$TESTHOME/.local/lib/big" ] || [ -e "$TESTHOME/.local/bin/big" ]; then fail "$ref: and nothing of it is written"; else pass; fi
    if [ -e "$ROOT/have/x11-repo" ]; then fail "$ref: not even x11-repo, since apt refuses the whole call" "$(cat "$ROOT/pkg.log")"; else pass; fi
    rm -rf "$ROOT" "$OLD"
done

# ---------------------------------------------------------------------------
# build-catalog.sh: the fields go through as they are, and a malformed one stops the build.
# ---------------------------------------------------------------------------

echo
echo "== build-catalog.sh"
SHELL_LABEL=build-catalog
BC="$(mktemp -d)"
mkdir -p "$BC/scripts" "$BC/dist"
cp "$repo/scripts/build-catalog.sh" "$BC/scripts/"
printf '%s  big-aarch64\n' 1111111111111111111111111111111111111111111111111111111111111111 > "$BC/SHA256SUMS"
bc_tail='-	-	0	-	-	-	-	-	-	-	-	-	-	-	0	-	-'
bc_items() {
    printf 'big\tarchive\t1.0+abc1234.1\t*\tbinaries:big@1.0\t-\telectron42\t%s\tA big app.\tTools\t-\t0\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t1\t-\t-\n' "$1"
    printf 'x11-repo\tpkg\t-\tcom.termux\tx11-repo\t-\t-\t%s\tThe source.\t%s\n' "$2" "$bc_tail"
    printf 'electron42\tpkg\t-\tcom.termux\telectron42\t-\tx11-repo\thidden=1\tElectron.\t%s\n' "$bc_tail"
}
bc_build() { OUT="$(cd "$BC" && bash scripts/build-catalog.sh "$BC/SHA256SUMS" 2>&1)"; ST=$?; }
bc_items "exe=bin/app;pkg-size=153,862;pkg-what=$BIG_WHAT" "hidden=1;repo=1" > "$BC/scripts/items.tsv"
bc_build
expect_status "build-catalog.sh takes pkg-size=, pkg-what= and repo=1" 0
if awk -F'\t' -v w="exe=bin/app;pkg-size=153,862;pkg-what=$BIG_WHAT" '$1=="big" { exit ($9==w) ? 0 : 1 }' "$BC/dist/catalog.tsv"; then pass; else fail "the options reach the catalog unchanged" "$(grep '^big' "$BC/dist/catalog.tsv" | cut -f9)"; fi
if awk -F'\t' '$1=="x11-repo" { exit ($9=="hidden=1;repo=1" && NF==30) ? 0 : 1 }' "$BC/dist/catalog.tsv"; then pass; else fail "repo=1 too, in a 30-column row"; fi
# The built catalog, read back by this engine.
SHCMD=(/bin/sh)
build_fixture
fresh
cp "$BC/dist/catalog.tsv" "$TPREFIX/libexec/termux-launcher/tlstore/catalog.tsv"
tl info big --tsv
expect_out "and this engine reads the line back out of it" $'^Packages\t'"$BIG_LINE"
rm -rf "$ROOT"
for bad in "pkg-size=153" "pkg-size=153,862,1" "pkg-size=153MB,862" "pkg-size=0153,862" "pkg-what=Electron"; do
    bc_items "exe=bin/app;$bad" "hidden=1;repo=1" > "$BC/scripts/items.tsv"
    bc_build
    if [ "$ST" != 0 ]; then pass; else fail "build-catalog.sh refuses '$bad'"; fi
done
bc_items "exe=bin/app;repo=1" "hidden=1" > "$BC/scripts/items.tsv"
bc_build
if [ "$ST" != 0 ]; then pass; else fail "build-catalog.sh refuses repo=1 on an archive"; fi
bc_items "exe=bin/app" "hidden=1;repo=yes" > "$BC/scripts/items.tsv"
bc_build
if [ "$ST" != 0 ]; then pass; else fail "build-catalog.sh refuses repo= other than 1"; fi
rm -rf "$BC"

echo
if command -v shellcheck >/dev/null 2>&1; then
    echo "== shellcheck -s sh"
    if shellcheck -s sh "$TLSTORE"; then
        echo "   clean"
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("shellcheck")
    fi
else
    echo "== shellcheck is not installed — not run"
fi

echo
echo "passed $PASS, failed $FAIL, skipped $SKIP"
if [ "$FAIL" != 0 ]; then
    printf '  %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
exit 0
