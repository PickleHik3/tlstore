#!/usr/bin/env bash
# Host tests for dist/tlstore (source engine/tlstore). No framework: a sandbox
# HOME, a fake prefix, a catalog whose sources are file:// URLs, and a list of
# assertions. Nothing here touches the network, a device or the real HOME.
#
#   scripts/test.sh [shell...]
#
# With no arguments it runs the whole suite under every POSIX shell it can find
# (sh, dash, busybox sh, bash --posix) — tlstore has to work under all of them,
# and dash is what Termux's sh is. Name shells to run only those, e.g.
#   scripts/test.sh /bin/dash "/path/to/busybox sh"
#
# Two knobs let the suite exercise phone-only code paths on a Linux host, and
# tlstore reads both by design:
#   TLSTORE_ARCH=aarch64   — binary and npm-musl items are hidden on other
#                            processors; the fixture sets this so they show up.
#   TLSTORE_PATCHELF=true  — the npm-musl install runs patchelf on the
#                            downloaded executable. The fixture payload is a
#                            shell script, so patchelf would (rightly) refuse
#                            it; `true` stands in and the rest of the path —
#                            registry document, sha512, extraction, loader,
#                            wrapper — is exercised for real. Nothing else is
#                            stubbed: curl, sha256sum, sha512sum, tar, base64,
#                            od and minisign are the real tools. The npm-android
#                            item must never reach patchelf, so its tests set
#                            it to `false`, which would fail the install.
#   TLSTORE_ASSUME_TTY=1   — the questions tlstore only asks a person (replace
#                            this config file? remove the build tools?) are
#                            skipped when stdin is not a terminal. The suite has
#                            no pty, so it sets this knob and pipes the answers
#                            in; without it the "nobody is there" paths are what
#                            get tested, and both are.
#   TLSTORE_HOST=launcher  — which app the store is running in. The suite also
#                            drives the detection itself, through TERM_PROGRAM,
#                            TERM_PROGRAM_VERSION and the marker file the app
#                            writes, and checks all three.
#   TLSTORE_UI=no-such-ui  — the tlstore-ui binary bare `tlstore` execs inside
#                            the launcher. There is no pty here, so the suite
#                            never actually execs one; it points this at a
#                            fake executable to prove the routing decision, and
#                            at a name that is not there for the fallback.
#   TLSTORE_GITHUB         — where GitHub is: the suite points it at a file://
#                            tree laid out <host>/<path>, so `tlstore readme`
#                            and `readme-asset` fetch real files through real
#                            curl and never reach the network.
#   TLSTORE_RELEASE_BASE   — where the newest store release is (tlstore, its
#                            signature, tlstore-ui-<abi>). Every run points it
#                            at a file:// directory: one that is not there, so
#                            no ordinary test ever fetches a release, or one of
#                            the fixture releases the self-update tests lay out.
#   TLSTORE_BINARIES_RELEASES, TLSTORE_BINARIES_RAW — where a bare
#                            `binaries:<asset>@<tag>` source (a release asset)
#                            and a `binaries:<path>@<tag>` source (a file in
#                            the repository) resolve; file:// trees laid out
#                            <tag>/<asset>-aarch64 and <tag>/<path>.
# The catalog signature tests need minisign. Without it they are skipped, and
# the suite says so instead of passing quietly.

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
    [ -z "${OUT:-}" ] || printf '        output: %s\n' "$(printf '%s' "$OUT" | head -5 | tr '\n' '|')"
}
skip() { SKIP=$((SKIP + 1)); echo "  SKIP  $1${2:+ — $2}"; }

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

sha() { sha256sum "$1" | cut -d' ' -f1; }

# npm's dist.integrity is base64 of the raw sha512.
sha512_b64() {
    if command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha512 -binary "$1" | base64 | tr -d '\n'
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import base64,hashlib,sys;print(base64.b64encode(hashlib.sha512(open(sys.argv[1],"rb").read()).digest()).decode())' "$1"
    else
        echo "need openssl or python3 to build the npm fixture" >&2
        return 1
    fi
}

# The Revision 5 columns (category upstream setup standfirst does1..3 try
# notes author licence size picture picture-digest demo featured), the
# Revision 6 one (readme-skip) and the pinned-content addendum's three
# (readme readme-digest demo-digest), appended after summary. Every fixture
# row carries one of these two so the catalog stays 30 columns wide;
# R5_HELLO gives "hello" a category, makes it the featured item and names two
# README sections to skip, so list/search/info --tsv have something real to
# read back.
R5_NONE="-	-	0	-	-	-	-	-	-	-	-	-	-	-	-	0	-	-	-	-"
R5_HELLO="Tools	-	0	a greeting from the item list	Shows a greeting	Keeps it plain text	Does nothing else	hello	one note|another note	Test Author	MIT	~1 KB	file://example/hello.jpg	deadbeef	-	1	Portability|Star history	-	-	-"

# write_catalog <file> <serial> <version> <fakebin payload> [retire] — the
# version is the one hello and fakebin carry, so a newer catalog moves a
# config item on too. [retire]=1 marks "retiree" and "retiree-pkg" (a file and
# a pkg item, otherwise ordinary) hidden=1;retired=1 — everything else about
# their rows (kind, source, target, digest) stays exactly as it was.
write_catalog() {
    local out="$1" serial="$2" fbver="$3" fbfile="$4" retire="${5:-0}"
    local retire_opts="-"
    [ "$retire" = 1 ] && retire_opts="hidden=1;retired=1"
    {
        printf '# tlstore catalog\tserial=%s\n' "$serial"
        printf '# name\tkind\tversion\tprefixes\tsource\tdigest\ttarget\trequires\toptions\tsummary\tcategory\tupstream\tsetup\tstandfirst\tdoes1\tdoes2\tdoes3\ttry\tnotes\tauthor\tlicence\tsize\tpicture\tpicture-digest\tdemo\tfeatured\treadme-skip\treadme\treadme-digest\tdemo-digest\n'
        printf 'hello\tfile\t%s\t*\tfile://%s/hello.conf\t%s\t~/.config/hello.conf\t-\t-\tA greeting you can read.\t%s\n' "$fbver" "$FX" "$(sha "$FX/hello.conf")" "$R5_HELLO"
        printf 'mine\tfile-once\t1\t*\tfile://%s/mine.conf\t%s\t~/.config/mine.conf\t-\t-\tYours to edit, installed once.\t%s\n' "$FX" "$(sha "$FX/mine.conf")" "$R5_NONE"
        printf 'fakebin\tbinary\t%s\t*\tfile://%s/%s\t%s\t-\t-\t-\tA small tool for the terminal.\t%s\n' "$fbver" "$FX" "$fbfile" "$(sha "$FX/$fbfile")" "$R5_NONE"
        printf 'badsum\tbinary\t1\t*\tfile://%s/hello.conf\t%s\t~/.local/bin/badsum\t-\t-\tNever installs, on purpose.\t%s\n' "$FX" "0000000000000000000000000000000000000000000000000000000000000000" "$R5_NONE"
        printf 'twin\tbinary\t1\tio.vaj.tl\tfile://%s/other.bin\t%s\t~/.local/bin/twin\t-\t-\tThe other edition build.\t%s\n' "$FX" "$(sha "$FX/other.bin")" "$R5_NONE"
        printf 'twin\tbinary\t1\tcom.termux\tfile://%s/twin.bin\t%s\t~/.local/bin/twin\t-\t-\tThis edition build.\t%s\n' "$FX" "$(sha "$FX/twin.bin")" "$R5_NONE"
        printf 'ghost\tbinary\t1\tio.vaj.tl\tfile://%s/other.bin\t%s\t-\t-\t-\tOnly for another edition.\t%s\n' "$FX" "$(sha "$FX/other.bin")" "$R5_NONE"
        # A priv=shizuku binary and the hidden tl-priv it requires. The fixture
        # tl-priv only echoes what it was asked to run, so the wrapper's exec
        # line is what gets exercised, not a launcher.
        printf 'tl-priv\tbinary\t1\t*\tfile://%s/tl-priv.bin\t%s\t-\t-\thidden=1\tThe client that runs a privileged item through the launcher.\t%s\n' "$FX" "$(sha "$FX/tl-priv.bin")" "$R5_NONE"
        printf 'privbin\tbinary\t1\t*\tfile://%s/fakebin-1\t%s\t-\ttl-priv\tpriv=shizuku\tRuns as the shell user through the lane.\t%s\n' "$FX" "$(sha "$FX/fakebin-1")" "$R5_NONE"
        printf 'demo-pkg\tpkg\t-\t*\tdemo-one demo-two\t-\t-\t-\t-\tTwo packages from the package manager.\t%s\n' "$R5_NONE"
        printf 'musl-loader\tbinary\t1\tcom.termux\tfile://%s/loader.bin\t%s\t~/.local/lib/musl/ld-musl-aarch64.so.1\t-\t-\tWhat tools from other systems need to start.\t%s\n' "$FX" "$(sha "$FX/loader.bin")" "$R5_NONE"
        printf 'claude-code\tnpm-musl\tlatest\t*\tnpm:demo-cli#claude\t-\t-\tmusl-loader,demo-pkg\tenv=DEMO_FLAG=1;tz=1;build=demo-build\tA tool that comes from npm.\t%s\n' "$R5_NONE"
        printf 'musl-cxx\tbinary\t1\t*\tfile://%s/musllib.bin\t%s\t~/.local/lib/musl/libdemo++.so.6\t-\thidden=1\tA library tools from other systems need.\t%s\n' "$FX" "$(sha "$FX/musllib.bin")" "$R5_NONE"
        printf 'agent\tnpm-musl\tlatest\t*\tnpm:demo-agent#bin/agent\t-\t-\tmusl-loader,musl-cxx\tmusl-libs=musl-cxx\tAn agent that comes from npm.\t%s\n' "$R5_NONE"
        printf 'droid\tnpm-android\tlatest\t*\tnpm:demo-droid#bin/droid.bin\t-\t-\t-\textra=bin/droid-helper;command=droid;args=-c demo=1\tA program built for Android that comes from npm.\t%s\n' "$R5_NONE"
        printf 'kit\tbundle\t-\t*\t-\t-\t-\thello,fakebin,demo-pkg,secret\t-\tA few things at once.\t%s\n' "$R5_NONE"
        # conflicts=: a bundle and its part that refuse to install while the package termux-api is
        # (the marker file the fake pacman looks for), the way the termux-api-shims item does.
        printf 'shimset\tbundle\t-\t*\t-\t-\t-\tshimpart\tconflicts=termux-api\tA bundle that owns commands a package owns.\t%s\n' "$R5_NONE"
        printf 'shimpart\tfile\t1\t*\tfile://%s/hello.conf\t%s\t~/.config/shimpart.conf\t-\thidden=1;conflicts=termux-api\tA part that owns a command a package owns.\t%s\n' "$FX" "$(sha "$FX/hello.conf")" "$R5_NONE"
        printf 'plug\tfisher\t-\t*\tdemo/one demo/two\t-\t-\t-\t-\tPlugins for the shell.\t%s\n' "$R5_NONE"
        printf 'secret\tfile\t1\t*\tfile://%s/mine.conf\t%s\t~/.config/secret.conf\t-\thidden=1\tA part of something else.\t%s\n' "$FX" "$(sha "$FX/mine.conf")" "$R5_NONE"
        printf 'launcheronly\tbinary\t1\t*\tfile://%s/twin.bin\t%s\t~/.local/bin/launcheronly\t-\thost=launcher\tOnly where the launcher runs it.\t%s\n' "$FX" "$(sha "$FX/twin.bin")" "$R5_NONE"
        printf 'termuxonly\tbinary\t1\t*\tfile://%s/other.bin\t%s\t~/.local/bin/termuxonly\t-\thost=termux\tOnly in the plain app.\t%s\n' "$FX" "$(sha "$FX/other.bin")" "$R5_NONE"
        printf 'recentonly\tbinary\t1\t*\tfile://%s/twin.bin\t%s\t~/.local/bin/recentonly\t-\tmin-launcher=0.3.0\tWants a recent app.\t%s\n' "$FX" "$(sha "$FX/twin.bin")" "$R5_NONE"
        # A file and a pkg item, retired (hidden=1;retired=1) when this
        # function is asked to, everything else about their rows unchanged —
        # the retirement tests install one, retire it, and check what update
        # does with it.
        printf 'retiree\tfile\t1\t*\tfile://%s/retiree.conf\t%s\t~/.config/retiree/nested/retiree.conf\t-\t%s\tA fixture item, retired when the catalog says so.\t%s\n' \
            "$FX" "$(sha "$FX/retiree.conf")" "$retire_opts" "$R5_NONE"
        printf 'retiree-pkg\tpkg\t-\t*\tdemo-retiree\t-\t-\t-\t%s\tA fixture package, retired when the catalog says so.\t%s\n' \
            "$retire_opts" "$R5_NONE"
        # A real, fetchable picture and demo, so `tlstore picture` has
        # something genuine to verify and cache. Digests are computed here,
        # not folded into R5_HELLO/R5_NONE, since they depend on the fixture
        # files this function's caller already made. The demo's own digest is
        # real too now (demo-digest), so `tlstore picture pictured demo` is
        # digest-checked the same way the cover picture is.
        printf 'pictured\tfile\t1\t*\tfile://%s/hello.conf\t%s\t~/.config/pictured.conf\t-\t-\tHas a real picture and demo, for the picture command tests.\tTools\t-\t0\tan item with a picture\tShows a picture\tKeeps it simple\tHas a demo too\tpictured\t-\tTest Author\tMIT\t~1 KB\tfile://%s/pictured.jpg\t%s\tfile://%s/pictured-demo.jpg\t0\t-\t-\t-\t%s\n' \
            "$FX" "$(sha "$FX/hello.conf")" "$FX" "$(sha "$FX/pictured.jpg")" "$FX" "$(sha "$FX/pictured-demo.jpg")"
        # Same picture file, but the catalog's own digest for it is wrong —
        # `tlstore picture` must refuse it the way any other digest mismatch is.
        printf 'badpic\tfile\t1\t*\tfile://%s/hello.conf\t%s\t~/.config/badpic.conf\t-\t-\tHas a picture whose digest never matches, on purpose.\tTools\t-\t0\t-\t-\t-\t-\t-\t-\tTest Author\tMIT\t-\tfile://%s/pictured.jpg\t0000000000000000000000000000000000000000000000000000000000000000\t-\t0\t-\t-\t-\t-\n' \
            "$FX" "$(sha "$FX/hello.conf")" "$FX"
        # A demo whose digest never matches, on purpose — the demo-digest
        # side of the same rule, kept separate from badpic's picture-digest.
        printf 'baddemo\tfile\t1\t*\tfile://%s/hello.conf\t%s\t~/.config/baddemo.conf\t-\t-\tHas a demo whose digest never matches, on purpose.\tTools\t-\t0\t-\t-\t-\t-\t-\t-\tTest Author\tMIT\t-\t-\t-\tfile://%s/pictured-demo.jpg\t0\t-\t-\t-\t0000000000000000000000000000000000000000000000000000000000000000\n' \
            "$FX" "$(sha "$FX/hello.conf")" "$FX"
        # A binary whose source is a FIFO: curl blocks reading it until this
        # test writes to the other end, so a --progress install can be
        # cancelled reliably while it is still in flight.
        printf 'slow\tbinary\t1\t*\tfile://%s/slow.pipe\t-\t-\t-\t-\tA slow item, so a --progress cancel can land mid-download.\t%s\n' "$FX" "$R5_NONE"
        # Items with an upstream, one per way `tlstore readme` picks the
        # revision to read: a +<hash> version, an x.y.z version whose tag is
        # there, one whose tag is not, a rolling version, and one whose
        # upstream has nothing at all (the offline case).
        printf 'pinned\tfile\t1.0.0+abc1234.5\t*\tfile://%s/hello.conf\t%s\t~/.config/pinned.conf\t-\t-\tRead at the commit in its version.\t%s\n' "$FX" "$(sha "$FX/hello.conf")" "$(r6_upstream demo/pinned)"
        printf 'tagged\tfile\t2.3.4\t*\tfile://%s/hello.conf\t%s\t~/.config/tagged.conf\t-\t-\tRead at its v tag.\t%s\n' "$FX" "$(sha "$FX/hello.conf")" "$(r6_upstream demo/tagged)"
        printf 'untagged\tfile\t3.0.0\t*\tfile://%s/hello.conf\t%s\t~/.config/untagged.conf\t-\t-\tHas no v tag, so HEAD it is.\t%s\n' "$FX" "$(sha "$FX/hello.conf")" "$(r6_upstream demo/untagged)"
        printf 'rolling\tfile\tlatest\t*\tfile://%s/hello.conf\t%s\t~/.config/rolling.conf\t-\t-\tNo version to speak of.\t%s\n' "$FX" "$(sha "$FX/hello.conf")" "$(r6_upstream demo/rolling)"
        printf 'nowhere\tfile\t1.0.0\t*\tfile://%s/hello.conf\t%s\t~/.config/nowhere.conf\t-\t-\tIts upstream cannot be reached.\t%s\n' "$FX" "$(sha "$FX/hello.conf")" "$(r6_upstream demo/nowhere)"
        # Pinned content (Revision 6 addendum): an item whose readme column
        # points at a pinned copy instead of an upstream one. "readmepinned"
        # verifies against the real digest and must never touch GitHub at
        # all (its upstream, demo/readmepinned, has no fixture tree under
        # $GH); "readmepinnedbad" carries a digest that never matches, so the
        # fetch must fail — no silent fall back to upstream.
        printf 'readmepinned\tfile\t1\t*\tfile://%s/hello.conf\t%s\t~/.config/readmepinned.conf\t-\t-\tRead from a pinned copy, not upstream.\t%s\n' \
            "$FX" "$(sha "$FX/hello.conf")" "$(r6_upstream_pinned demo/readmepinned "file://$FX/pinned-hero.md" "$(sha "$FX/pinned-hero.md")")"
        printf 'readmepinnedbad\tfile\t1\t*\tfile://%s/hello.conf\t%s\t~/.config/readmepinnedbad.conf\t-\t-\tA pinned readme whose digest never matches, on purpose.\t%s\n' \
            "$FX" "$(sha "$FX/hello.conf")" "$(r6_upstream_pinned demo/readmepinnedbad "file://$FX/pinned-hero.md" 0000000000000000000000000000000000000000000000000000000000000000)"
    } > "$out"
}

# The same shape with an upstream, for the readme tests: <version> and
# <upstream> are the two things `tlstore readme` reads.
r6_upstream() { printf 'Tools\t%s\t0\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t0\t-\t-\t-\t-' "$1"; }

# r6_upstream_pinned <upstream> <readme url> <readme digest> — like
# r6_upstream, but with a pinned readme (readme, readme-digest) instead of
# "-", for the pinned-readme tests.
r6_upstream_pinned() { printf 'Tools\t%s\t0\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t0\t-\t%s\t%s\t-' "$1" "$2" "$3"; }

build_fixture() {
    ROOT="$(mktemp -d)"
    FX="$ROOT/fixtures"
    TESTHOME="$ROOT/home"
    TPREFIX="$ROOT/data/data/com.termux/files/usr"
    FIXBIN="$ROOT/bin"
    mkdir -p "$FX" "$TESTHOME" "$TPREFIX/bin" "$TPREFIX/libexec/termux-launcher/tlstore" "$FIXBIN"

    # A shell for the generated wrapper's shebang, which names $PREFIX/bin/sh.
    ln -sf /bin/sh "$TPREFIX/bin/sh"

    printf 'greeting from the catalog\n' > "$FX/hello.conf"
    printf 'your own settings go here\n' > "$FX/mine.conf"
    printf 'retire me if I am never edited\n' > "$FX/retiree.conf"
    printf '#!/bin/sh\necho fakebin 1\n' > "$FX/fakebin-1"
    printf '#!/bin/sh\necho fakebin 2\n' > "$FX/fakebin-2"
    printf '#!/bin/sh\necho fakebin 3\n' > "$FX/fakebin-3"
    printf '#!/bin/sh\necho twin here\n' > "$FX/twin.bin"
    printf '#!/bin/sh\necho other edition\n' > "$FX/other.bin"
    printf 'not really a loader\n' > "$FX/loader.bin"
    printf '#!/bin/sh\necho "tl-priv $*"\n' > "$FX/tl-priv.bin"
    printf 'a picture worth caching\n' > "$FX/pictured.jpg"
    printf 'a demo worth caching\n' > "$FX/pictured-demo.jpg"
    printf '<!-- tlstore: pinned from demo/pinnedsrc@abcdef1 -->\n# pinned\n\nread from the pinned copy, never from upstream\n' > "$FX/pinned-hero.md"
    rm -f "$FX/slow.pipe"
    mkfifo "$FX/slow.pipe"

    # A release asset and a repository file, where a binaries: source of each
    # form resolves: <releases>/<tag>/<asset>-aarch64 and <raw>/<tag>/<path>.
    mkdir -p "$FX/rel/1.0" "$FX/raw/1.0/readme"
    printf '#!/bin/sh\necho relbin from a release\n' > "$FX/rel/1.0/relbin-aarch64"
    printf '<!-- tlstore: pinned from demo/relpinned@abcdef1 -->\n# relpinned\n\nread from the repository at the tag\n' > "$FX/raw/1.0/readme/relpinned.md"

    # GitHub, as a directory: <host>/<path> under $FX/gh, which TLSTORE_GITHUB
    # points tlstore at. One README per revision the readme tests expect to be
    # read, pictures beside two of them, and one picture over the 5 MB cap.
    GH="$FX/gh"
    RAWGH="$GH/raw.githubusercontent.com"
    mkdir -p "$RAWGH/demo/pinned/abc1234" "$RAWGH/demo/tagged/v2.3.4/docs" \
        "$RAWGH/demo/untagged/HEAD/docs" "$RAWGH/demo/rolling/HEAD" \
        "$GH/user-images.githubusercontent.com/123" "$GH/demo.github.io" "$GH/github.com/demo/tagged/raw/HEAD"
    printf '# pinned\n\nread at abc1234\n' > "$RAWGH/demo/pinned/abc1234/README.md"
    printf '# tagged\n\nread at v2.3.4\n\n![shot](docs/shot.png)\n' > "$RAWGH/demo/tagged/v2.3.4/README.md"
    printf '# untagged\n\nread at HEAD\n' > "$RAWGH/demo/untagged/HEAD/README.md"
    printf '# rolling\n\nread at HEAD\n' > "$RAWGH/demo/rolling/HEAD/README.md"
    printf 'the tagged shot\n' > "$RAWGH/demo/tagged/v2.3.4/docs/shot.png"
    printf 'the untagged shot\n' > "$RAWGH/demo/untagged/HEAD/docs/shot.png"
    truncate -s 5242881 "$RAWGH/demo/tagged/v2.3.4/big.png"
    printf 'a user image\n' > "$GH/user-images.githubusercontent.com/123/abc.png"
    printf 'a pages picture\n' > "$GH/demo.github.io/pic.png"
    printf 'a github.com raw picture\n' > "$GH/github.com/demo/tagged/raw/HEAD/x.png"
    mkdir -p "$RAWGH/demo/pinnedsrc/abcdef1/docs"
    printf 'the pinned-commit shot\n' > "$RAWGH/demo/pinnedsrc/abcdef1/docs/shot.png"

    # Fake package managers: they record what they were asked for. Both names
    # are needed — tlstore prefers pacman, and a host may have a real one.
    cat > "$FIXBIN/pkg" <<EOF
#!/bin/sh
echo "\$@" >> "$ROOT/pkg.log"
exit 0
EOF
    chmod +x "$FIXBIN/pkg"
    cp "$FIXBIN/pkg" "$FIXBIN/apt"
    # pacman is the one tlstore prefers, and the only one it asks whether a
    # package is already there: -Q says no for the build tool, yes for the rest.
    cat > "$FIXBIN/pacman" <<EOF
#!/bin/sh
echo "\$@" >> "$ROOT/pkg.log"
if [ "\${1:-}" = -S ]; then
    # What the real one prints with no terminal, so --progress has lines to read.
    echo ":: Synchronizing package databases..."
    echo " demo-one-1-1-aarch64 downloading..."
    echo "(1/1) checking package integrity"
    echo "(1/1) installing demo-one"
    echo ":: Running post-transaction hooks..."
fi
[ "\${1:-}" = -Q ] || exit 0
[ "\${2:-}" = demo-build ] && exit 1
# termux-api is "installed" only while the test has dropped this marker (the conflicts= tests).
if [ "\${2:-}" = termux-api ] && [ ! -e "$ROOT/have-termux-api" ]; then exit 1; fi
exit 0
EOF
    chmod +x "$FIXBIN/pacman"

    # A fake fish, so the plugin manager's install and remove can be seen.
    cat > "$FIXBIN/fish" <<EOF
#!/bin/sh
echo "\$@" >> "$ROOT/fish.log"
exit 0
EOF
    chmod +x "$FIXBIN/fish"

    # curl itself, counted: every call is written to curl.log before the real
    # curl runs it, so a test can prove a prefetch fetched nothing.
    REAL_CURL="$(command -v curl)"
    cat > "$FIXBIN/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$ROOT/curl.log"
exec "$REAL_CURL" "\$@"
EOF
    chmod +x "$FIXBIN/curl"

    # A fake npm registry: two package documents and their tarballs.
    mkdir -p "$FX/registry/demo-cli" "$FX/pkgsrc/package"
    cat > "$FX/pkgsrc/package/claude" <<'EOF'
#!/bin/sh
echo "demo-cli 1.0.0"
echo "DEMO_FLAG=${DEMO_FLAG:-unset}"
EOF
    chmod +x "$FX/pkgsrc/package/claude"
    printf 'MIT\n' > "$FX/pkgsrc/package/LICENSE.md"
    tar czf "$FX/demo-cli-1.0.0.tgz" -C "$FX/pkgsrc" package
    printf '{"name":"demo-cli","version":"1.0.0","dist":{"tarball":"file://%s/demo-cli-1.0.0.tgz","integrity":"sha512-%s"}}\n' \
        "$FX" "$(sha512_b64 "$FX/demo-cli-1.0.0.tgz")" > "$FX/registry/demo-cli/latest"

    # The second keeps its executable in a subdirectory and needs a library the
    # loader alone does not provide — opencode's shape.
    mkdir -p "$FX/registry/demo-agent" "$FX/agentsrc/package/bin"
    cat > "$FX/agentsrc/package/bin/agent" <<'EOF'
#!/bin/sh
echo "demo-agent 2.0.0"
EOF
    chmod +x "$FX/agentsrc/package/bin/agent"
    tar czf "$FX/demo-agent-2.0.0.tgz" -C "$FX/agentsrc" package
    printf '{"name":"demo-agent","version":"2.0.0","dist":{"tarball":"file://%s/demo-agent-2.0.0.tgz","integrity":"sha512-%s"}}\n' \
        "$FX" "$(sha512_b64 "$FX/demo-agent-2.0.0.tgz")" > "$FX/registry/demo-agent/latest"
    printf 'the musl C++ library\n' > "$FX/musllib.bin"

    # The third is an Android build (codex-termux's shape): the executable is
    # not named like the command, and it needs a helper beside it.
    mkdir -p "$FX/registry/demo-droid" "$FX/droidsrc/package/bin"
    cat > "$FX/droidsrc/package/bin/droid.bin" <<'EOF'
#!/bin/sh
echo "demo-droid 3.0.0"
echo "args: $*"
"$(dirname "$0")/droid-helper"
EOF
    cat > "$FX/droidsrc/package/bin/droid-helper" <<'EOF'
#!/bin/sh
echo "helper beside the executable"
EOF
    chmod +x "$FX/droidsrc/package/bin/droid.bin" "$FX/droidsrc/package/bin/droid-helper"
    printf 'Apache-2.0\n' > "$FX/droidsrc/package/LICENSE"
    printf 'notice\n' > "$FX/droidsrc/package/NOTICE"
    tar czf "$FX/demo-droid-3.0.0.tgz" -C "$FX/droidsrc" package
    printf '{"name":"demo-droid","version":"3.0.0","dist":{"tarball":"file://%s/demo-droid-3.0.0.tgz","integrity":"sha512-%s"}}\n' \
        "$FX" "$(sha512_b64 "$FX/demo-droid-3.0.0.tgz")" > "$FX/registry/demo-droid/latest"

    # The catalog the app ships, plus three the refresh can be pointed at.
    write_catalog "$TPREFIX/libexec/termux-launcher/tlstore/catalog.tsv" 2026090601 1 fakebin-1
    write_catalog "$FX/newer.tsv" 2026090602 2 fakebin-2
    write_catalog "$FX/older.tsv" 2026090600 1 fakebin-1
    write_catalog "$FX/newest.tsv" 2026090603 2 fakebin-2
    write_catalog "$FX/tampered.tsv" 2026090604 2 fakebin-2

    HAVE_MINISIGN=0
    if command -v minisign >/dev/null 2>&1; then
        HAVE_MINISIGN=1
        minisign -G -W -f -p "$ROOT/key.pub" -s "$ROOT/key.sec" >/dev/null 2>&1 || HAVE_MINISIGN=0
    fi
    if [ "$HAVE_MINISIGN" = 1 ]; then
        cp "$ROOT/key.pub" "$TPREFIX/libexec/termux-launcher/tlstore/trusted.pub"
        for c in newer older newest tampered; do
            minisign -S -s "$ROOT/key.sec" -x "$FX/$c.tsv.minisig" -m "$FX/$c.tsv" >/dev/null 2>&1
        done
        # Signed, then changed: the signature no longer covers the file.
        printf '# nudged after signing\n' >> "$FX/tampered.tsv"
    fi

    RUNPATH="$FIXBIN"
    if command -v minisign >/dev/null 2>&1; then
        RUNPATH="$RUNPATH:$(dirname "$(command -v minisign)")"
    fi
    RUNPATH="$RUNPATH:/usr/bin:/bin"
}

# ---------------------------------------------------------------------------
# Running tlstore
# ---------------------------------------------------------------------------

# tl [args...] — stdin comes from $STDIN_TEXT when set.
tl() {
    local input="${STDIN_TEXT:-}"
    if [ -n "$input" ]; then
        OUT="$(printf '%s' "$input" | env -i \
            HOME="$TESTHOME" PATH="$RUNPATH" \
            TLSTORE_PREFIX="$TPREFIX" \
            TLSTORE_CATALOG_URL="$CATALOG_URL" \
            TLSTORE_NPM_REGISTRY="file://$FX/registry" \
            TLSTORE_ARCH=aarch64 \
            TLSTORE_PATCHELF="${PATCHELF_KNOB:-true}" \
            TLSTORE_ASSUME_TTY="${TTY_KNOB:-0}" \
            TLSTORE_HOST="${HOST_KNOB:-}" \
            TLSTORE_UI="${UI_KNOB:-}" \
            TLSTORE_GITHUB="file://$FX/gh" \
            TLSTORE_RELEASE_BASE="${RELEASE_KNOB:-file://$FX/release-none}" \
            TLSTORE_BINARIES_RELEASES="file://$FX/rel" \
            TLSTORE_BINARIES_RAW="file://$FX/raw" \
            TERM_PROGRAM="${TP_KNOB:-}" \
            TERM_PROGRAM_VERSION="${TPV_KNOB:-}" \
            "${SHCMD[@]}" "$TLSTORE" "$@" 2>&1)"
    else
        OUT="$(env -i \
            HOME="$TESTHOME" PATH="$RUNPATH" \
            TLSTORE_PREFIX="$TPREFIX" \
            TLSTORE_CATALOG_URL="$CATALOG_URL" \
            TLSTORE_NPM_REGISTRY="file://$FX/registry" \
            TLSTORE_ARCH=aarch64 \
            TLSTORE_PATCHELF="${PATCHELF_KNOB:-true}" \
            TLSTORE_ASSUME_TTY="${TTY_KNOB:-0}" \
            TLSTORE_HOST="${HOST_KNOB:-}" \
            TLSTORE_UI="${UI_KNOB:-}" \
            TLSTORE_GITHUB="file://$FX/gh" \
            TLSTORE_RELEASE_BASE="${RELEASE_KNOB:-file://$FX/release-none}" \
            TLSTORE_BINARIES_RELEASES="file://$FX/rel" \
            TLSTORE_BINARIES_RAW="file://$FX/raw" \
            TERM_PROGRAM="${TP_KNOB:-}" \
            TERM_PROGRAM_VERSION="${TPV_KNOB:-}" \
            "${SHCMD[@]}" "$TLSTORE" "$@" < /dev/null 2>&1)"
    fi
    ST=$?
    STDIN_TEXT=""
    TTY_KNOB=0
    HOST_KNOB=""
    PATCHELF_KNOB=""
    UI_KNOB=""
    RELEASE_KNOB=""
    TP_KNOB=""
    TPV_KNOB=""
    return 0
}

# tl_stdout [args...] — like tl, but OUT is stdout alone (stderr discarded),
# to prove --progress keeps its machine lines clean of the human narration
# say() sends to stderr in that mode; no test besides that one needs it.
tl_stdout() {
    OUT="$(env -i \
        HOME="$TESTHOME" PATH="$RUNPATH" \
        TLSTORE_PREFIX="$TPREFIX" \
        TLSTORE_CATALOG_URL="$CATALOG_URL" \
        TLSTORE_NPM_REGISTRY="file://$FX/registry" \
        TLSTORE_ARCH=aarch64 \
        TLSTORE_PATCHELF=true \
        TLSTORE_ASSUME_TTY="${TTY_KNOB:-0}" \
        TLSTORE_HOST="${HOST_KNOB:-}" \
        TLSTORE_UI="${UI_KNOB:-}" \
        TLSTORE_GITHUB="file://$FX/gh" \
        TLSTORE_RELEASE_BASE="${RELEASE_KNOB:-file://$FX/release-none}" \
        TLSTORE_BINARIES_RELEASES="file://$FX/rel" \
        TLSTORE_BINARIES_RAW="file://$FX/raw" \
        TERM_PROGRAM="${TP_KNOB:-}" \
        TERM_PROGRAM_VERSION="${TPV_KNOB:-}" \
        "${SHCMD[@]}" "$TLSTORE" "$@" < /dev/null 2>/dev/null)"
    ST=$?
    HOST_KNOB=""
    PATCHELF_KNOB=""
    UI_KNOB=""
    RELEASE_KNOB=""
    TP_KNOB=""
    TPV_KNOB=""
    return 0
}

expect_status() {
    if [ "$ST" = "$2" ]; then pass; else fail "$1" "expected exit $2, got $ST"; fi
}
expect_out() {
    if printf '%s' "$OUT" | grep -q -- "$2"; then pass; else fail "$1" "expected output matching: $2"; fi
}
expect_no_out() {
    if printf '%s' "$OUT" | grep -q -- "$2"; then fail "$1" "did not expect: $2"; else pass; fi
}
expect_file() {
    if [ -e "$2" ]; then pass; else fail "$1" "expected file $2"; fi
}
expect_no_file() {
    if [ -e "$2" ]; then fail "$1" "$2 should be gone"; else pass; fi
}
expect_content() {
    local got
    got="$(cat "$2" 2>/dev/null)"
    if [ "$got" = "$3" ]; then pass; else fail "$1" "$2 holds '$got', expected '$3'"; fi
}

# ---------------------------------------------------------------------------
# The suite
# ---------------------------------------------------------------------------

run_suite() {
    build_fixture
    CATALOG_URL="file://$FX/newer.tsv"
    STDIN_TEXT=""
    HOST_KNOB=""
    PATCHELF_KNOB=""
    UI_KNOB=""
    RELEASE_KNOB=""
    TP_KNOB=""
    TPV_KNOB=""

    # --- help, version, usage ---
    tl help; expect_status "help" 0; expect_out "help lists commands" "tlstore install"
    expect_no_out "help no longer mentions browse" "browse"
    tl version; expect_status "version" 0; expect_out "version names the item list" "2026090601"
    tl nonsense; expect_status "unknown command is a usage error" 2
    tl browse; expect_status "browse is no longer a command" 2
    tl list -x; expect_status "unknown option is a usage error" 2
    tl search; expect_status "search with no term is a usage error" 2
    tl remove; expect_status "remove with no name is a usage error" 2
    tl info nosuch; expect_status "info on an unknown item fails" 1

    # --- bare command: tlstore-ui inside the launcher, the list everywhere else ---
    # This harness has no pty, so on_terminal is always false here — every one
    # of these falls back to the list; the exec itself is proved below with a
    # real pty, when one is available.
    tl
    expect_status "no arguments, not the launcher" 0
    expect_out "prints the item list" "hello"
    expect_out "and one line on how to install" "Run 'tlstore install' to add what you want."
    expect_no_out "not the old full usage text" "tlstore info <name>"
    HOST_KNOB=launcher
    tl
    expect_status "no arguments, the launcher, but no terminal here" 0
    expect_out "still prints the item list" "hello"
    HOST_KNOB=launcher
    UI_KNOB="$ROOT/no-such-tlstore-ui"
    tl
    expect_status "no arguments, the launcher, a ui path that is not there" 0
    expect_out "falls back to the item list" "hello"
    if command -v script >/dev/null 2>&1; then
        ui_fake="$FIXBIN/fake-tlstore-ui"
        printf '#!/bin/sh\necho TLSTORE_UI_RAN\n' > "$ui_fake"
        chmod +x "$ui_fake"
        ui_log="$ROOT/ui.typescript"
        script -qc "env -i HOME='$TESTHOME' PATH='$RUNPATH' TLSTORE_PREFIX='$TPREFIX' \
            TLSTORE_CATALOG_URL='$CATALOG_URL' TLSTORE_HOST=launcher TLSTORE_UI='$ui_fake' \
            ${SHCMD[*]} '$TLSTORE'" "$ui_log" >/dev/null 2>&1
        if grep -q TLSTORE_UI_RAN "$ui_log" 2>/dev/null; then
            pass
        else
            fail "no arguments execs tlstore-ui inside the launcher, with a real terminal"
        fi
        rm -f "$ui_log" "$ui_fake"
    else
        skip "bare-command exec routing" "script is not installed"
    fi

    # --- list, search, info, per-prefix and per-arch selection ---
    tl list
    expect_status "list" 0
    expect_out "list shows a file item" "hello"
    expect_out "list shows a bundle" "kit"
    expect_no_out "list hides another edition's item" "ghost"
    expect_no_out "list hides the parts of other items" "secret"
    expect_out "list leaves room for the installed mark" "^  hello"
    expect_out "list hints at what an item builds with" "needs while installing: demo-build"
    tl search part
    expect_no_out "search hides them too" "secret"
    tl info secret
    expect_status "info still explains a part" 0
    expect_out "info names the part" "part of something else"
    tl install secret -y
    expect_status "installing a part by name is refused" 1
    expect_out "and says why" "part of another item"
    tl info twin
    expect_out "the row for this prefix wins" "twin.bin"
    expect_no_out "the other edition's row is not used" "other.bin"
    tl search greeting
    expect_status "search" 0
    expect_out "search matches the summary" "hello"
    tl info hello
    expect_status "info" 0
    expect_out "info names where the file goes" ".config/hello.conf"
    expect_out "info names the checksum" "$(sha "$FX/hello.conf")"

    # --- which app the store is running in ---
    # Nothing in the environment and no marker file: the plain app.
    tl list
    expect_no_out "an item for the launcher is hidden in the plain app" "launcheronly"
    expect_out "an item for the plain app shows there" "termuxonly"
    HOST_KNOB=launcher
    tl list
    expect_out "TLSTORE_HOST=launcher shows the launcher's items" "launcheronly"
    expect_no_out "and hides the plain app's" "termuxonly"
    TP_KNOB=termux-launcher
    tl list
    expect_out "the launcher names itself in the environment" "launcheronly"
    TP_KNOB=something-else
    tl list
    expect_no_out "any other app in the environment is not the launcher" "launcheronly"
    # Over ssh nothing names the app; the file it writes on every start does.
    touch "$TPREFIX/libexec/termux-launcher/tlstore/.installed"
    tl list
    expect_out "with nothing else to go on, the app's own file answers" "launcheronly"
    rm -f "$TPREFIX/libexec/termux-launcher/tlstore/.installed"
    tl list
    expect_no_out "and without it this is the plain app" "launcheronly"
    tl info launcheronly
    expect_status "info on an item for the other app fails" 1
    expect_out "and says it is not in the list" "not in the list"
    HOST_KNOB=launcher
    tl info launcheronly
    expect_status "info on it in the launcher works" 0
    tl install launcheronly -y
    expect_status "installing an item for the other app is refused" 1

    # --- an item that wants a recent launcher ---
    TP_KNOB=termux-launcher
    TPV_KNOB=0.2.39
    tl list
    expect_no_out "an older launcher does not see it" "recentonly"
    TP_KNOB=termux-launcher
    TPV_KNOB=0.3.1
    tl list
    expect_out "a newer launcher sees it" "recentonly"
    TP_KNOB=termux-launcher
    tl list
    expect_out "a launcher that does not say its version sees it" "recentonly"
    tl list
    expect_out "and so does the plain app" "recentonly"

    # --- a file, where there is none yet ---
    mkdir -p "$TESTHOME/.config"
    tl install hello -y
    expect_status "install a file" 0
    expect_content "the file was written" "$TESTHOME/.config/hello.conf" "greeting from the catalog"
    tl list -i
    expect_out "list -i shows what is installed" "hello"
    tl list -a
    expect_no_out "list -a hides what is installed" "hello"

    # --- a config file that already differs: never replaced silently ---
    # Each case starts as a first install over a file tlstore did not put there,
    # which is what a user with their own config.fish actually has.
    forget_state() { rm -f "$TESTHOME/.local/share/tlstore/installed.tsv"; }

    printf 'the users own greeting\n' > "$TESTHOME/.config/hello.conf"

    # nobody there to ask: kept, one line, still recorded
    forget_state
    tl install hello -y
    expect_status "a config that differs, with nobody to ask" 0
    expect_content "the users own config is kept" "$TESTHOME/.config/hello.conf" "the users own greeting"
    expect_out "and it says so" "kept your hello.conf"
    expect_no_out "-y does not answer the config question" "Replace your"

    # asked, and answered no
    forget_state
    TTY_KNOB=1
    STDIN_TEXT='n
'
    tl install hello -y
    expect_status "a config that differs, answered no" 0
    expect_out "the change is shown" "greeting from the catalog"
    expect_out "and the question is asked" "Replace your hello.conf"
    expect_content "answering no keeps the users file" "$TESTHOME/.config/hello.conf" "the users own greeting"

    # asked, and answered yes
    forget_state
    TTY_KNOB=1
    STDIN_TEXT='y
'
    tl install hello -y
    expect_status "a config that differs, answered yes" 0
    expect_content "answering yes takes the new file" "$TESTHOME/.config/hello.conf" "greeting from the catalog"
    if ls "$TESTHOME/.config/hello.conf".bak-* >/dev/null 2>&1; then pass; else fail "the old config was kept beside it"; fi

    # identical: nothing to show, nothing to ask
    forget_state
    tl install hello -y
    expect_status "a config that is already identical" 0
    expect_no_out "an identical config asks nothing" "Replace your"
    expect_no_out "an identical config shows nothing" "^---"

    # --configs answers it without a person
    printf 'changed again\n' > "$TESTHOME/.config/hello.conf"
    forget_state
    tl install hello -y --configs
    expect_status "--configs" 0
    expect_content "--configs takes the new config" "$TESTHOME/.config/hello.conf" "greeting from the catalog"
    expect_no_out "--configs does not ask" "Replace your"

    # --- a file-once, twice ---
    printf 'already mine\n' > "$TESTHOME/.config/mine.conf"
    tl install mine -y
    expect_status "install a file-once over an existing file" 0
    expect_content "a file-once leaves the users file alone" "$TESTHOME/.config/mine.conf" "already mine"
    tl install mine -y
    expect_status "install a file-once again" 0
    expect_content "the second run keeps it" "$TESTHOME/.config/mine.conf" "already mine"

    # --- a binary, and a digest that does not match ---
    tl install fakebin -y
    expect_status "install a binary" 0
    expect_file "the binary landed in ~/.local/bin" "$TESTHOME/.local/bin/fakebin"
    if [ -x "$TESTHOME/.local/bin/fakebin" ]; then pass; else fail "the binary is executable"; fi
    tl install badsum -y
    expect_status "a payload that does not match its checksum fails" 1
    expect_no_file "nothing is left behind after a checksum failure" "$TESTHOME/.local/bin/badsum"

    # --- a privileged binary: the program off PATH, a wrapper on it ---
    tl install privbin -y
    expect_status "install a priv=shizuku binary" 0
    expect_file "the program lands off PATH" "$TESTHOME/.local/lib/tlstore/priv/privbin"
    expect_file "the wrapper lands on PATH" "$TESTHOME/.local/bin/privbin"
    expect_file "tl-priv comes in with it" "$TESTHOME/.local/bin/tl-priv"
    expect_content "the wrapper hands the program to tl-priv" "$TESTHOME/.local/bin/privbin" "#!$TPREFIX/bin/sh
# written by termux-launcher
exec \"$TESTHOME/.local/bin/tl-priv\" run \"$TESTHOME/.local/lib/tlstore/priv/privbin\" \"\$@\""
    OUT="$("$TESTHOME/.local/bin/privbin" --flag 2>&1)"; ST=$?
    expect_status "the wrapper runs" 0
    expect_out "the wrapper runs the program through tl-priv, arguments and all" "^tl-priv run $TESTHOME/.local/lib/tlstore/priv/privbin --flag$"
    tl info privbin --tsv
    expect_out "info names both files" $'^Files\t'"$TESTHOME/.local/lib/tlstore/priv/privbin $TESTHOME/.local/bin/privbin"'$'
    tl remove privbin -y
    expect_status "remove a priv=shizuku binary" 0
    expect_no_file "the program is gone" "$TESTHOME/.local/lib/tlstore/priv/privbin"
    expect_no_file "the wrapper is gone too" "$TESTHOME/.local/bin/privbin"

    # --- a bundle, with a package item in it ---
    tl install kit -y
    expect_status "install a bundle" 0
    expect_out "the bundle installs its members" "demo-pkg"
    expect_file "a bundle brings its hidden parts in" "$TESTHOME/.config/secret.conf"
    if grep -q demo-one "$ROOT/pkg.log" 2>/dev/null; then pass; else fail "the package manager was asked for the packages"; fi
    tl list -i
    expect_out "the bundle is recorded" "kit"
    expect_out "list marks what you have" "^\* kit"

    # --- fish plugins, which fisher fetches and fisher keeps current ---
    tl install plug -y
    expect_status "install fish plugins" 0
    if grep -q -- "-c fisher install demo/one demo/two" "$ROOT/fish.log" 2>/dev/null; then pass; else fail "fisher was asked to install the plugins"; fi
    tl install plug -y
    expect_out "installing them again says they are there" "already installed"
    tl remove plug -y
    expect_status "remove fish plugins" 0
    if grep -q -- "-c fisher remove demo/one demo/two" "$ROOT/fish.log" 2>/dev/null; then pass; else fail "fisher was asked to remove the plugins"; fi

    # --- npm-musl ---
    tl install claude-code -y
    expect_status "install an npm-musl item" 0
    expect_file "the loader is in place" "$TESTHOME/.local/lib/claude-code/ld-musl-aarch64.so.1"
    expect_file "the package executable is in place" "$TESTHOME/.local/lib/claude-code/claude"
    expect_content "the installed version is recorded" "$TESTHOME/.local/lib/claude-code/version" "1.0.0"
    expect_file "the wrapper is named after the command" "$TESTHOME/.local/bin/claude"
    expect_out "the build tool is installed first" "Installing what is needed to build: demo-build"
    expect_out "-y also answers the cleanup question" "Removed them"
    OUT="$("$TESTHOME/.local/bin/claude" 2>&1)"; ST=$?
    expect_status "the wrapper runs" 0
    expect_out "the wrapper runs the package executable" "demo-cli 1.0.0"
    expect_out "the wrapper exports the options" "DEMO_FLAG=1"
    if grep -q -- "-S --needed --noconfirm demo-build" "$ROOT/pkg.log"; then pass; else fail "the build tool was installed"; fi
    if grep -q -- "-R --noconfirm demo-build" "$ROOT/pkg.log"; then pass; else fail "the build tool was removed again"; fi
    tl info claude-code
    expect_out "info names the build tools" "Builds with demo-build"

    # --- npm-musl with extra musl libraries, and an executable in a subdirectory ---
    tl install agent -y
    expect_status "install an npm-musl item that needs more of musl" 0
    expect_file "the extra library is beside the loader" "$TESTHOME/.local/lib/agent/libdemo++.so.6"
    expect_file "the loader is there too" "$TESTHOME/.local/lib/agent/ld-musl-aarch64.so.1"
    expect_file "the executable keeps its own path inside the package" "$TESTHOME/.local/lib/agent/bin/agent"
    expect_file "the wrapper is named after the command, not the path" "$TESTHOME/.local/bin/agent"
    expect_file "the library is also installed on its own" "$TESTHOME/.local/lib/musl/libdemo++.so.6"
    OUT="$("$TESTHOME/.local/bin/agent" 2>&1)"; ST=$?
    expect_status "the wrapper runs" 0
    expect_out "the wrapper runs the package executable" "demo-agent 2.0.0"
    tl remove agent -y
    expect_status "remove it again" 0

    # --- npm-android: no loader, no patchelf, an extra member, a command name and args ---
    PATCHELF_KNOB=false
    mkdir -p "$TESTHOME/.local/bin"
    printf 'my own droid\n' > "$TESTHOME/.local/bin/droid"
    tl install droid -y
    expect_status "install an npm-android item" 0
    expect_out "a file of yours where the wrapper goes is kept" "kept a copy of droid beside it"
    expect_file "the executable is in place" "$TESTHOME/.local/lib/droid/bin/droid.bin"
    expect_file "the extra member is beside it" "$TESTHOME/.local/lib/droid/bin/droid-helper"
    expect_file "its licence and notice come along" "$TESTHOME/.local/lib/droid/NOTICE"
    expect_content "the installed version is recorded" "$TESTHOME/.local/lib/droid/version" "3.0.0"
    expect_file "the wrapper is named by command=" "$TESTHOME/.local/bin/droid"
    if [ -e "$TESTHOME/.local/lib/droid/ld-musl-aarch64.so.1" ]; then fail "no musl loader belongs in an Android package"; else pass; fi
    if [ -e "$TESTHOME/.local/bin/droid.bin" ]; then fail "the wrapper is not named after the executable"; else pass; fi
    OUT="$("$TESTHOME/.local/bin/droid" one two 2>&1)"; ST=$?
    expect_status "the wrapper runs" 0
    expect_out "the wrapper runs the package executable" "demo-droid 3.0.0"
    expect_out "args= come before the person's own" "args: -c demo=1 one two"
    expect_out "the extra member is reachable beside the executable" "helper beside the executable"
    # What an older tlstore left: a copy of its own wrapper per update, and
    # more copies of a file of yours than are worth keeping.
    for bk in 20200101-000001 20200101-000002; do
        printf '#!/bin/sh\n# written by termux-launcher\nexec old "$@"\n' > "$TESTHOME/.local/bin/droid.bak-$bk"
    done
    for bk in 20190101-000001 20190101-000002 20190101-000003; do
        printf 'an older one of mine\n' > "$TESTHOME/.local/bin/droid.bak-$bk"
    done
    PATCHELF_KNOB=false
    tl install droid -y
    expect_out "installing it again says it is already here" "droid 3.0.0 is already here"
    if ls "$TESTHOME/.local/bin/droid.bak-2020"* >/dev/null 2>&1; then fail "copies of tlstore's own wrapper are pruned"; else pass; fi
    if [ "$(ls "$TESTHOME/.local/bin/droid.bak-"* 2>/dev/null | wc -l)" -eq 3 ]; then pass; else fail "three copies of your own file are kept" "$(ls "$TESTHOME/.local/bin/")"; fi
    if [ -e "$TESTHOME/.local/bin/droid.bak-20190101-000001" ]; then fail "the oldest copy is the one that goes"; else pass; fi
    tl remove droid -y
    expect_status "remove an npm-android item" 0
    expect_out "remove puts your own file back" "put your own droid back"
    if [ -e "$TESTHOME/.local/lib/droid" ]; then fail "remove deletes the directory"; else pass; fi
    expect_content "what is back is yours, not the wrapper" "$TESTHOME/.local/bin/droid" "my own droid"
    rm -f "$TESTHOME/.local/bin/droid"

    # --- build tools, with nobody to ask and with an answer ---
    : > "$ROOT/pkg.log"
    tl install claude-code
    expect_status "reinstall with nobody to ask" 0
    expect_no_out "nobody there means the build tools stay" "Removed them"
    if grep -q -- "-R --noconfirm demo-build" "$ROOT/pkg.log"; then fail "the build tool should have stayed"; else pass; fi

    : > "$ROOT/pkg.log"
    TTY_KNOB=1
    STDIN_TEXT='y
n
'
    tl install claude-code
    expect_status "reinstall, cleanup declined" 0
    expect_out "the cleanup question names the packages" "only needed for installing (demo-build)"
    if grep -q -- "-R --noconfirm demo-build" "$ROOT/pkg.log"; then fail "answering no should keep them"; else pass; fi

    : > "$ROOT/pkg.log"
    TTY_KNOB=1
    STDIN_TEXT='y
y
'
    tl install claude-code
    expect_status "reinstall, cleanup accepted" 0
    if grep -q -- "-R --noconfirm demo-build" "$ROOT/pkg.log"; then pass; else fail "answering yes should remove them"; fi

    # An item already here asks for nothing to build with.
    : > "$ROOT/pkg.log"
    tl install fakebin -y
    expect_no_out "nothing is built for what is already installed" "needed to build"

    # --- remove, with the backup put back ---
    tl remove hello -y
    expect_status "remove" 0
    expect_content "the file that was there came back" "$TESTHOME/.config/hello.conf" "changed again"
    tl list -i
    expect_no_out "a removed item is no longer installed" "hello"
    tl remove hello -y
    expect_status "removing something twice is not an error" 0
    expect_out "removing something twice says so" "not installed"

    # --- update ---
    # Put a config item back first, from the catalog the app ships, so the
    # refresh below has something whose shipped version has moved on.
    tl install hello -y --configs
    tl update --check
    expect_status "update --check" 0
    expect_out "update --check took the newer item list" "Updated the list of items"
    expect_out "update --check names what is out of date" "fakebin"
    expect_out "a config with a new version says the change will be shown" "hello has a new version"
    tl version
    expect_out "the refreshed item list is in use" "2026090602"
    tl update -y
    expect_status "update" 0
    OUT="$("$TESTHOME/.local/bin/fakebin" 2>&1)"; ST=$?
    expect_out "update replaced the payload" "fakebin 2"
    tl update --check
    expect_out "nothing is out of date afterwards" "up to date"
    tl update --check --offline
    expect_status "update --offline" 0

    # --- refresh ---
    if [ "$HAVE_MINISIGN" = 1 ]; then
        CATALOG_URL="file://$FX/older.tsv"
        tl refresh
        expect_status "an older item list is refused" 1
        expect_out "and says so" "older"
        tl version
        expect_out "the item list did not move" "2026090602"

        CATALOG_URL="file://$FX/tampered.tsv"
        tl refresh
        expect_status "an item list with a broken signature is refused" 1
        expect_out "and says so" "not signed by the launcher"
        tl version
        expect_out "the item list still did not move" "2026090602"

        CATALOG_URL="file://$FX/newest.tsv"
        tl refresh
        expect_status "a newer, signed item list is taken" 0
        tl version
        expect_out "the newer item list is in use" "2026090603"
        tl refresh
        expect_status "refreshing again is fine" 0
        expect_out "and says there is nothing new" "up to date"
    else
        skip "catalog signature tests" "minisign is not installed"
    fi

    # --- graphics setup, which the app installs and tlstore only runs ---
    tl display
    expect_status "display without the app's script" 1
    expect_out "and says what to do" "update the app"
    printf '#!/bin/sh\necho "gpu-setup $*"\n' > "$TPREFIX/bin/termux-x11-gpu-setup"
    chmod +x "$TPREFIX/bin/termux-x11-gpu-setup"
    tl display --yes --keep
    expect_status "display runs the app's script" 0
    expect_out "and passes the arguments through" "gpu-setup --yes --keep"

    # --- doctor ---
    tl doctor
    expect_status "doctor" 0
    expect_out "doctor names the prefix" "$TPREFIX"
    expect_out "doctor names the item list" "Item list"
    expect_out "doctor names the app it is running in" "^App *Termux (com.termux)"
    TP_KNOB=termux-launcher
    TPV_KNOB=0.2.40
    tl doctor
    expect_out "doctor names the launcher and its version" "^App *Termux Launcher 0.2.40 (com.termux)"

    # --- the columns a program reads ---
    tl list --tsv
    expect_status "list --tsv" 0
    expect_out "list --tsv says what is installed, with both versions" \
        $'^hello\tinstalled\t2\t2\tfile\tA greeting'
    expect_out "list --tsv leaves the installed column empty for the rest" \
        $'^twin\tavailable\t1\t\tbinary\t'
    expect_no_out "list --tsv prints no mark column" '^\* '
    expect_no_out "list --tsv hides the parts of other items" "^secret"
    expect_out "list --tsv carries the category and featured columns" \
        $'^hello\tinstalled\t2\t2\tfile\tA greeting you can read.\tTools\t1$'
    expect_out "an item with no category prints -, not featured" \
        $'^twin\tavailable\t1\t\tbinary\t.*\t-\t0$'
    tl list --tsv -a
    expect_no_out "list --tsv -a is only what you do not have" $'^hello\t'
    tl list --tsv -i
    expect_out "list --tsv -i is only what you have" $'^hello\tinstalled\t'
    tl search --tsv greeting
    expect_status "search --tsv" 0
    expect_out "search --tsv has the same columns as list" $'^hello\tinstalled\t2\t2\tfile\t'
    expect_out "search --tsv carries category and featured too" \
        $'^hello\tinstalled\t2\t2\tfile\tA greeting you can read.\tTools\t1$'
    tl info --tsv hello
    expect_status "info --tsv" 0
    expect_out "info --tsv gives one key and value per line" $'^Kind\tfile$'
    expect_out "info --tsv names the version" $'^Version\t2$'
    expect_out "info --tsv names where it came from" $'^From\tfile://'
    expect_out "info --tsv names the checksum" $'^Checksum\t'
    expect_out "info --tsv names what it needs" $'^Needs\t'
    expect_out "info --tsv names where the file goes" $'^Files\t.*hello.conf$'
    expect_out "info --tsv says what is installed" $'^Installed\t2$'
    expect_out "info --tsv ends with the summary" $'^Summary\tA greeting you can read.$'
    expect_no_out "info --tsv is not the form for people" "^hello$"
    # --- the Revision 5 item-spread fields, round-tripped through info --tsv ---
    expect_out "info --tsv names the category" $'^Category\tTools$'
    expect_no_out "info --tsv skips an unknown upstream" $'^Upstream\t'
    expect_out "info --tsv always names setup, 0 being an answer" $'^Setup\t0$'
    expect_out "info --tsv names the standfirst" $'^Standfirst\ta greeting from the item list$'
    expect_out "info --tsv names does1" $'^Does1\tShows a greeting$'
    expect_out "info --tsv names does2" $'^Does2\tKeeps it plain text$'
    expect_out "info --tsv names does3" $'^Does3\tDoes nothing else$'
    expect_out "info --tsv names try" $'^Try\thello$'
    expect_out "info --tsv keeps notes pipe-separated" $'^Notes\tone note|another note$'
    expect_out "info --tsv names the author" $'^Author\tTest Author$'
    expect_out "info --tsv names the licence" $'^Licence\tMIT$'
    expect_out "info --tsv names the size" $'^Size\t~1 KB$'
    expect_out "info --tsv names the picture" $'^Picture\tfile://example/hello.jpg$'
    expect_out "info --tsv names the picture digest alongside it" $'^Picture-digest\tdeadbeef$'
    expect_out "info --tsv always names featured, 0 being an answer" $'^Featured\t1$'
    expect_out "info --tsv names the readme sections to skip, pipe-separated" $'^Readme-skip\tPortability|Star history$'
    tl info --tsv twin
    expect_no_out "an item with no picture prints no Picture line" $'^Picture\t'
    expect_out "and featured still prints as 0" $'^Featured\t0$'
    expect_no_out "and nothing to skip prints no Readme-skip line" $'^Readme-skip\t'
    expect_no_out "and no readme column prints no Readme line" $'^Readme\t'
    tl info --tsv pictured
    expect_out "info --tsv names the demo alongside its digest" $'^Demo\tfile://'
    expect_out "and the demo digest alongside it" $'^Demo-digest\t'"$(sha "$FX/pictured-demo.jpg")"'$'
    tl info --tsv readmepinned
    expect_out "info --tsv names a pinned readme" $'^Readme\tfile://'
    expect_out "and its digest alongside it" $'^Readme-digest\t'"$(sha "$FX/pinned-hero.md")"'$'
    tl info --tsv claude-code
    expect_out "info --tsv names the build tools" $'^Builds with\tdemo-build$'
    tl info --tsv
    expect_status "info --tsv still needs a name" 2
    # --- the same handful, for a person reading the terminal ---
    tl info hello
    expect_out "human info also names the category" "Category *Tools"
    expect_out "human info also names the author" "Author *Test Author"
    expect_out "human info also names the licence" "Licence *MIT"
    expect_out "human info also names the size" "Size *~1 KB"
    expect_no_out "human info does not dump the item-spread copy" "Standfirst"

    # --- tlstore picture: a digest-verified, cached local copy for tlstore-ui ---
    PIC_DIGEST="$(sha "$FX/pictured.jpg")"
    PIC_CACHE="$TESTHOME/.cache/tlstore/pictures/$PIC_DIGEST.jpg"
    rm -rf "$TESTHOME/.cache/tlstore"

    tl_stdout picture pictured
    expect_status "picture prints a path and exits 0" 0
    expect_out "it names the digest-keyed cache copy" "^$PIC_CACHE\$"
    expect_content "the cached copy is really the picture" "$PIC_CACHE" "a picture worth caching"

    # A second call must never touch the source again: move it out of the way
    # and prove the same cached path still comes back, offline.
    mv "$FX/pictured.jpg" "$FX/pictured.jpg.moved"
    tl_stdout picture pictured
    expect_status "a second call is instant and offline" 0
    expect_out "and returns the very same cached path" "^$PIC_CACHE\$"
    mv "$FX/pictured.jpg.moved" "$FX/pictured.jpg"

    DEMO_DIGEST="$(sha "$FX/pictured-demo.jpg")"
    DEMO_CACHE="$TESTHOME/.cache/tlstore/pictures/$DEMO_DIGEST.jpg"
    tl_stdout picture pictured demo
    expect_status "picture demo prints the demo's path" 0
    expect_out "keyed by the demo's own digest, like the cover picture" "^$DEMO_CACHE\$"
    expect_content "and it really is the demo picture" "$OUT" "a demo worth caching"

    tl_stdout picture baddemo demo
    expect_status "a demo whose digest does not match fails" 1
    expect_no_out "and prints nothing on stdout" "."
    expect_no_file "and nothing was cached for it" \
        "$TESTHOME/.cache/tlstore/pictures/0000000000000000000000000000000000000000000000000000000000000000.jpg"

    tl_stdout picture twin
    expect_status "an item with no picture fails" 1
    expect_no_out "and prints nothing on stdout" "."

    tl_stdout picture no-such-item
    expect_status "an unknown item fails" 1
    expect_no_out "and prints nothing on stdout" "."

    tl_stdout picture hello
    expect_status "a picture whose source cannot be fetched fails" 1
    expect_no_out "and prints nothing on stdout" "."
    expect_no_file "and nothing was cached for it" "$TESTHOME/.cache/tlstore/pictures/deadbeef.jpg"

    tl_stdout picture badpic
    expect_status "a picture whose digest does not match fails" 1
    expect_no_out "and prints nothing on stdout" "."
    expect_no_file "and nothing was cached for it either" \
        "$TESTHOME/.cache/tlstore/pictures/0000000000000000000000000000000000000000000000000000000000000000.jpg"

    # --- tlstore readme: the upstream README, cached a day, for the item page ---
    # Every item below (pinned, tagged, untagged, rolling, nowhere) carries
    # "-" in its readme column (r6_upstream), so these all exercise the
    # upstream-fallback path — the same path a catalog from before the
    # pinned-content columns takes for every item.
    RM_CACHE="$TESTHOME/.cache/tlstore/readme"
    rm -rf "$TESTHOME/.cache/tlstore"

    tl_stdout readme pinned
    expect_status "readme prints a path and exits 0" 0
    expect_out "the cache path carries the name and version" "^$RM_CACHE/pinned-1.0.0+abc1234.5.md\$"
    expect_content "a +<hash> version is read at that commit" "$OUT" $'# pinned\n\nread at abc1234'

    tl_stdout readme tagged
    expect_status "an x.y.z version reads its v tag" 0
    expect_content "and gets the tag's README" "$OUT" $'# tagged\n\nread at v2.3.4\n\n![shot](docs/shot.png)'

    tl_stdout readme untagged
    expect_status "an x.y.z version whose tag is not there still succeeds" 0
    expect_content "by falling back to HEAD" "$OUT" $'# untagged\n\nread at HEAD'

    tl_stdout readme rolling
    expect_status "any other version reads HEAD" 0
    expect_content "and gets HEAD's README" "$OUT" $'# rolling\n\nread at HEAD'

    # --- pinned content (Revision 6 addendum): readme, readme-digest ---
    READMEPIN_DIGEST="$(sha "$FX/pinned-hero.md")"
    READMEPIN_CACHE="$TESTHOME/.cache/tlstore/readme/pinned/$READMEPIN_DIGEST.md"

    mv "$FX/gh" "$FX/gh.away"
    tl_stdout readme readmepinned
    expect_status "a pinned readme is served without touching GitHub" 0
    expect_out "from a digest-keyed cache path, like a picture" "^$READMEPIN_CACHE\$"
    expect_content "and it really is the pinned copy" "$OUT" "$(printf '<!-- tlstore: pinned from demo/pinnedsrc@abcdef1 -->\n# pinned\n\nread from the pinned copy, never from upstream')"
    mv "$FX/gh.away" "$FX/gh"

    tl_stdout readme readmepinnedbad
    expect_status "a pinned readme whose digest does not match fails" 1
    expect_no_out "and prints nothing on stdout" "."
    expect_no_file "and nothing was cached for it" \
        "$TESTHOME/.cache/tlstore/readme/pinned/0000000000000000000000000000000000000000000000000000000000000000.md"

    # A second call for the same pinned readme is served from the same
    # digest-keyed cache, offline, the same as a repeated `tlstore picture`.
    mv "$FX/pinned-hero.md" "$FX/pinned-hero.md.moved"
    tl_stdout readme readmepinned
    expect_status "a second call is instant and offline" 0
    expect_out "and returns the very same cached path" "^$READMEPIN_CACHE\$"
    mv "$FX/pinned-hero.md.moved" "$FX/pinned-hero.md"

    # A second call within the day never looks upstream: take GitHub away.
    mv "$FX/gh" "$FX/gh.away"
    tl_stdout readme pinned
    expect_status "a second call is served from the cache, offline" 0
    expect_out "with the same path" "^$RM_CACHE/pinned-1.0.0+abc1234.5.md\$"
    # A day-old copy still answers, offline or not: the open path never waits on
    # GitHub. The prefetch is what looks upstream again, once a day.
    touch -t 200001010000 "$RM_CACHE/pinned-1.0.0+abc1234.5.md"
    tl_stdout readme pinned
    expect_status "a stale copy still answers when GitHub cannot be reached" 0
    expect_content "with what it had" "$OUT" $'# pinned\n\nread at abc1234'
    mv "$FX/gh.away" "$FX/gh"
    printf '# pinned\n\nread again at abc1234\n' > "$RAWGH/demo/pinned/abc1234/README.md"
    tl_stdout readme pinned
    expect_status "with GitHub back, readme still answers from the copy it has" 0
    expect_content "unchanged: the open path never fetches what it has" "$OUT" $'# pinned\n\nread at abc1234'
    tl_stdout prefetch
    expect_status "prefetch revalidates a day-old copy" 0
    expect_content "and the newer README replaces it" "$RM_CACHE/pinned-1.0.0+abc1234.5.md" $'# pinned\n\nread again at abc1234'
    if [ -z "$(find "$RM_CACHE/pinned-1.0.0+abc1234.5.md" -mtime +0)" ]; then pass; else fail "the refreshed copy counts as checked again"; fi
    touch -t 200001010000 "$RM_CACHE/pinned-1.0.0+abc1234.5.md"
    tl_stdout prefetch
    if [ -z "$(find "$RM_CACHE/pinned-1.0.0+abc1234.5.md" -mtime +0)" ]; then pass; else fail "a copy checked again is marked so, newer or not"; fi
    expect_content "and keeps what it had" "$RM_CACHE/pinned-1.0.0+abc1234.5.md" $'# pinned\n\nread again at abc1234'

    tl readme kit
    expect_status "an item with no upstream exits 2" 2
    expect_out "and says so on stderr" "kit has no readme"
    tl_stdout readme kit
    expect_no_out "and prints nothing on stdout" "."

    tl readme nowhere
    expect_status "nothing fetched and nothing cached exits 1" 1
    expect_out "with one line on stderr" "could not fetch the readme for nowhere"
    if [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ]; then pass; else fail "exactly one line" "$OUT"; fi
    tl_stdout readme nowhere
    expect_no_out "and prints nothing on stdout" "."
    expect_no_file "and nothing was cached for it" "$RM_CACHE/nowhere-1.0.0.md"

    tl readme
    expect_status "readme needs a name" 2
    tl readme no-such-item
    expect_status "readme on an unknown item fails" 1

    # --- tlstore readme-asset: a README's pictures, from GitHub only ---
    tl_stdout readme-asset tagged docs/shot.png
    expect_status "a relative picture resolves against the README's revision" 0
    expect_out "into the item's own cache directory, under the README's revision" "^$RM_CACHE/tagged/v2.3.4/[0-9a-f]*\.png\$"
    expect_content "and is the tag's copy of it" "$OUT" "the tagged shot"
    tl_stdout readme-asset readmepinned docs/shot.png
    expect_status "a relative picture in a pinned readme resolves against the commit it names" 0
    expect_content "and is that commit's copy, not upstream's" "$OUT" "the pinned-commit shot"
    tl_stdout readme-asset untagged ./docs/shot.png
    expect_status "a relative picture follows the fallback to HEAD" 0
    expect_content "and is HEAD's copy of it" "$OUT" "the untagged shot"

    tl_stdout readme-asset tagged https://user-images.githubusercontent.com/123/abc.png
    expect_status "an https picture on user-images.githubusercontent.com is fetched" 0
    expect_content "and cached" "$OUT" "a user image"
    tl_stdout readme-asset tagged https://demo.github.io/pic.png
    expect_status "an https picture on github.io is fetched" 0
    expect_content "and cached too" "$OUT" "a pages picture"
    tl_stdout readme-asset tagged https://github.com/demo/tagged/raw/HEAD/x.png
    expect_status "an https picture on github.com is fetched" 0
    expect_content "and cached as well" "$OUT" "a github.com raw picture"
    RA_ABS="$OUT"

    tl readme-asset tagged https://example.com/x.png
    expect_status "a picture anywhere else exits 1" 1
    expect_out "and says it was left alone" "is not on GitHub"
    tl readme-asset tagged http://raw.githubusercontent.com/demo/tagged/v2.3.4/docs/shot.png
    expect_status "plain http exits 1, even on a GitHub host" 1
    tl readme-asset tagged https://github.com.example.com/x.png
    expect_status "a host that only starts like GitHub exits 1" 1
    tl readme-asset tagged https://evil.example/github.com/x.png
    expect_status "GitHub in the path is not GitHub as the host" 1
    tl readme-asset tagged "data:image/png;base64,AAAA"
    expect_status "a data address exits 1" 1
    tl_stdout readme-asset tagged https://example.com/x.png
    expect_no_out "and a refused picture prints nothing on stdout" "."

    tl readme-asset tagged big.png
    expect_status "a picture over 5 MB exits 1" 1
    expect_out "and says it could not be fetched" "could not fetch big.png"
    if ls "$RM_CACHE/tagged/"*/.*.part "$RM_CACHE/tagged/"*/.*.new >/dev/null 2>&1; then fail "no half-written picture is left behind"; else pass; fi

    tl readme-asset tagged docs/missing.png
    expect_status "a relative picture that is not there exits 1" 1
    tl readme-asset kit docs/shot.png
    expect_status "a relative picture for an item with no upstream exits 2" 2
    tl readme-asset tagged
    expect_status "readme-asset needs a name and an address" 2

    # Cached pictures are served offline and never fetched again on the open
    # path; the prefetch revalidates a README's header picture once a day.
    mv "$FX/gh" "$FX/gh.away"
    tl_stdout readme-asset tagged https://github.com/demo/tagged/raw/HEAD/x.png
    expect_status "a cached picture is served offline" 0
    expect_out "from the same path" "^$RA_ABS\$"
    touch -t 200001010000 "$RA_ABS"
    tl_stdout readme-asset tagged https://github.com/demo/tagged/raw/HEAD/x.png
    expect_status "a stale picture still answers offline" 0
    mv "$FX/gh.away" "$FX/gh"
    printf 'a newer github.com raw picture\n' > "$GH/github.com/demo/tagged/raw/HEAD/x.png"
    tl_stdout readme-asset tagged https://github.com/demo/tagged/raw/HEAD/x.png
    expect_status "with GitHub back, the open path still answers from the copy" 0
    expect_content "unchanged" "$RA_ABS" "a github.com raw picture"
    RA_SHOT="$RM_CACHE/tagged/v2.3.4/$(printf '%s' "https://raw.githubusercontent.com/demo/tagged/v2.3.4/docs/shot.png" | sha256sum | cut -d' ' -f1).png"
    expect_file "the README's header picture is cached under the README's revision" "$RA_SHOT"
    touch -t 200001010000 "$RA_SHOT"
    printf 'the tagged shot, retaken\n' > "$RAWGH/demo/tagged/v2.3.4/docs/shot.png"
    tl_stdout prefetch
    expect_content "prefetch brings the newer header picture" "$RA_SHOT" "the tagged shot, retaken"
    if [ -z "$(find "$RA_SHOT" -mtime +0)" ]; then pass; else fail "and marks it checked"; fi

    # A newer list, put in place without a refresh, so there is something to
    # report as out of date.
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090610 3 fakebin-3
    tl update --check --tsv --offline
    expect_status "update --check --tsv" 0
    expect_out "it names the item, what you have and what there is" $'^fakebin\t2\t3\t$'
    expect_out "a config item is marked as one that asks" $'^hello\t2\t3\tconfig-asks$'
    expect_no_out "offline, an item pinned to the newest is not called out of date" $'^claude-code\t'
    expect_no_out "and nothing a person would read" "up to date"
    expect_no_out "and no packages line" "package manager"
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090603 2 fakebin-2
    tl update --check --tsv --offline
    expect_no_out "with nothing out of date the row is gone" $'^fakebin\t'
    expect_no_out "and the item pinned to the newest is not listed either" $'^claude-code\t'

    # Online, an item pinned to latest is asked about at the registry: the same
    # version is not an update, a newer one is, with its real number.
    tl update --check --tsv
    expect_status "update --check --tsv online" 0
    expect_no_out "latest at the registry is what is installed: no row" $'^claude-code\t'
    cp "$FX/registry/demo-cli/latest" "$FX/registry-demo-cli-latest.bak"
    sed 's/"version":"1.0.0"/"version":"1.1.0"/' "$FX/registry-demo-cli-latest.bak" > "$FX/registry/demo-cli/latest"
    tl update --check --tsv
    expect_out "a newer version at the registry is named with its number" $'^claude-code\t1.0.0\t1.1.0\tlatest$'
    tl update --check
    expect_out "and said in words without --tsv" "claude-code 1.1.0 is available; you have 1.0.0"
    mv "$FX/registry-demo-cli-latest.bak" "$FX/registry/demo-cli/latest"
    # An npm-android item pinned to latest is asked about the same way.
    PATCHELF_KNOB=false
    tl install droid -y
    cp "$FX/registry/demo-droid/latest" "$FX/registry-demo-droid-latest.bak"
    sed 's/"version":"3.0.0"/"version":"3.1.0"/' "$FX/registry-demo-droid-latest.bak" > "$FX/registry/demo-droid/latest"
    tl update --check --tsv
    expect_out "a newer npm-android version is named with its number" $'^droid\t3.0.0\t3.1.0\tlatest$'
    mv "$FX/registry-demo-droid-latest.bak" "$FX/registry/demo-droid/latest"
    tl update --check --tsv
    expect_no_out "and the same version is not an update" $'^droid\t'
    tl remove droid -y
    rm -rf "$FX/registry-gone"
    mv "$FX/registry" "$FX/registry-gone"
    tl update --check --tsv
    expect_no_out "an unreachable registry names nothing" $'^claude-code\t'
    mv "$FX/registry-gone" "$FX/registry"

    # --- tlstore snapshot: the whole store in one run, kept while nothing moves ---
    T=$'\t'
    SNAP_FILE="$TESTHOME/.cache/tlstore/snapshot.tsv"
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090610 3 fakebin-3
    rm -f "$SNAP_FILE"
    tl_stdout snapshot --tsv
    expect_status "snapshot --tsv" 0
    SNAP="$OUT"
    expect_out "it starts with the key of what it read" "^# tlstore snapshot${T}key=.*serial=2026090610"
    for sn in hello claude-code pictured readmepinned privbin kit plug fakebin; do
        tl_stdout info --tsv "$sn"
        got="$(printf '%s\n' "$SNAP" | grep "^field${T}${sn}${T}" | cut -f3-)"
        if [ "$got" = "$OUT" ]; then pass; else fail "snapshot's field lines for $sn are info --tsv's rows" "$(printf '%s' "$got" | head -3 | tr '\n' '|')"; fi
    done
    tl_stdout list --tsv
    got="$(printf '%s\n' "$SNAP" | grep "^item${T}" | cut -f2-)"
    if [ "$got" = "$OUT" ]; then pass; else fail "snapshot's item lines are list --tsv's rows"; fi
    tl_stdout update --check --tsv --offline
    got="$(printf '%s\n' "$SNAP" | grep "^update${T}" | cut -f2- | sort)"
    if [ "$got" = "$(printf '%s\n' "$OUT" | sort)" ]; then pass; else fail "snapshot's update lines are update --check --tsv --offline's rows" "$got"; fi
    OUT="$SNAP"
    expect_out "a cached picture is named with its path" "^cached${T}pictured${T}picture${T}$PIC_CACHE\$"
    expect_out "a cached demo too" "^cached${T}pictured${T}demo${T}$DEMO_CACHE\$"
    expect_out "a cached pinned readme" "^cached${T}readmepinned${T}readme${T}$READMEPIN_CACHE\$"
    expect_out "a cached upstream readme" "^cached${T}tagged${T}readme${T}$RM_CACHE/tagged-2.3.4.md\$"
    expect_no_out "a picture that was never fetched is not" "^cached${T}hello${T}"
    expect_no_out "nor one whose digest did not match" "^cached${T}badpic${T}"
    expect_no_out "nothing hidden is listed" "^item${T}secret${T}"
    expect_no_out "and no README picture: the UI learns those from the prefetch" "${T}asset${T}"
    expect_file "the answer is kept" "$SNAP_FILE"
    printf 'nudged\n' >> "$SNAP_FILE"
    tl_stdout snapshot --tsv
    expect_out "and served again as it is while nothing it reads has moved" "^nudged\$"
    touch -t 202001010000 "$TESTHOME/.local/share/tlstore/installed.tsv"
    tl_stdout snapshot --tsv
    expect_no_out "a change to the installed list makes a new one" "^nudged\$"
    expect_out "with the same content" "^item${T}hello${T}installed${T}"
    tl snapshot
    expect_status "snapshot without --tsv is refused" 2
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090603 2 fakebin-2

    # --- tlstore prefetch: every asset, one line each, and nothing fetched twice ---
    rm -rf "$TESTHOME/.cache/tlstore/pictures" "$TESTHOME/.cache/tlstore/readme"
    : > "$ROOT/curl.log"
    tl_stdout prefetch
    expect_status "prefetch exits 0 once every item has been seen" 0
    expect_out "a picture lands with its path" "^ready${T}pictured${T}picture${T}$PIC_CACHE\$"
    expect_out "a demo too" "^ready${T}pictured${T}demo${T}$DEMO_CACHE\$"
    expect_out "a pinned readme" "^ready${T}readmepinned${T}readme${T}$READMEPIN_CACHE\$"
    expect_out "an upstream readme" "^ready${T}tagged${T}readme${T}$RM_CACHE/tagged-2.3.4.md\$"
    expect_out "and the README's header picture, with the address it was written as" "^ready${T}tagged${T}asset${T}$RM_CACHE/tagged/v2.3.4/[0-9a-f]*\.png${T}docs/shot.png\$"
    expect_out "a picture whose digest does not match is refused" "^failed${T}badpic${T}picture${T}"
    expect_no_file "and nothing is kept for it" "$TESTHOME/.cache/tlstore/pictures/0000000000000000000000000000000000000000000000000000000000000000.jpg"
    expect_out "a demo whose digest does not match is refused" "^failed${T}baddemo${T}demo${T}"
    expect_out "a pinned readme whose digest does not match is refused" "^failed${T}readmepinnedbad${T}readme${T}"
    expect_out "a picture that cannot be fetched fails" "^failed${T}hello${T}picture${T}"
    expect_out "a readme that cannot be fetched, with no copy kept, fails" "^failed${T}nowhere${T}readme${T}"
    expect_no_out "an item with nothing to fetch says nothing" "${T}twin${T}"
    expect_no_out "an item with no upstream says nothing about a readme" "${T}kit${T}readme"
    expect_no_out "nothing but ready and failed lines" "^[^rf]"
    if [ -s "$ROOT/curl.log" ]; then pass; else fail "the first prefetch downloads"; fi
    : > "$ROOT/curl.log"
    tl_stdout prefetch
    expect_status "a second prefetch" 0
    expect_out "answers from the cache" "^ready${T}pictured${T}picture${T}$PIC_CACHE\$"
    expect_out "the readme too" "^ready${T}tagged${T}readme${T}"
    expect_out "and the readme's picture" "^ready${T}tagged${T}asset${T}"
    # badpic, baddemo and readmepinnedbad share their sources with the good
    # items, so it is the destinations (digest-named) that must not appear.
    if grep -q "$PIC_DIGEST\|$DEMO_DIGEST\|$READMEPIN_DIGEST\|demo/tagged\|demo/pinned\|demo/untagged\|demo/rolling" "$ROOT/curl.log"; then
        fail "and fetches nothing that is cached and verified" "$(head -3 "$ROOT/curl.log" | tr '\n' '|')"
    else
        pass
    fi
    # The catalog moves one picture's digest: that picture alone is fetched
    # again, and the copy the old digest named goes.
    printf 'a picture worth caching, retaken\n' > "$FX/pictured.jpg"
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090611 2 fakebin-2
    NEW_PIC_CACHE="$TESTHOME/.cache/tlstore/pictures/$(sha "$FX/pictured.jpg").jpg"
    : > "$ROOT/curl.log"
    tl_stdout prefetch
    expect_out "the moved picture lands under its new digest" "^ready${T}pictured${T}picture${T}$NEW_PIC_CACHE\$"
    expect_content "and it is the new picture" "$NEW_PIC_CACHE" "a picture worth caching, retaken"
    expect_no_file "the copy the old digest named is gone" "$PIC_CACHE"
    expect_file "the demo, unchanged, stays" "$DEMO_CACHE"
    if [ "$(grep -c "$(sha "$FX/pictured.jpg")" "$ROOT/curl.log")" = 1 ]; then pass; else fail "exactly one download, of the moved picture" "$(tr '\n' '|' < "$ROOT/curl.log")"; fi
    if grep -q "$PIC_DIGEST\|$DEMO_DIGEST\|$READMEPIN_DIGEST\|demo/tagged\|demo/pinned" "$ROOT/curl.log"; then fail "nothing else is fetched again"; else pass; fi
    printf 'a picture worth caching\n' > "$FX/pictured.jpg"
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090612 2 fakebin-2
    # Copies no item names at all go too.
    printf 'stray\n' > "$TESTHOME/.cache/tlstore/pictures/feedfacefeedface.jpg"
    mkdir -p "$TESTHOME/.cache/tlstore/readme/gone-item/HEAD"
    printf 'stray\n' > "$TESTHOME/.cache/tlstore/readme/gone-item/HEAD/x.png"
    printf 'stray\n' > "$TESTHOME/.cache/tlstore/readme/gone-item-1.md"
    printf 'stray\n' > "$TESTHOME/.cache/tlstore/readme/tagged/flat.png"
    tl_stdout prefetch
    expect_no_file "a picture no item names is removed" "$TESTHOME/.cache/tlstore/pictures/feedfacefeedface.jpg"
    expect_no_file "a gone item's readme pictures are removed" "$TESTHOME/.cache/tlstore/readme/gone-item"
    expect_no_file "and its readme" "$TESTHOME/.cache/tlstore/readme/gone-item-1.md"
    expect_no_file "a picture from before revisions had directories is removed" "$TESTHOME/.cache/tlstore/readme/tagged/flat.png"
    expect_file "a kept item's readme pictures stay" "$RM_CACHE/tagged/v2.3.4"
    expect_file "the pinned readme stays" "$READMEPIN_CACHE"
    expect_file "and the picture is back under its digest" "$PIC_CACHE"
    expect_no_file "with the retaken copy gone" "$NEW_PIC_CACHE"
    # Every fetch in the script gives up on a dead connection.
    if grep -n 'curl -f' "$TLSTORE" | grep -v -- '--connect-timeout 5' | grep -q .; then
        fail "every curl call names a connect timeout" "$(grep -n 'curl -f' "$TLSTORE" | grep -v -- '--connect-timeout 5' | head -2 | tr '\n' '|')"
    else
        pass
    fi
    if grep -n 'curl -f' "$TLSTORE" | grep -v -- '--max-time\|--speed-time' | grep -q .; then
        fail "and a cap on the whole transfer, or on a stall"
    else
        pass
    fi
    tl prefetch extra
    expect_status "prefetch takes no arguments" 2
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090603 2 fakebin-2

    # --- where a binaries: source resolves: a release asset, or a file in the repository ---
    # A bare asset is <releases>/<tag>/<asset>-aarch64; a path with a slash is
    # <raw>/<tag>/<path>. The items live in a refreshed catalog laid down for
    # this block alone, so the app's list is left as it was.
    user_catalog="$TESTHOME/.local/share/tlstore/catalog.tsv"
    saved_catalog=""
    if [ -f "$user_catalog" ]; then
        saved_catalog="$ROOT/saved-catalog.tsv"
        cp "$user_catalog" "$saved_catalog"
    fi
    mkdir -p "$(dirname "$user_catalog")"
    {
        printf '# tlstore catalog\tserial=2026090650\n'
        printf 'relbin\tbinary\t1\t*\tbinaries:relbin@1.0\t%s\t-\t-\t-\tA tool published as a release asset.\t%s\n' \
            "$(sha "$FX/rel/1.0/relbin-aarch64")" "$R5_NONE"
        printf 'relpinned\tfile\t1\t*\tfile://%s/hello.conf\t%s\t~/.config/relpinned.conf\t-\t-\tIts readme is a file in the repository at a tag.\t%s\n' \
            "$FX" "$(sha "$FX/hello.conf")" "$(r6_upstream_pinned demo/relpinned "binaries:readme/relpinned.md@1.0" "$(sha "$FX/raw/1.0/readme/relpinned.md")")"
    } > "$user_catalog"
    : > "$ROOT/curl.log"
    tl install relbin -y
    expect_status "a bare binaries: source installs from the release asset" 0
    expect_file "the release asset landed" "$TESTHOME/.local/bin/relbin"
    if grep -q "file://$FX/rel/1.0/relbin-aarch64" "$ROOT/curl.log"; then pass; else fail "binaries:relbin@1.0 resolved to <releases>/1.0/relbin-aarch64" "$(cat "$ROOT/curl.log")"; fi
    if grep -q "/bin/relbin-aarch64\|raw/1.0/relbin" "$ROOT/curl.log"; then fail "a bare asset is never read from the repository tree"; else pass; fi
    : > "$ROOT/curl.log"
    tl readme relpinned
    expect_status "a path-style binaries: source reads the file at the tag" 0
    if grep -q "file://$FX/raw/1.0/readme/relpinned.md" "$ROOT/curl.log"; then pass; else fail "binaries:readme/relpinned.md@1.0 resolved to <raw>/1.0/readme/relpinned.md" "$(cat "$ROOT/curl.log")"; fi
    if grep -q "rel/1.0/readme" "$ROOT/curl.log"; then fail "a path is never looked for among the release assets"; else pass; fi
    expect_content "the pinned copy is what was served" "$OUT" "$(cat "$FX/raw/1.0/readme/relpinned.md")"
    tl remove relbin -y
    if [ -n "$saved_catalog" ]; then mv "$saved_catalog" "$user_catalog"; else rm -f "$user_catalog"; fi

    # --- keeping tlstore itself current, with the store program that pairs with it ---
    if [ "$HAVE_MINISIGN" = 1 ]; then
        store="$TPREFIX/libexec/termux-launcher/tlstore"
        ui="$store/tlstore-ui"
        # Fixture releases, each laid out the way releases/latest/download is:
        # a newer script naming its UI's digests, the same version again, a
        # script nudged after signing, a newer script whose UI asset is not the
        # one it names, and a newer script with no UI asset at all.
        for d in new same bad badui noui; do mkdir -p "$FX/release-$d"; done
        printf '#!/bin/sh\necho the new ui\n' > "$FX/release-new/tlstore-ui-arm64-v8a"
        printf '#!/bin/sh\necho the new x86 ui\n' > "$FX/release-new/tlstore-ui-x86_64"
        sed 's/^TLSTORE_VERSION=.*/TLSTORE_VERSION=9.9/' "$TLSTORE" > "$FX/release-new/tlstore"
        printf '# the newer one\n' >> "$FX/release-new/tlstore"
        bash "$repo/scripts/embed-ui-digests.sh" "$FX/release-new" >/dev/null
        cp "$TLSTORE" "$FX/release-same/tlstore"
        cp "$FX/release-new/tlstore" "$FX/release-bad/tlstore"
        cp "$FX/release-new/tlstore" "$FX/release-badui/tlstore"
        cp "$FX/release-new/tlstore" "$FX/release-noui/tlstore"
        printf '#!/bin/sh\necho not the ui that was named\n' > "$FX/release-badui/tlstore-ui-arm64-v8a"
        for d in new same bad badui noui; do
            minisign -S -s "$ROOT/key.sec" -x "$FX/release-$d/tlstore.minisig" \
                -m "$FX/release-$d/tlstore" >/dev/null 2>&1
        done
        printf '# nudged after signing\n' >> "$FX/release-bad/tlstore"
        new_ui_digest="$(sha "$FX/release-new/tlstore-ui-arm64-v8a")"

        # The launcher's install: the script, a UI it wrote, and its marker.
        su_reset() {
            cp "$TLSTORE" "$TPREFIX/bin/tlstore"
            printf '#!/bin/sh\necho the old ui\n' > "$ui"
            chmod 755 "$ui"
            touch "$store/.installed"
            rm -f "$store/.standalone" "$store/.tlstore-ui-sha256"
        }
        su_untouched() {
            if grep -q "^# the newer one" "$TPREFIX/bin/tlstore"; then fail "$1: the old tlstore stays"; else pass; fi
            expect_content "$1: the old store program stays" "$ui" "$(printf '#!/bin/sh\necho the old ui')"
            expect_no_file "$1: no UI record is written" "$store/.tlstore-ui-sha256"
        }

        su_reset
        RELEASE_KNOB="file://$FX/release-new"; UI_KNOB="$ui"
        tl update -y
        expect_status "update inside the launcher" 0
        expect_out "it says which version is in place now" "tlstore is now version 9.9"
        if grep -q "^# the newer one" "$TPREFIX/bin/tlstore"; then pass; else fail "the newer tlstore replaced the app's copy"; fi
        expect_content "the store program moved with it" "$ui" "$(printf '#!/bin/sh\necho the new ui')"
        if [ -x "$ui" ]; then pass; else fail "the new store program is executable"; fi
        expect_content "the launcher's record of the UI names the new one" "$store/.tlstore-ui-sha256" "$new_ui_digest"
        expect_no_file "no staging file is left beside the script" "$TPREFIX/bin/tlstore.new"
        expect_no_file "no staging file is left beside the UI" "$ui.new"

        # update --check is the refresh tlstore-ui runs in the background: it
        # must never swap the files under a running UI (self-update --progress
        # does that in plain view).
        su_reset
        RELEASE_KNOB="file://$FX/release-new"; UI_KNOB="$ui"
        tl update --check
        expect_status "update --check, the UI's background refresh" 0
        expect_no_out "no longer updates tlstore itself" "tlstore is now version"
        su_untouched "update --check"

        su_reset
        RELEASE_KNOB="file://$FX/release-new"; UI_KNOB="$ui"
        tl_stdout update --check --tsv
        expect_no_out "nor under --tsv" "tlstore is now version"
        su_untouched "update --check --tsv"

        # --- self-update --check --tsv: the first thing tlstore-ui asks ---
        cur_ver="$(sed -n 's/^TLSTORE_VERSION=//p' "$TLSTORE" | head -1)"
        su_cache="$TESTHOME/.cache/tlstore"
        su_reset
        RELEASE_KNOB="file://$FX/release-new"; UI_KNOB="$ui"
        tl_stdout self-update --check --tsv
        expect_status "self-update --check --tsv, a newer release" 0
        expect_out "one self line: installed, latest, available" $'^self\t'"$cur_ver"$'\t9.9\t1$'
        expect_file "the verified script waits in the cache for the install" "$su_cache/tlstore.new"
        expect_file "with its signature" "$su_cache/tlstore.new.minisig"
        su_untouched "the check alone"

        RELEASE_KNOB="file://$FX/release-same"; UI_KNOB="$ui"
        tl_stdout self-update --check --tsv
        expect_status "self-update --check --tsv, the same version" 0
        expect_out "names it, not available" $'^self\t'"$cur_ver"$'\t'"$cur_ver"$'\t0$'
        expect_no_file "and keeps nothing in the cache" "$su_cache/tlstore.new"

        UI_KNOB="$ui"
        tl_stdout self-update --check --tsv
        expect_status "self-update --check --tsv, offline" 0
        expect_out "no version, not available" $'^self\t'"$cur_ver"$'\t-\t0$'

        RELEASE_KNOB="file://$FX/release-bad"; UI_KNOB="$ui"
        tl_stdout self-update --check --tsv
        expect_status "self-update --check --tsv, a bad signature" 0
        expect_out "no version, not available" $'^self\t'"$cur_ver"$'\t-\t0$'
        expect_no_file "a refused script is not kept" "$su_cache/tlstore.new"
        su_untouched "the check, bad signature"

        # --- self-update --progress: the stream the Installing screen reads ---
        su_reset
        RELEASE_KNOB="file://$FX/release-new"; UI_KNOB="$ui"
        tl_stdout self-update --check --tsv
        : > "$ROOT/curl.log"
        RELEASE_KNOB="file://$FX/release-new"; UI_KNOB="$ui"
        tl_stdout self-update --progress
        expect_status "self-update --progress after the check" 0
        expect_out "the item is tlstore, fetched first" $'^step\ttlstore\t[0-9]*\tfetched$'
        expect_out "signature checked" $'^step\ttlstore\t85\tsignature checked$'
        expect_out "putting files in place" $'^step\ttlstore\t92\tputting files in place$'
        expect_out "ready" $'^step\ttlstore\t100\tready$'
        expect_out "the done line names the version" $'^done\ttlstore\tok\tupdated to 9.9$'
        got=$(printf '%s\n' "$OUT" | awk -F '\t' '$1 == "step" && $2 == "tlstore" { print $3 }' | tr '\n' ' ')
        if printf '%s\n' "$got" | tr ' ' '\n' | awk 'NF && $1 + 0 <= last { bad = 1 } NF { last = $1 + 0 } END { exit bad }'; then
            pass
        else
            fail "self-update step percentages only ever grow" "$got"
        fi
        case "$got" in
            *" 80 85 92 100 ") pass ;;
            *) fail "the store program's download fills the bar to 80, then the checks and the placing" "$got" ;;
        esac
        if grep -q "release-new/tlstore.minisig" "$ROOT/curl.log"; then fail "the script the check verified is not fetched again" "$(cat "$ROOT/curl.log")"; else pass; fi
        if grep -q "release-new/tlstore-ui-arm64-v8a" "$ROOT/curl.log"; then pass; else fail "the store program is fetched" "$(cat "$ROOT/curl.log")"; fi
        expect_no_out "stdout carries no narration" "tlstore is now version"
        if grep -q "^# the newer one" "$TPREFIX/bin/tlstore"; then pass; else fail "the newer tlstore is in place"; fi
        expect_content "the store program moved with it" "$ui" "$(printf '#!/bin/sh\necho the new ui')"
        if [ -x "$ui" ]; then pass; else fail "the new store program is executable"; fi
        expect_content "the launcher's record of the UI names the new one" "$store/.tlstore-ui-sha256" "$new_ui_digest"
        expect_no_file "nothing is left in the cache" "$su_cache/tlstore.new"
        expect_no_file "no staging file is left beside the script" "$TPREFIX/bin/tlstore.new"
        expect_no_file "no staging file is left beside the UI" "$ui.new"

        su_reset
        RELEASE_KNOB="file://$FX/release-badui"; UI_KNOB="$ui"
        tl_stdout self-update --progress
        expect_status "a tampered store program fails the --progress self-update" 1
        expect_out "with a done/failed line" $'^done\ttlstore\tfailed\tthe store program that was offered does not match'
        expect_no_out "and never claims to be ready" $'^step\ttlstore\t100\tready$'
        su_untouched "--progress, tampered UI"
        expect_no_file "the refused program is not kept" "$su_cache/tlstore-ui.new"
        expect_no_file "nor the script" "$su_cache/tlstore.new"

        su_reset
        UI_KNOB="$ui"
        tl_stdout self-update --progress
        expect_status "offline, the --progress self-update fails" 1
        expect_out "and says so on the stream" $'^done\ttlstore\tfailed\t'
        su_untouched "--progress, offline"

        su_reset
        RELEASE_KNOB="file://$FX/release-same"; UI_KNOB="$ui"
        tl update -y
        expect_no_out "the same version is not installed again" "tlstore is now version"
        su_untouched "same version"

        su_reset
        RELEASE_KNOB="file://$FX/release-bad"; UI_KNOB="$ui"
        tl update -y
        expect_out "a tlstore whose signature does not cover it is refused" "not signed by the launcher"
        su_untouched "bad signature"

        su_reset
        RELEASE_KNOB="file://$FX/release-badui"; UI_KNOB="$ui"
        tl update -y
        expect_status "a tampered store program does not fail the update" 0
        expect_out "it is refused by the digest the signed script names" "does not match what tlstore 9.9 expects"
        expect_no_out "and nothing claims to be updated" "tlstore is now version"
        su_untouched "tampered UI"

        su_reset
        RELEASE_KNOB="file://$FX/release-noui"; UI_KNOB="$ui"
        tl update -y
        expect_out "a release without the store program is refused" "could not download the store program"
        su_untouched "missing UI"

        su_reset
        RELEASE_KNOB="file://$FX/release-new"; UI_KNOB="$ui"
        tl update -y --offline
        expect_no_out "offline, tlstore leaves itself alone" "tlstore is now version"
        su_untouched "offline"

        # A hand-installed tlstore on plain Termux: no store program to pair.
        su_reset
        rm -f "$ui" "$store/.installed"
        printf 'file://%s\n' "$FX" > "$store/.standalone"
        RELEASE_KNOB="file://$FX/release-new"; UI_KNOB="$ROOT/no-such-tlstore-ui"
        tl update -y
        expect_out "a standalone tlstore updates itself" "tlstore is now version 9.9"
        if grep -q "^# the newer one" "$TPREFIX/bin/tlstore"; then pass; else fail "the newer tlstore replaced the hand-installed one"; fi
        expect_no_file "no store program is put down where none was" "$ROOT/no-such-tlstore-ui"
        rm -f "$store/.installed" "$store/.standalone" "$store/.tlstore-ui-sha256" "$TPREFIX/bin/tlstore" "$ui"
    else
        skip "self-update tests" "minisign is not installed"
    fi

    # --- --progress: the machine stream tlstore-ui reads ---
    tl remove fakebin -y
    tl_stdout install fakebin --progress
    expect_status "a successful --progress install" 0
    expect_out "the fetched step" $'^step\tfakebin\t10\tfetched$'
    expect_out "the signature-checked step" $'^step\tfakebin\t60\tsignature checked$'
    expect_out "the putting-files step" $'^step\tfakebin\t90\tputting files in place$'
    expect_out "the ready step" $'^step\tfakebin\t100\tready$'
    expect_out "the done line, ok" $'^done\tfakebin\tok\tinstalled$'
    # The download reports its own share of the bar (curl's progress, up to 55),
    # and no step is reported twice or out of order.
    got=$(printf '%s\n' "$OUT" | awk -F '\t' '$1 == "step" && $2 == "fakebin" { print $3 }' | tr '\n' ' ')
    case "$got" in
        "10 "*"55 60 90 100 ") pass ;;
        *) fail "the download fills 10..55, then checksum, placing, ready" "$got" ;;
    esac
    if printf '%s\n' "$got" | tr ' ' '\n' | awk 'NF && $1 + 0 <= last { bad = 1 } NF { last = $1 + 0 } END { exit bad }'; then
        pass
    else
        fail "step percentages only ever grow" "$got"
    fi
    expect_no_out "stdout alone carries no human narration" "Installing:"
    expect_file "the item really is installed" "$TESTHOME/.local/bin/fakebin"

    # A package-manager item: what pacman prints becomes steps, and none of it
    # reaches stdout.
    tl remove demo-pkg -y
    tl_stdout install demo-pkg --progress
    expect_status "a --progress package install" 0
    got=$(printf '%s\n' "$OUT" | awk -F '\t' '$1 == "step" && $2 == "demo-pkg" { print $3 }' | tr '\n' ' ')
    case "$got" in
        "10 "[1-5][0-9]" "*"60 75 85 90 100 ") pass ;;
        *) fail "the package manager moves the bar: download, integrity, unpack, ready" "$got" ;;
    esac
    if printf '%s\n' "$got" | tr ' ' '\n' | awk 'NF && $1 + 0 <= last { bad = 1 } NF { last = $1 + 0 } END { exit bad }'; then
        pass
    else
        fail "package step percentages only ever grow" "$got"
    fi
    expect_out "the package done line, ok" $'^done\tdemo-pkg\tok\tinstalled$'
    expect_no_out "the package manager's own words stay off stdout" "checking package integrity"

    tl install badsum --progress
    expect_status "a failing --progress install still exits nonzero" 1
    expect_out "the done line, failed" $'^done\tbadsum\tfailed\tcould not install badsum$'
    expect_no_out "a failed item never claims to be ready" $'^step\tbadsum\t100\tready$'

    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090699 9 fakebin-3
    tl update --progress --offline
    expect_status "a --progress update" 0
    expect_out "the update steps stream on stdout" $'^step\tfakebin\t10\tfetched$'
    expect_out "and finish ready" $'^step\tfakebin\t100\tready$'
    expect_out "the done line for an update" $'^done\tfakebin\tok\tupdated$'
    expect_no_out "self-update never runs inside a --progress stream" "tlstore is now version"

    printf 'the users own greeting\n' > "$TESTHOME/.config/hello.conf"
    forget_state
    tl install hello --progress
    expect_status "a --progress install that would touch a config file still succeeds" 0
    expect_content "the users config is kept, never replaced" \
        "$TESTHOME/.config/hello.conf" "the users own greeting"
    expect_out "the done line says it was kept" $'^done\thello\tok\tkept your hello.conf$'
    expect_no_out "no diff leaks onto stdout" "^---"
    expect_no_out "and no replace question either" "Replace your"

    tl remove hello --progress
    expect_status "a --progress remove" 0
    expect_out "the remove steps stream too" $'^step\thello\t30\tfetched$'
    expect_out "and finish ready" $'^step\thello\t100\tready$'
    expect_out "the done line for a remove" $'^done\thello\tok\tremoved$'

    # --- retiring an item: update takes it away once its row carries
    # retired=1, or leaves an edited copy alone; install refuses it outright ---
    forget_state
    rm -rf "$TESTHOME/.config/retiree"
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090700 9 fakebin-3
    tl install retiree retiree-pkg -y
    expect_status "installing the fixture that will be retired" 0
    expect_file "the file item landed" "$TESTHOME/.config/retiree/nested/retiree.conf"
    if grep -q demo-retiree "$ROOT/pkg.log"; then pass; else fail "the pkg fixture's package was asked for"; fi

    # (c) install refuses a retired item
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090701 9 fakebin-3 1
    tl install retiree -y
    expect_status "install of a retired item fails" 1
    expect_out "and says why" "retiree was retired"

    # (e) the machine output never offers a retired item as an update (it is
    # hidden: the UI could count it but not show it); the human check says it
    tl update --check --tsv --offline
    expect_status "update --check --tsv --offline" 0
    expect_no_out "no tsv line for the retired file item" $'^retiree\t'
    expect_no_out "nor for the retired pkg item" $'^retiree-pkg\t'
    tl update --check --offline
    expect_out "the human check says it will go" "retiree was retired; update will remove it"

    # (a) update removes an unmodified retired file item, and the now-empty
    # directories it leaves behind; the pkg item just stops being tracked
    tl update -y --offline
    expect_status "update retires the fixture" 0
    expect_out "the file item was retired and removed" "retiree was retired and removed"
    expect_out "the pkg item just stops being tracked" \
        "retiree-pkg is no longer tracked; the package itself stays installed"
    expect_no_file "the shipped file is gone" "$TESTHOME/.config/retiree/nested/retiree.conf"
    expect_no_file "its now-empty directory went with it" "$TESTHOME/.config/retiree/nested"
    expect_no_file "and its now-empty parent too, up to \$HOME" "$TESTHOME/.config/retiree"
    if grep -q "$(printf '^retiree\t')" "$TESTHOME/.local/share/tlstore/installed.tsv" 2>/dev/null; then
        fail "retiree's state should have been forgotten"
    else
        pass
    fi
    if grep -q "$(printf '^retiree-pkg\t')" "$TESTHOME/.local/share/tlstore/installed.tsv" 2>/dev/null; then
        fail "retiree-pkg's state should have been forgotten"
    else
        pass
    fi

    # (b) an edited copy is kept, never overwritten or deleted — only the
    # state entry is forgotten
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090702 9 fakebin-3
    tl install retiree -y
    expect_status "reinstalling the fixture" 0
    printf 'edited by the person, never touched again\n' > "$TESTHOME/.config/retiree/nested/retiree.conf"
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090703 9 fakebin-3 1
    tl update -y --offline
    expect_status "update still succeeds on an edited copy" 0
    expect_out "it says the edited file was kept" "kept your retiree.conf — retiree was retired"
    expect_content "and the file itself is never touched" \
        "$TESTHOME/.config/retiree/nested/retiree.conf" "edited by the person, never touched again"
    if grep -q "$(printf '^retiree\t')" "$TESTHOME/.local/share/tlstore/installed.tsv" 2>/dev/null; then
        fail "retiree's state should still have been forgotten"
    else
        pass
    fi

    # (d) update --progress emits the same step/done lines a remove does, with
    # a done message of "retired"
    rm -rf "$TESTHOME/.config/retiree"
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090704 9 fakebin-3
    tl install retiree -y
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090705 9 fakebin-3 1
    tl_stdout update --progress --offline
    expect_status "a --progress retirement" 0
    expect_out "the remove-shaped steps stream" $'^step\tretiree\t30\tfetched$'
    expect_out "and finish ready" $'^step\tretiree\t100\tready$'
    expect_out "the done line says retired" $'^done\tretiree\tok\tretired$'

    # (g) snapshot (what the store UI runs on every start, when the launcher
    # has just written a new catalog) retires it quietly: no update line, a
    # clean stdout, the file gone
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090706 9 fakebin-3
    tl install retiree -y
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090707 9 fakebin-3 1
    tl_stdout snapshot --tsv
    expect_status "snapshot with a retired item installed" 0
    expect_no_out "no update line for it" $'^update\tretiree\t'
    expect_no_out "and no narration on stdout" "was retired"
    expect_no_file "snapshot retired the file" "$TESTHOME/.config/retiree/nested/retiree.conf"

    # Back to the catalog the rest of the suite expects.
    write_catalog "$TESTHOME/.local/share/tlstore/catalog.tsv" 2026090603 2 fakebin-2
    forget_state
    rm -rf "$TESTHOME/.config/retiree"

    # --- cancel: SIGTERM to the whole process group (what tlstore-ui sends
    # when the person backs out of a running --progress job) stops cleanly ---
    forget_state
    rm -rf "$TESTHOME/.config/hello.conf" "$TESTHOME/.local/bin"
    CANCEL_OUT="$ROOT/cancel.out"
    CANCEL_PART="$TESTHOME/.local/bin/.slow.part"
    : > "$CANCEL_OUT"
    set -m
    env -i \
        HOME="$TESTHOME" PATH="$RUNPATH" \
        TLSTORE_PREFIX="$TPREFIX" \
        TLSTORE_CATALOG_URL="$CATALOG_URL" \
        TLSTORE_NPM_REGISTRY="file://$FX/registry" \
        TLSTORE_ARCH=aarch64 \
        TLSTORE_PATCHELF=true \
        "${SHCMD[@]}" "$TLSTORE" install hello slow -y --progress > "$CANCEL_OUT" 2>/dev/null &
    CANCEL_PID=$!
    CANCEL_I=0
    while ! pgrep -f 'slow\.pipe' >/dev/null 2>&1 && [ "$CANCEL_I" -lt 100 ]; do
        sleep 0.05
        CANCEL_I=$((CANCEL_I + 1))
    done
    if pgrep -f 'slow\.pipe' >/dev/null 2>&1; then
        pass
    else
        fail "the slow item's download really started before the cancel was sent"
    fi
    kill -TERM -- -"$CANCEL_PID" 2>/dev/null
    wait "$CANCEL_PID" 2>/dev/null
    set +m
    CANCEL_TXT="$(cat "$CANCEL_OUT" 2>/dev/null)"
    if printf '%s' "$CANCEL_TXT" | grep -q "$(printf 'done\tslow\tfailed\tCancelled.')"; then
        pass
    else
        fail "the cancelled item gets a done/failed/Cancelled line" "$CANCEL_TXT"
    fi
    if [ -e "$CANCEL_PART" ]; then
        fail "the half-written part file was left behind"
    else
        pass
    fi
    if printf '%s' "$CANCEL_TXT" | grep -q "$(printf 'done\thello\tok')"; then
        pass
    else
        fail "an item that finished before the cancel still gets its own done line" "$CANCEL_TXT"
    fi
    tl list -i
    expect_out "the item that finished before the cancel stays installed" "hello"
    expect_no_out "the cancelled item was never recorded as installed" "slow"
    forget_state
    rm -rf "$TESTHOME/.config/hello.conf" "$TESTHOME/.local/bin"

    # --- conflicts=: refused while the package that owns the same commands is installed ---
    touch "$ROOT/have-termux-api"
    tl install shimset -y
    expect_status "an item is refused while its conflicting package is installed" 1
    expect_out "the refusal names the package" "termux-api package"
    expect_out "and says how to get out of it" "pkg uninstall termux-api"
    expect_no_file "nothing of it was installed" "$TESTHOME/.config/shimpart.conf"
    expect_no_out "the plan was never shown" "Installing:"
    tl install shimset -y --progress
    expect_status "the refusal holds for --progress too" 1
    expect_no_file "and installs nothing then either" "$TESTHOME/.config/shimpart.conf"
    rm -f "$ROOT/have-termux-api"
    tl install shimset -y
    expect_status "the same item installs once the package is gone" 0
    expect_file "and puts its part in place" "$TESTHOME/.config/shimpart.conf"
    touch "$ROOT/have-termux-api"
    tl install shimset -y
    expect_status "an item that is already installed is not refused afterwards" 0
    expect_out "it just says so" "already installed"
    rm -f "$ROOT/have-termux-api"
    tl remove shimset -y
    expect_no_file "removing it takes the part away" "$TESTHOME/.config/shimpart.conf"

    # --- the numbered picker (the only picker now; fzf is gone) ---
    rm -rf "$TESTHOME/.local/share/tlstore" "$TESTHOME/.config/hello.conf"
    CATALOG_URL="file://$FX/newer.tsv"
    STDIN_TEXT='a
n
1

'
    tl install -y
    expect_status "the picker" 0
    expect_out "the picker numbers the items" "\[ \]  1"
    expect_content "the picker installed exactly what was ticked" "$TESTHOME/.config/hello.conf" "greeting from the catalog"
    expect_no_file "the picker installed nothing else" "$TESTHOME/.local/bin/twin"
    STDIN_TEXT='

'
    tl install -y
    expect_status "picking nothing" 0
    expect_out "picking nothing installs nothing" "Nothing to install"

    rm -rf "$ROOT"
}

# ---------------------------------------------------------------------------
# The termux-api-shims scripts (shims/termux-api/*) against a fake launcherctl
# ---------------------------------------------------------------------------

# The shims are POSIX sh wrappers over `launcherctl`. Here launcherctl is a
# script on PATH that logs its arguments (one line per call, |-separated) and
# answers from files, so what each shim sends and how it maps the answer back
# is exercised for real, under whichever shell the suite is running.
shim_suite() {
    local SD="$repo/shims/termux-api"
    local R FB FD want when when2 got name args f t
    R="$(mktemp -d)"
    FB="$R/bin"
    FD="$R/fake"
    mkdir -p "$FB" "$FD"
    SHIM_SH=("$(command -v "${SHCMD[0]}")" "${SHCMD[@]:1}")
    cat > "$FB/launcherctl" <<'EOF'
#!/bin/sh
# Fake launcherctl: logs the call, answers from $FAKE_DIR/reply.<command>, fails when rc says so.
d=$FAKE_DIR
{ printf 'launcherctl'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$d/log"
if [ -e "$d/rc" ]; then
    cat "$d/err" >&2
    exit "$(cat "$d/rc")"
fi
if [ "$1 $2" = "clipboard copy" ] && [ $# -eq 2 ]; then cat > "$d/stdin"; fi
[ -e "$d/reply.$1" ] && cat "$d/reply.$1"
exit 0
EOF
    chmod +x "$FB/launcherctl"
    printf 'a picture\n' > "$R/pic.png"

    fake_reset() { rm -rf "$FD"; mkdir -p "$FD"; }
    fake_reply() { printf '%s' "$2" > "$FD/reply.$1"; }
    fake_fail() { printf '%s\n' "$2" > "$FD/err"; printf '%s' "$1" > "$FD/rc"; }
    # shim <name> [args...] — OUT is stdout, ERR stderr, ST the status. stdin is $SHIM_IN when
    # set, else empty; SHIM_CWD runs it from another directory; SHIM_PATH replaces PATH.
    shim() {
        local name="$1"
        shift
        local in="${SHIM_IN:-/dev/null}" path="${SHIM_PATH:-$FB:/usr/bin:/bin}"
        (
            [ -z "${SHIM_CWD:-}" ] || cd "$SHIM_CWD" || exit 99
            env -i PATH="$path" HOME="$R" TZ=UTC TMPDIR="$R" FAKE_DIR="$FD" \
                "${SHIM_SH[@]}" "$SD/$name" "$@" < "$in" > "$R/out" 2> "$R/err"
        )
        ST=$?
        OUT="$(cat "$R/out")"
        ERR="$(cat "$R/err")"
        SHIM_IN=""; SHIM_CWD=""; SHIM_PATH=""
    }
    last_call() { tail -1 "$FD/log" 2>/dev/null; }
    expect_call() {
        local got
        got="$(last_call)"
        if [ "$got" = "$2" ]; then pass; else fail "$1" "launcherctl was called as '$got', expected '$2'"; fi
    }
    expect_stdout() {
        if [ "$OUT" = "$2" ]; then pass; else fail "$1" "stdout was '$OUT', expected '$2'"; fi
    }
    # expect_bytes <label> <printf format> — stdout is exactly that, byte for byte (no newline added).
    expect_bytes() {
        # shellcheck disable=SC2059
        printf "$2" > "$R/want"
        if cmp -s "$R/out" "$R/want"; then pass; else fail "$1" "stdout was $(od -An -c "$R/out" | tr -s ' ' | head -3 | tr '\n' ' ')"; fi
    }
    expect_err() {
        if printf '%s' "$ERR" | grep -q -- "$2"; then pass; else fail "$1" "stderr was '$ERR', expected it to match: $2"; fi
    }
    expect_no_err() {
        if printf '%s' "$ERR" | grep -q -- "$2"; then fail "$1" "stderr should not match: $2 (it was '$ERR')"; else pass; fi
    }

    # --- every shim: no launcherctl, launcherctl failing ---
    for name in termux-clipboard-get termux-clipboard-set termux-notification termux-notification-remove \
        termux-notification-list termux-toast termux-vibrate termux-torch termux-battery-status \
        termux-volume termux-wallpaper; do
        case "$name" in
            termux-notification) args="-t x" ;;
            termux-notification-remove) args="7" ;;
            termux-toast) args="hi" ;;
            termux-torch) args="on" ;;
            termux-clipboard-set) args="text" ;;
            termux-wallpaper) args="-f $R/pic.png" ;;
            *) args="" ;;
        esac
        fake_reset
        # shellcheck disable=SC2086
        SHIM_PATH="/usr/bin:/bin" shim "$name" $args
        expect_status "$name without launcherctl exits non-zero" 1
        expect_err "$name says launcherctl is missing" "launcherctl not found"
        expect_err "$name names the app it needs" "Termux Launcher"
        fake_reset
        fake_fail 1 "launcherctl: missing /home/x/.launcherctl/token; start Termux Launcher first"
        # shellcheck disable=SC2086
        shim "$name" $args
        expect_status "$name exits non-zero when the API is not up" 1
        expect_err "$name passes launcherctl's reason on" "start Termux Launcher first"
        expect_stdout "$name prints nothing to stdout on failure" ""
    done

    # --- termux-clipboard-get: plain text, JSON escapes undone ---
    fake_reset
    fake_reply clipboard '{"ok":true,"text":"hello world"}'
    shim termux-clipboard-get
    expect_status "clipboard-get" 0
    expect_call "clipboard-get asks launcherctl to paste" "launcherctl|clipboard|paste"
    expect_bytes "clipboard-get prints plain text, no JSON and no added newline" 'hello world'
    fake_reply clipboard '{"ok":true,"text":"a\nb\t\"q\" \\ é 😀 c\n"}'
    shim termux-clipboard-get
    expect_bytes "clipboard-get decodes newlines, tabs, quotes, backslashes, accents and emoji" \
        'a\nb\t"q" \\ \303\251 \360\237\230\200 c\n'
    fake_reply clipboard '{"ok":true,"text":"100% \\n %s \\0101 done"}'
    shim termux-clipboard-get
    expect_bytes "clipboard-get leaves percent signs and backslash sequences in the text alone" \
        '100%% \\n %%s \\0101 done'
    fake_reply clipboard '{"ok":true,"text":"é café ünï"}'
    shim termux-clipboard-get
    expect_bytes "clipboard-get passes raw UTF-8 through" '\303\251 caf\303\251 \303\274n\303\257'
    fake_reply clipboard '{"ok":true,"text":""}'
    shim termux-clipboard-get
    expect_bytes "clipboard-get prints nothing for an empty clipboard" ''
    shim termux-clipboard-get extra
    expect_status "clipboard-get takes no arguments" 1
    fake_reset
    fake_fail 1 '{"error":{"code":"launcher_not_visible"}}'
    shim termux-clipboard-get
    expect_status "clipboard-get fails when the launcher is off screen" 1
    expect_err "and passes the server's code on" "launcher_not_visible"

    # --- termux-clipboard-set: arguments or stdin ---
    fake_reset
    fake_reply clipboard '{"ok":true,"length":3}'
    shim termux-clipboard-set some words "and more"
    expect_status "clipboard-set with arguments" 0
    expect_call "clipboard-set joins its arguments with spaces" "launcherctl|clipboard|copy|some words and more"
    expect_stdout "clipboard-set prints nothing on success" ""
    fake_reset
    printf 'from stdin\nline two\n' > "$R/in.txt"
    SHIM_IN="$R/in.txt" shim termux-clipboard-set
    expect_status "clipboard-set from stdin" 0
    expect_call "clipboard-set with no arguments lets launcherctl read stdin" "launcherctl|clipboard|copy"
    expect_content "clipboard-set forwards stdin whole" "$FD/stdin" "$(printf 'from stdin\nline two\n')"

    # --- termux-notification ---
    fake_reset
    fake_reply notify '{"ok":true,"shown":true}'
    shim termux-notification -t Title -c "Body text" -i 7 --priority high
    expect_status "notification" 0
    expect_call "notification maps title, content, id and priority" \
        "launcherctl|notify|--title|Title|--id|7|--urgency|critical|--|Body text"
    expect_stdout "notification prints nothing on success" ""
    expect_no_err "notification with supported flags warns about nothing" "ignoring"
    shim termux-notification --title=T2 --content=B2 --id=x --priority=low
    expect_call "notification takes --opt=value" "launcherctl|notify|--title|T2|--id|x|--urgency|low|--|B2"
    shim termux-notification -tT3 -cB3 --priority default
    expect_call "notification takes -tVALUE and maps default" "launcherctl|notify|--title|T3|--urgency|normal|--|B3"
    shim termux-notification -c "-starts with a dash"
    expect_call "notification protects a body that starts with a dash" "launcherctl|notify|--|-starts with a dash"
    printf 'piped body\nsecond line\n' > "$R/in.txt"
    SHIM_IN="$R/in.txt" shim termux-notification -t FromStdin
    got="$(tail -2 "$FD/log")"
    want="launcherctl|notify|--title|FromStdin|--|piped body
second line"
    if [ "$got" = "$want" ]; then pass; else fail "notification reads content from stdin, trimming the last newline" "log was '$got'"; fi
    SHIM_IN="$R/in.txt" shim termux-notification -t T -c "arg wins"
    expect_call "notification content argument beats stdin" "launcherctl|notify|--title|T|--|arg wins"
    shim termux-notification \
        --button1 Yes --button1-action "termux-toast yes" --button2=No --action "true" --on-delete "true" \
        --ongoing --alert-once --sound --led-color ff0000 --led-on 100 --led-off 100 --vibrate 100,200 \
        --image-path /tmp/x.png --icon foo --group g --channel c --type media --media-play "true" \
        -t Kept -c Body
    expect_status "notification does not fail on options it cannot honour" 0
    expect_call "notification still sends what it can" "launcherctl|notify|--title|Kept|--|Body"
    for f in --button1 --button1-action --button2 --action --on-delete --ongoing --alert-once --sound \
        --led-color --led-on --led-off --vibrate --image-path --icon --group --channel "--type media" --media-play; do
        expect_err "notification warns about $f" "termux-notification: ignoring unsupported option $f\$"
    done
    shim termux-notification --type default -t T -c B
    expect_no_err "notification --type default is not a warning" "ignoring"
    shim termux-notification -c "no title"
    expect_call "notification works with content alone" "launcherctl|notify|--|no title"
    shim termux-notification
    expect_status "notification with nothing to show fails" 1
    shim termux-notification --nonsense
    expect_status "notification rejects an option upstream does not have" 1
    expect_err "and names it" "unrecognized option '--nonsense'"
    shim termux-notification -t
    expect_status "notification -t with no value fails" 1
    shim termux-notification -t T -c B stray
    expect_status "notification with a stray argument fails" 1

    # --- termux-notification-remove ---
    fake_reset
    fake_reply notify '{"ok":true}'
    shim termux-notification-remove 7
    expect_status "notification-remove" 0
    expect_call "notification-remove closes by id" "launcherctl|notify|--close|7"
    shim termux-notification-remove
    expect_status "notification-remove needs an id" 1
    expect_err "notification-remove says so" "no notification id specified"

    # --- termux-toast ---
    fake_reset
    shim termux-toast hello world
    expect_status "toast" 0
    expect_call "toast joins its arguments" "launcherctl|toast|--|hello world"
    shim termux-toast -s brief
    expect_call "toast -s is the short toast" "launcherctl|toast|--short|--|brief"
    shim termux-toast -g top -c red -b blue tinted
    expect_status "toast accepts -g -c -b" 0
    expect_call "toast sends the text without them" "launcherctl|toast|--|tinted"
    expect_err "toast warns about -g" "termux-toast: ignoring unsupported option -g\$"
    expect_err "toast warns about -c" "termux-toast: ignoring unsupported option -c\$"
    expect_err "toast warns about -b" "termux-toast: ignoring unsupported option -b\$"
    printf 'from stdin\n' > "$R/in.txt"
    SHIM_IN="$R/in.txt" shim termux-toast
    expect_call "toast reads stdin when it has no text" "launcherctl|toast|--|from stdin"
    shim termux-toast
    expect_status "toast with no text fails" 1

    # --- termux-vibrate ---
    fake_reset
    shim termux-vibrate
    expect_status "vibrate" 0
    expect_call "vibrate with no options leaves the default to launcherctl" "launcherctl|vibrate"
    shim termux-vibrate -d 300 -f
    expect_call "vibrate -d and -f" "launcherctl|vibrate|-d|300|--force"
    shim termux-vibrate -f
    expect_call "vibrate -f alone" "launcherctl|vibrate|--force"
    shim termux-vibrate -d abc
    expect_status "vibrate rejects a duration that is not a number" 1
    shim termux-vibrate -x
    expect_status "vibrate rejects an unknown option" 1

    # --- termux-torch ---
    fake_reset
    shim termux-torch on
    expect_call "torch on" "launcherctl|torch|on"
    shim termux-torch off
    expect_call "torch off" "launcherctl|torch|off"
    shim termux-torch maybe
    expect_status "torch rejects anything else" 1
    shim termux-torch
    expect_status "torch needs an argument" 1

    # --- termux-battery-status: upstream's field names and layout ---
    fake_reset
    fake_reply battery '{"health":"GOOD","percentage":87,"plugged":"UNPLUGGED","status":"DISCHARGING","temperature":29.5,"current":-312000}'
    shim termux-battery-status
    expect_status "battery-status" 0
    expect_call "battery-status asks for the battery" "launcherctl|battery"
    want='{
  "health": "GOOD",
  "percentage": 87,
  "plugged": "UNPLUGGED",
  "status": "DISCHARGING",
  "temperature": 29.5,
  "current": -312000
}'
    expect_stdout "battery-status prints upstream's object, two-space indented" "$want"
    fake_reply battery '{
  "ok": true,
  "health": "COLD",
  "percentage": 100,
  "plugged": "PLUGGED_AC",
  "status": "FULL",
  "temperature": 12.0,
  "current": 0
}'
    shim termux-battery-status
    want='{
  "health": "COLD",
  "percentage": 100,
  "plugged": "PLUGGED_AC",
  "status": "FULL",
  "temperature": 12.0,
  "current": 0
}'
    expect_stdout "battery-status reads a pretty-printed answer too, and drops ok" "$want"
    fake_reply battery 'not json'
    shim termux-battery-status
    expect_status "battery-status fails on an answer it cannot read" 1

    # --- termux-volume: a top-level array, streams unwrapped ---
    fake_reset
    fake_reply volume '{"ok":true,"streams":[{"stream":"call","volume":5,"max_volume":5},{"stream":"music","volume":7,"max_volume":15},{"stream":"ring","volume":0,"max_volume":7}]}'
    shim termux-volume
    expect_status "volume" 0
    expect_call "volume with no arguments lists the streams" "launcherctl|volume"
    want='[
  {
    "stream": "call",
    "volume": 5,
    "max_volume": 5
  },
  {
    "stream": "music",
    "volume": 7,
    "max_volume": 15
  },
  {
    "stream": "ring",
    "volume": 0,
    "max_volume": 7
  }
]'
    expect_stdout "volume prints a top-level array, not the streams wrapper" "$want"
    fake_reply volume '{"ok":true,"streams":[]}'
    shim termux-volume
    expect_stdout "volume with no streams prints an empty array" "[]"
    fake_reset
    shim termux-volume music 7
    expect_status "volume set" 0
    expect_call "volume STREAM VALUE sets it" "launcherctl|volume|music|7"
    expect_stdout "volume set prints nothing, as upstream does" ""
    shim termux-volume music loud
    expect_status "volume rejects a value that is not a number" 1
    shim termux-volume music
    expect_status "volume rejects one argument" 1

    # --- termux-notification-list: upstream's fields, mapped from launcherctl ---
    fake_reset
    fake_reply notifications '{"ok":true,"count":2,"notifications":[{"id":9,"time":1790000000000,"timeIso":"2026-09-21T14:13:20Z","package":"com.example.chat","app":"Chat","conversation":null,"title":"Ann \"A\"","sender":null,"text":"Lunch, }{ at 12?","subText":null,"category":"msg","channel":"c1","key":"0|com.example.chat|42|null|10123","postTime":1790000000000,"removedTime":null},{"time":1790003600000,"timeIso":"2026-09-21T15:13:20Z","package":"com.example.mail","app":"Mail","conversation":"Inbox","title":null,"sender":"Bo","text":"café \\ done","subText":null,"category":null,"channel":"m","key":"0|com.example.mail|7|thread-1|10099","postTime":1790003600000,"removedTime":null}]}'
    shim termux-notification-list
    expect_status "notification-list" 0
    expect_call "notification-list asks for the active notifications as JSON" "launcherctl|notifications|active|--json"
    when=$(date -u -d @1790000000 '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)
    when2=$(date -u -d @1790003600 '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)
    if [ -z "$when" ]; then
        skip "notification-list maps the fields" "date -d @seconds is not available here"
    else
        want='[
  {
    "id": 42,
    "tag": "",
    "key": "0|com.example.chat|42|null|10123",
    "group": "",
    "packageName": "com.example.chat",
    "title": "Ann \"A\"",
    "content": "Lunch, }{ at 12?",
    "when": "'"$when"'"
  },
  {
    "id": 7,
    "tag": "thread-1",
    "key": "0|com.example.mail|7|thread-1|10099",
    "group": "",
    "packageName": "com.example.mail",
    "title": "",
    "content": "café \\ done",
    "when": "'"$when2"'"
  }
]'
        expect_stdout "notification-list prints upstream's fields, id and tag from the key, escapes intact" "$want"
    fi
    fake_reply notifications '{"ok":true,"count":0,"notifications":[],"hint":"Notification access is not granted."}'
    shim termux-notification-list
    expect_status "notification-list with nothing to list" 0
    expect_stdout "notification-list prints an empty array" "[]"
    expect_err "and says why on stderr" "Notification access is not granted"
    fake_reply notifications '{"ok":true,"count":0,"notifications":[]}'
    shim termux-notification-list
    expect_stdout "notification-list with no hint prints just the array" "[]"
    expect_no_err "and says nothing" "notification-list:"
    fake_reply notifications 'nope'
    shim termux-notification-list
    expect_status "notification-list fails on an answer it cannot read" 1

    # --- termux-wallpaper ---
    fake_reset
    shim termux-wallpaper -f "$R/pic.png"
    expect_status "wallpaper -f" 0
    expect_call "wallpaper -f sets the home screen" "launcherctl|wallpaper|set|$R/pic.png|--home"
    shim termux-wallpaper -l -f "$R/pic.png"
    expect_call "wallpaper -l sets the lock screen" "launcherctl|wallpaper|set|$R/pic.png|--lock"
    SHIM_CWD="$R" shim termux-wallpaper -f pic.png
    expect_call "wallpaper makes a relative path absolute" "launcherctl|wallpaper|set|$R/pic.png|--home"
    shim termux-wallpaper -f "$R/missing.png"
    expect_status "wallpaper -f with no such file fails" 1
    shim termux-wallpaper
    expect_status "wallpaper needs -f or -u" 1
    shim termux-wallpaper -f "$R/pic.png" -u "file://$R/pic.png"
    expect_status "wallpaper refuses -f with -u" 1
    fake_reset
    shim termux-wallpaper -u "file://$R/pic.png"
    expect_status "wallpaper -u downloads then sets" 0
    got="$(last_call)"
    case "$got" in
        "launcherctl|wallpaper|set|$R/termux-wallpaper."*"|--home") pass ;;
        *) fail "wallpaper -u hands launcherctl the downloaded file" "call was '$got'" ;;
    esac
    if ls "$R"/termux-wallpaper.* >/dev/null 2>&1; then fail "wallpaper -u cleans up its download"; else pass; fi
    mkdir -p "$R/nocurl"
    for t in mktemp rm; do ln -sf "$(command -v $t)" "$R/nocurl/$t"; done
    ln -sf "$FB/launcherctl" "$R/nocurl/launcherctl"
    SHIM_PATH="$R/nocurl" shim termux-wallpaper -u "file://$R/pic.png"
    expect_status "wallpaper -u without curl fails" 1
    expect_err "and says it needs curl" "needs curl"
    fake_reset
    fake_fail 2 "launcherctl supports: launch, pane, window, agent, notify, progress, clipboard"
    shim termux-wallpaper -f "$R/pic.png"
    expect_status "wallpaper on a launcher without the command fails" 1
    expect_err "and says to update the app" "update the app"

    # --- help text ---
    fake_reset
    for name in termux-clipboard-get termux-clipboard-set termux-notification termux-notification-remove \
        termux-notification-list termux-toast termux-vibrate termux-battery-status termux-volume; do
        shim "$name" -h
        expect_status "$name -h exits 0" 0
        if printf '%s' "$OUT" | grep -q "sage"; then pass; else fail "$name -h prints a usage line" "stdout was '$OUT'"; fi
    done

    rm -rf "$R"
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
    shim_suite
    if [ "$FAIL" = "$before_fail" ]; then
        echo "   all checks passed"
    fi
done

echo
# ---------------------------------------------------------------------------
# Backward compatibility: a phone's already-installed tlstore against the new
# catalog. New columns only ever land at the end (see the TSV contract in
# docs/REVISION-5.md; Revision 6 added readme-skip the same
# way), so the script already on dev, unchanged, must still read this
# worktree's catalog shape.
# ---------------------------------------------------------------------------

echo "== the dev-branch tlstore reads the new catalog"
OLD_TLSTORE="$(mktemp)"
if git -C "$repo" show dev:dist/tlstore > "$OLD_TLSTORE" 2>/dev/null; then
    SHELL_LABEL="dev-branch tlstore"
    build_fixture
    CATALOG_URL="file://$FX/newer.tsv"
    old_env() {
        env -i HOME="$TESTHOME" PATH="$RUNPATH" \
            TLSTORE_PREFIX="$TPREFIX" TLSTORE_CATALOG_URL="$CATALOG_URL" \
            TLSTORE_ARCH=aarch64 TLSTORE_PATCHELF=true \
            /bin/sh "$OLD_TLSTORE" "$@" 2>&1
    }
    OUT="$(old_env list)"; ST=$?
    expect_status "its list command still exits 0 against this catalog" 0
    expect_out "and still shows an item from it" "hello"
    OUT="$(old_env info hello)"; ST=$?
    expect_status "its info command still works" 0
    expect_out "and still reads the summary, unaware of the columns after it" \
        "A greeting you can read."
    mkdir -p "$TESTHOME/.config"
    OUT="$(old_env install hello -y)"; ST=$?
    expect_status "it can still install an item from the new catalog" 0
    expect_file "the file landed" "$TESTHOME/.config/hello.conf"
    rm -rf "$ROOT"
else
    skip "dev-branch compatibility check" "no dev branch reachable from this worktree"
fi
rm -f "$OLD_TLSTORE"

echo
echo "== build-catalog.sh"
SHELL_LABEL=build-catalog
BC_ROOT="$(mktemp -d)"
mkdir -p "$BC_ROOT/scripts/pictures" "$BC_ROOT/dist"
cp "$repo/scripts/build-catalog.sh" "$BC_ROOT/scripts/build-catalog.sh"
printf 'a fake picture\n' > "$BC_ROOT/scripts/pictures/demo.jpg"
BC_PIC_DIGEST="$(sha "$BC_ROOT/scripts/pictures/demo.jpg")"
# A launcher: source is hashed at its ref in a launcher checkout (TLSTORE_LAUNCHER_REPO): a
# throwaway repo whose tag abc123 holds the picture.
BC_LAUNCHER="$(mktemp -d)"
mkdir -p "$BC_LAUNCHER/scripts/pictures"
cp "$BC_ROOT/scripts/pictures/demo.jpg" "$BC_LAUNCHER/scripts/pictures/demo.jpg"
git -C "$BC_LAUNCHER" init -q
git -C "$BC_LAUNCHER" add -A
git -C "$BC_LAUNCHER" -c user.name=t -c user.email=t@t commit -qm fixture
git -C "$BC_LAUNCHER" tag abc123
export TLSTORE_LAUNCHER_REPO="$BC_LAUNCHER"
BC_SUMS="$BC_ROOT/SHA256SUMS"
# One bare asset (looked up as "<asset>-aarch64", as always) and one path
# asset (a pinned readme, looked up by its exact repo-relative path — the
# pinned-content addendum's binaries: rule).
printf '1111111111111111111111111111111111111111111111111111111111111111  demo-aarch64\n' > "$BC_SUMS"
printf '3333333333333333333333333333333333333333333333333333333333333333  readme/demo.md\n' >> "$BC_SUMS"

# bc_write_items <items.tsv path> <featured 0|1> <category>
bc_write_items() {
    printf 'demo\tbinary\t1\t*\tbinaries:demo@1.0\t-\t-\t-\tA demo item.\t%s\tdemo/demo\t0\ta demo item for testing\tShows a demo\tDoes another thing\tDoes one more thing\tdemo\t-\tDemo Author\tMIT\t-\tlauncher:scripts/pictures/demo.jpg@abc123\t-\t%s\tPortability|Star history\tbinaries:readme/demo.md@1.0\n' \
        "$3" "$2" > "$1"
    printf 'part\tpkg\t-\t*\tdemo-pkg\t-\t-\thidden=1\tA hidden part.\t-\t-\t0\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t0\t-\t-\n' >> "$1"
}

bc_items="$BC_ROOT/scripts/items.tsv"
bc_cat="$BC_ROOT/dist/catalog.tsv"

bc_write_items "$bc_items" 1 Tools
OUT="$(cd "$BC_ROOT" && bash scripts/build-catalog.sh "$BC_SUMS" 2>&1)"; ST=$?
if [ "$ST" = 0 ]; then pass; else fail "build-catalog.sh runs against a Revision 6 items.tsv" "$OUT"; fi
if [ -f "$bc_cat" ]; then pass; else fail "it writes the catalog"; fi
if awk -F'\t' 'NR==3 { exit (NF == 30 && $27 == "readme-skip" && $28 == "readme" && $29 == "readme-digest" && $30 == "demo-digest") ? 0 : 1 }' "$bc_cat"; then pass; else fail "the header row has 30 columns, readme/readme-digest/demo-digest last"; fi
if awk -F'\t' '$1=="demo" { exit ($27=="Portability|Star history") ? 0 : 1 }' "$bc_cat"; then
    pass
else
    fail "readme-skip rides through unchanged"
fi
if awk -F'\t' -v want="3333333333333333333333333333333333333333333333333333333333333333" '$1=="demo" { exit ($28=="binaries:readme/demo.md@1.0" && $29==want) ? 0 : 1 }' "$bc_cat"; then
    pass
else
    fail "a path-style binaries: source resolves by its exact repo-relative path in SHA256SUMS"
fi
if awk -F'\t' '$1=="demo" { exit ($30=="-") ? 0 : 1 }' "$bc_cat"; then
    pass
else
    fail "an item with no demo carries - for demo-digest"
fi
if awk -F'\t' '$1=="part" { exit (NF == 30 && $27=="-" && $28=="-" && $29=="-" && $30=="-") ? 0 : 1 }' "$bc_cat"; then
    pass
else
    fail "a part carries - for readme-skip, readme, readme-digest and demo-digest"
fi
# The very catalog build-catalog.sh wrote, read back by this worktree's tlstore:
# the last columns come out of info --tsv under their own keys.
bc_prefix="$BC_ROOT/data/data/com.termux/files/usr"
mkdir -p "$BC_ROOT/home" "$bc_prefix/libexec/termux-launcher/tlstore"
cp "$bc_cat" "$bc_prefix/libexec/termux-launcher/tlstore/catalog.tsv"
OUT="$(env -i HOME="$BC_ROOT/home" PATH="/usr/bin:/bin" TLSTORE_PREFIX="$bc_prefix" \
    TLSTORE_ARCH=aarch64 /bin/sh "$TLSTORE" info --tsv demo 2>&1)"; ST=$?
if [ "$ST" = 0 ]; then pass; else fail "tlstore reads the catalog build-catalog.sh wrote" "$OUT"; fi
if printf '%s' "$OUT" | grep -q $'^Readme-skip\tPortability|Star history$'; then pass; else fail "and info --tsv prints Readme-skip from it" "$OUT"; fi
if printf '%s' "$OUT" | grep -q $'^Readme\tbinaries:readme/demo.md@1.0$'; then pass; else fail "and info --tsv prints the pinned readme source" "$OUT"; fi
if printf '%s' "$OUT" | grep -q $'^Readme-digest\t3333333333333333333333333333333333333333333333333333333333333333$'; then pass; else fail "and its digest alongside it" "$OUT"; fi
if awk -F'\t' -v want="$BC_PIC_DIGEST" '$1=="demo" { exit ($24==want) ? 0 : 1 }' "$bc_cat"; then
    pass
else
    fail "the picture's digest was computed the same way the item's own is"
fi
if awk -F'\t' '$1=="demo" { exit ($11=="Tools" && $26=="1") ? 0 : 1 }' "$bc_cat"; then
    pass
else
    fail "category and featured round-trip into the catalog"
fi

printf 'demo\tbinary\t1\t*\tbinaries:demo@1.0\t-\t-\t-\tA demo item.\tTools\n' > "$bc_items"
OUT="$(cd "$BC_ROOT" && bash scripts/build-catalog.sh "$BC_SUMS" 2>&1)"; ST=$?
if [ "$ST" != 0 ]; then pass; else fail "a row missing the Revision 5 columns is refused"; fi

printf 'demo\tbinary\t1\t*\tbinaries:demo@1.0\t-\t-\t-\tA demo item.\tTools\tdemo/demo\t0\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t1\n' > "$bc_items"
OUT="$(cd "$BC_ROOT" && bash scripts/build-catalog.sh "$BC_SUMS" 2>&1)"; ST=$?
if [ "$ST" != 0 ]; then pass; else fail "a Revision 5 row, without readme-skip, is refused"; fi

printf 'demo\tbinary\t1\t*\tbinaries:demo@1.0\t-\t-\t-\tA demo item.\tTools\tdemo/demo\t0\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t1\t-\n' > "$bc_items"
OUT="$(cd "$BC_ROOT" && bash scripts/build-catalog.sh "$BC_SUMS" 2>&1)"; ST=$?
if [ "$ST" != 0 ]; then pass; else fail "a Revision 6 row, without the pinned-content readme column, is refused"; fi

bc_write_items "$bc_items" 1 Nonsense
OUT="$(cd "$BC_ROOT" && bash scripts/build-catalog.sh "$BC_SUMS" 2>&1)"; ST=$?
if [ "$ST" != 0 ]; then pass; else fail "an unknown category is refused"; fi

bc_write_items "$bc_items" 0 Tools
OUT="$(cd "$BC_ROOT" && bash scripts/build-catalog.sh "$BC_SUMS" 2>&1)"; ST=$?
if [ "$ST" != 0 ]; then pass; else fail "no item at all being featured is refused"; fi

rm -rf "$BC_ROOT"

echo
echo "== embed-ui-digests.sh, bins-plan.sh, bins-record.sh"
SHELL_LABEL=bins
BN_ROOT="$(mktemp -d)"
mkdir -p "$BN_ROOT/scripts" "$BN_ROOT/dist" "$BN_ROOT/assets"
cp "$repo/scripts/embed-ui-digests.sh" "$repo/scripts/bins-plan.sh" "$repo/scripts/bins-record.sh" "$BN_ROOT/scripts/"

# --- embed-ui-digests.sh: the signed script names the UI built beside it ---
cp "$TLSTORE" "$BN_ROOT/dist/tlstore"
printf 'the arm64 ui\n' > "$BN_ROOT/dist/tlstore-ui-arm64-v8a"
printf 'the x86_64 ui\n' > "$BN_ROOT/dist/tlstore-ui-x86_64"
if grep -qx 'TLSTORE_UI_SHA256_arm64_v8a=' "$TLSTORE" && grep -qx 'TLSTORE_UI_SHA256_x86_64=' "$TLSTORE"; then pass; else fail "engine/tlstore carries the two empty placeholder lines"; fi
OUT="$(bash "$BN_ROOT/scripts/embed-ui-digests.sh" "$BN_ROOT/dist" 2>&1)"; ST=$?
expect_status "embed-ui-digests.sh fills both lines in" 0
if grep -qx "TLSTORE_UI_SHA256_arm64_v8a=$(sha "$BN_ROOT/dist/tlstore-ui-arm64-v8a")" "$BN_ROOT/dist/tlstore"; then pass; else fail "the arm64-v8a line is that file's sha256"; fi
if grep -qx "TLSTORE_UI_SHA256_x86_64=$(sha "$BN_ROOT/dist/tlstore-ui-x86_64")" "$BN_ROOT/dist/tlstore"; then pass; else fail "the x86_64 line is that file's sha256"; fi
if [ "$(grep -c '^TLSTORE_UI_SHA256_' "$BN_ROOT/dist/tlstore")" = 2 ]; then pass; else fail "only the two placeholder lines carry a digest"; fi
if sh -n "$BN_ROOT/dist/tlstore" 2>/dev/null; then pass; else fail "the script is still a script afterwards"; fi
if [ "$(grep -vc '^TLSTORE_UI_SHA256_' "$BN_ROOT/dist/tlstore")" = "$(grep -vc '^TLSTORE_UI_SHA256_' "$TLSTORE")" ]; then pass; else fail "nothing else in the script changed"; fi
OUT="$(bash "$BN_ROOT/scripts/embed-ui-digests.sh" --check "$BN_ROOT/dist" 2>&1)"; ST=$?
expect_status "--check passes for the binaries it was filled from" 0
printf 'rebuilt since\n' >> "$BN_ROOT/dist/tlstore-ui-x86_64"
OUT="$(bash "$BN_ROOT/scripts/embed-ui-digests.sh" --check "$BN_ROOT/dist" 2>&1)"; ST=$?
if [ "$ST" != 0 ]; then pass; else fail "--check refuses a UI that changed after the digests were written"; fi
expect_out "and says which one" "tlstore-ui-x86_64"

# --- bins-plan.sh: the build matrix ---
OUT="$(bash "$BN_ROOT/scripts/bins-plan.sh" all 2>&1)"; ST=$?
expect_status "bins-plan.sh all" 0
expect_out "a per-edition tool gets a job per edition" '{"tool":"dawn","edition":"io.vaj.tl","asset":"dawn-io.vaj.tl-aarch64"}'
expect_out "with the unsuffixed asset for com.termux" '{"tool":"dawn","edition":"com.termux","asset":"dawn-aarch64"}'
expect_out "an edition-agnostic tool gets one job" '{"tool":"btop","edition":"-","asset":"btop-aarch64"}'
expect_out "the musl runtime is one job for two assets" '"asset":"musl-libgcc-aarch64,musl-libstdcxx-aarch64"'
if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if len(d["include"]) == 11 else 1)'; then pass; else fail "the matrix is JSON with eleven entries" "$OUT"; fi
fi
OUT="$(bash "$BN_ROOT/scripts/bins-plan.sh" dawn,btop 2>&1)"; ST=$?
expect_status "bins-plan.sh with a comma list" 0
if [ "$(printf '%s' "$OUT" | grep -o '"tool"' | wc -l)" = 3 ]; then pass; else fail "dawn,btop is three jobs" "$OUT"; fi
OUT="$(bash "$BN_ROOT/scripts/bins-plan.sh" nonsense 2>&1)"; ST=$?
expect_status "an unknown tool is refused" 2

# --- bins-record.sh: SHA256SUMS lines and items.tsv tags after a build ---
printf 'built dawn\n' > "$BN_ROOT/assets/dawn-aarch64"
printf 'built dawn for vaj\n' > "$BN_ROOT/assets/dawn-io.vaj.tl-aarch64"
printf 'built btop\n' > "$BN_ROOT/assets/btop-aarch64"
{
    printf '1111111111111111111111111111111111111111111111111111111111111111  dawn-aarch64\n'
    printf '%s  btop-aarch64\n' "$(sha "$BN_ROOT/assets/btop-aarch64")"
    printf '2222222222222222222222222222222222222222222222222222222222222222  sigye-aarch64\n'
    printf '3333333333333333333333333333333333333333333333333333333333333333  hero/dawn.png\n'
} > "$BN_ROOT/SHA256SUMS"
bn_tail='-	-	-	Tools	-	0	-	-	-	-	-	-	-	-	-	binaries:scripts/pictures/dawn.jpg@2026.09.25-2	-	0	-	-'
{
    printf '# a comment line stays\n'
    printf 'dawn\tbinary\t0.1.3+0e958747.3\tcom.termux\tbinaries:dawn@2026.09.25-2\t%s\n' "$bn_tail"
    printf 'dawn\tbinary\t0.1.3+0e958747.3\tio.vaj.tl\tbinaries:dawn-io.vaj.tl@2026.09.25-2\t%s\n' "$bn_tail"
    printf 'btop\tbinary\t1.4.7\t*\tbinaries:btop@2026.09.25-2\t%s\n' "$bn_tail"
    printf 'sigye\tbinary\t0.6.0\t*\tbinaries:sigye@2026.09.02\t%s\n' "$bn_tail"
    printf 'fisher\tfile\t4.4.8\t*\thttps://example.invalid/fisher.fish\t%s\n' "$bn_tail"
} > "$BN_ROOT/scripts/items.tsv"
OUT="$(cd "$BN_ROOT" && bash scripts/bins-record.sh bins-2026.09.26 assets 2>"$BN_ROOT/record.err")"; ST=$?
expect_status "bins-record.sh" 0
if grep -qx "$(sha "$BN_ROOT/assets/dawn-aarch64")  dawn-aarch64" "$BN_ROOT/SHA256SUMS"; then pass; else fail "a rebuilt asset's SHA256SUMS line is replaced"; fi
if [ "$(head -1 "$BN_ROOT/SHA256SUMS")" = "$(sha "$BN_ROOT/assets/dawn-aarch64")  dawn-aarch64" ]; then pass; else fail "in place, keeping the line order"; fi
if grep -qx "$(sha "$BN_ROOT/assets/dawn-io.vaj.tl-aarch64")  dawn-io.vaj.tl-aarch64" "$BN_ROOT/SHA256SUMS"; then pass; else fail "a new asset's line is added"; fi
if grep -qx '2222222222222222222222222222222222222222222222222222222222222222  sigye-aarch64' "$BN_ROOT/SHA256SUMS" && grep -qx '3333333333333333333333333333333333333333333333333333333333333333  hero/dawn.png' "$BN_ROOT/SHA256SUMS"; then pass; else fail "lines for what was not built are untouched"; fi
if [ "$(grep -c . "$BN_ROOT/SHA256SUMS")" = 5 ]; then pass; else fail "SHA256SUMS has exactly the old lines plus the new asset" "$(cat "$BN_ROOT/SHA256SUMS")"; fi
if awk -F'\t' '$1=="dawn" && $4=="com.termux" { exit ($5=="binaries:dawn@bins-2026.09.26" && $3=="0.1.3+0e958747.4") ? 0 : 1 }' "$BN_ROOT/scripts/items.tsv"; then pass; else fail "a rebuilt +commit.N item moves to the tag with N bumped" "$(cat "$BN_ROOT/scripts/items.tsv")"; fi
if awk -F'\t' '$1=="dawn" && $4=="io.vaj.tl" { exit ($5=="binaries:dawn-io.vaj.tl@bins-2026.09.26" && $3=="0.1.3+0e958747.4") ? 0 : 1 }' "$BN_ROOT/scripts/items.tsv"; then pass; else fail "the other edition's row moves and bumps too"; fi
if awk -F'\t' '$1=="btop" { exit ($5=="binaries:btop@bins-2026.09.26" && $3=="1.4.7") ? 0 : 1 }' "$BN_ROOT/scripts/items.tsv"; then pass; else fail "an unchanged binary moves to the tag and keeps its version"; fi
if awk -F'\t' '$1=="sigye" { exit ($5=="binaries:sigye@2026.09.02" && $3=="0.6.0") ? 0 : 1 }' "$BN_ROOT/scripts/items.tsv"; then pass; else fail "a tool that was not built keeps its tag"; fi
if awk -F'\t' '$1=="dawn" { exit ($21=="binaries:scripts/pictures/dawn.jpg@2026.09.25-2") ? 0 : 1 }' "$BN_ROOT/scripts/items.tsv"; then pass; else fail "a path-style source in another column is left alone"; fi
if awk -F'\t' '$1=="fisher" { exit ($5=="https://example.invalid/fisher.fish") ? 0 : 1 }' "$BN_ROOT/scripts/items.tsv"; then pass; else fail "a plain URL source is left alone"; fi
if [ "$(head -1 "$BN_ROOT/scripts/items.tsv")" = "# a comment line stays" ]; then pass; else fail "comment lines survive"; fi
expect_out "the summary names the version bump" "0.1.3+0e958747.3 -> 0.1.3+0e958747.4"
if [ -s "$BN_ROOT/record.err" ]; then fail "nothing needed a hand" "$(cat "$BN_ROOT/record.err")"; else pass; fi
# A rebuilt binary at a plain upstream version: recorded, not bumped, and said so.
printf 'btop built again\n' > "$BN_ROOT/assets/btop-aarch64"
rm -f "$BN_ROOT/assets/dawn-aarch64" "$BN_ROOT/assets/dawn-io.vaj.tl-aarch64"
OUT="$(cd "$BN_ROOT" && bash scripts/bins-record.sh bins-2026.09.27 assets 2>"$BN_ROOT/record.err")"; ST=$?
expect_status "bins-record.sh for a plain-versioned rebuild" 0
if awk -F'\t' '$1=="btop" { exit ($5=="binaries:btop@bins-2026.09.27" && $3=="1.4.7") ? 0 : 1 }' "$BN_ROOT/scripts/items.tsv"; then pass; else fail "the row moves to the tag, version untouched"; fi
if grep -q 'bins-record: btop (\*): the binary changed but its version 1.4.7 did not' "$BN_ROOT/record.err"; then pass; else fail "and stderr says the version needs a hand" "$(cat "$BN_ROOT/record.err")"; fi
if awk -F'\t' '$1=="dawn" && $4=="com.termux" { exit ($5=="binaries:dawn@bins-2026.09.26") ? 0 : 1 }' "$BN_ROOT/scripts/items.tsv"; then pass; else fail "dawn, not in this build, keeps the earlier tag"; fi
rm -rf "$BN_ROOT"

echo
# ---------------------------------------------------------------------------
# The Neovim colour scheme nvim-theme installs
# ---------------------------------------------------------------------------

# The store's nvim-colors/nvim-palette rows still resolve against the pinned
# commit in catalog.tsv, but the working copy of that colour scheme moved into
# the theme-templates pack (and its palette module became a rendered template),
# so this section only runs where the old working copy is still checked out.
# scripts/theme-templates/check.sh covers the pack's own copy.
NVIMDIR="$repo/docs/en/examples/nvim"
if [ -d "$NVIMDIR" ] && command -v nvim >/dev/null 2>&1; then
    echo "== the Neovim colour scheme"
    SHELL_LABEL=nvim
    nvroot="$(mktemp -d)"
    mkdir -p "$nvroot/home/.termux"
    cat > "$nvroot/probe.lua" <<'PROBE'
vim.cmd.colorscheme "launcher-material"
-- Every group the scheme promises to paint, in the families a config actually
-- reads: buffer, syntax, chrome, diagnostics, treesitter, git.
local need = {
  "Normal", "NormalFloat", "Comment", "Constant", "String", "Identifier",
  "Function", "Statement", "Keyword", "Type", "Special", "Error", "Todo",
  "LineNr", "CursorLine", "Visual", "Search", "Pmenu", "PmenuSel",
  "StatusLine", "StatusLineNC", "DiagnosticError", "DiagnosticWarn",
  "DiagnosticInfo", "DiagnosticHint", "@keyword", "@string", "@function",
  "@type", "@comment", "GitSignsAdd", "DiffAdd", "DiffChange", "DiffDelete",
}
local missing = {}
for _, group in ipairs(need) do
  local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
  if not (hl.fg or hl.bg or hl.sp) then
    table.insert(missing, group)
  end
end
local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
io.stdout:write(("colors_name=%s missing=%s normal_fg=%06X\n"):format(
  tostring(vim.g.colors_name),
  #missing == 0 and "none" or table.concat(missing, ","),
  normal.fg or 0))
PROBE
    cat > "$nvroot/palette.sh" <<'PALETTE'
export TERMUX_MATERIAL_TERMINAL_BACKGROUND='#1A1111'
export TERMUX_MATERIAL_TERMINAL_FOREGROUND='#F1DEDD'
export TERMUX_MATERIAL_TERMINAL_COLOR1='#FF5449'
export TERMUX_MATERIAL_TERMINAL_COLOR2='#4CAF50'
export TERMUX_MATERIAL_TERMINAL_COLOR3='#FFC107'
export TERMUX_MATERIAL_TERMINAL_COLOR4='#4D9BE6'
export TERMUX_MATERIAL_TERMINAL_COLOR5='#C77DFF'
export TERMUX_MATERIAL_TERMINAL_COLOR6='#4DD0E1'
export TERMUX_MATERIAL_TERMINAL_COLOR8='#8C7A78'
export TERMUX_MATERIAL_TERMINAL_COLOR9='#FF8A80'
export TERMUX_MATERIAL_TERMINAL_COLOR10='#81C784'
export TERMUX_MATERIAL_TERMINAL_COLOR11='#FFD54F'
export TERMUX_MATERIAL_TERMINAL_COLOR12='#82B1FF'
export TERMUX_MATERIAL_TERMINAL_COLOR13='#E1BEE7'
export TERMUX_MATERIAL_TERMINAL_COLOR14='#80DEEA'
export TERMUX_MATERIAL_TERMINAL_COLOR15='#FFFFFF'
export TERMUX_MATERIAL_ON_SURFACE_VARIANT='#D8C2C0'
export TERMUX_MATERIAL_SURFACE_CONTAINER='#271D1D'
export TERMUX_MATERIAL_SURFACE_CONTAINER_HIGH='#322828'
export TERMUX_MATERIAL_SURFACE_CONTAINER_HIGHEST='#3D3232'
export TERMUX_MATERIAL_OUTLINE='#A08C8B'
export TERMUX_MATERIAL_OUTLINE_VARIANT='#534343'
export TERMUX_MATERIAL_PRIMARY='#FFB4AB'
export TERMUX_MATERIAL_TERTIARY='#E7BF8F'
export TERMUX_MATERIAL_ERROR='#FF5449'
PALETTE

    nvprobe() {
        OUT="$(HOME="$nvroot/home" nvim --headless -u NONE \
            --cmd "set rtp^=$NVIMDIR" -l "$nvroot/probe.lua" 2>&1)"
        ST=$?
    }

    # No palette yet — plain Termux, or before the first wallpaper.
    rm -f "$nvroot/home/.termux/material-colors.sh"
    nvprobe
    expect_status "the colour scheme loads with no wallpaper palette" 0
    expect_out "it names itself" "colors_name=launcher-material"
    expect_out "every group it promises is painted" "missing=none"
    expect_out "the fixed palette is used" "normal_fg=ABB2BF"

    # With the palette the launcher writes on a wallpaper change.
    cp "$nvroot/palette.sh" "$nvroot/home/.termux/material-colors.sh"
    nvprobe
    expect_status "the colour scheme loads from the wallpaper palette" 0
    expect_out "it still names itself" "colors_name=launcher-material"
    expect_out "every group is still painted" "missing=none"
    expect_out "the wallpaper's foreground is used" "normal_fg=F1DEDD"

    rm -rf "$nvroot"
else
    echo "== nvim is not installed — the colour scheme was not loaded"
    SKIP=$((SKIP + 1))
fi

echo "== installer suite (scripts/test-install.sh)"
ti_out="$("$repo/scripts/test-install.sh" "$@" 2>&1)"
echo "$ti_out" | sed 's/^/   /' | tail -3
ti_line="$(echo "$ti_out" | grep '^passed ' | tail -1)"
if [ -n "$ti_line" ]; then
    read -r _ ti_p _ ti_f _ ti_s <<<"${ti_line//,/}"
    PASS=$((PASS + ti_p)); FAIL=$((FAIL + ti_f)); SKIP=$((SKIP + ti_s))
    [ "$ti_f" = 0 ] || FAILED_NAMES+=("test-install.sh")
else
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("test-install.sh did not finish")
fi

echo
if command -v shellcheck >/dev/null 2>&1; then
    echo "== shellcheck -s sh"
    if shellcheck -s sh "$TLSTORE" "$repo/scripts/install.sh"; then
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
