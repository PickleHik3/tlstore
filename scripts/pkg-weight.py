#!/usr/bin/env python3
"""What Termux packages weigh on a stock Termux, for an item's pkg-size= option.

    python3 -I scripts/pkg-weight.py [--arch aarch64] [--index FILE]... [--have NAMES] PACKAGE...

An item whose packages pull in a lot (terminal-browser: Termux's electron42 and the libraries it
needs) says so on its store page with `pkg-size=<download MB>,<disk MB>` (docs/SPEC.md,
Revision 15). This prints those two figures, computed rather than guessed: every package the named
ones depend on, all the way down, minus what a fresh Termux already has, summed from the Size
(download) and Installed-Size (on disk) fields of Termux's own package indexes.

A fresh Termux is taken to be everything the indexes mark `Essential: yes` (the bootstrap's
core) plus the bootstrap's few extras (BOOTSTRAP_EXTRAS below), with their dependencies. --have
adds more names (comma separated) to treat as already there.

The indexes are Termux's main and x11 repositories for --arch, read from packages-cf.termux.dev,
unless --index names local Packages files instead (any number; the first entry for a name wins).
Sizes are decimal megabytes, as apt prints them. Nothing here installs anything.
"""

import argparse
import re
import sys
import urllib.request

MIRROR = "https://packages-cf.termux.dev/apt"
REPOS = (
    ("termux-main", "stable"),
    ("termux-x11", "x11"),
)

# What termux-packages' build-bootstraps.sh puts in a bootstrap besides the Essential set.
BOOTSTRAP_EXTRAS = (
    "command-not-found", "debianutils", "dos2unix", "ed", "inetutils", "lsof",
    "nano", "net-tools", "patch", "unzip",
)


def read_index(text, into):
    """Adds each package stanza of a Packages file to `into` (the first one for a name wins)."""
    for block in text.split("\n\n"):
        fields = {}
        for line in block.splitlines():
            if line.startswith((" ", "\t")) or ": " not in line:
                continue
            key, value = line.split(": ", 1)
            fields[key] = value
        name = fields.get("Package")
        if name and name not in into:
            into[name] = fields


def fetch_index(repo, dist, arch):
    url = f"{MIRROR}/{repo}/dists/{dist}/main/binary-{arch}/Packages"
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read().decode("utf-8", "replace")


def depends(fields):
    """The names a package depends on: the first choice of each alternative, versions dropped."""
    out = []
    for key in ("Pre-Depends", "Depends"):
        for part in fields.get(key, "").split(","):
            part = part.strip()
            if part:
                out.append(re.sub(r"\s*\(.*?\)", "", part.split("|")[0]).strip())
    return out


def closure(names, index):
    """Every package in `names` and everything they need, as far as the index knows them."""
    seen = set()
    todo = list(names)
    while todo:
        name = todo.pop()
        if name in seen or name not in index:
            continue
        seen.add(name)
        todo.extend(depends(index[name]))
    return seen


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("packages", nargs="+", metavar="PACKAGE")
    ap.add_argument("--arch", default="aarch64", choices=("aarch64", "x86_64", "arm", "i686"))
    ap.add_argument("--index", action="append", default=[], metavar="FILE",
                    help="a local Packages file to read instead of the mirror (repeatable)")
    ap.add_argument("--have", default="", metavar="NAMES",
                    help="more packages to count as already installed, comma separated")
    a = ap.parse_args()

    index = {}
    if a.index:
        for path in a.index:
            with open(path, encoding="utf-8", errors="replace") as f:
                read_index(f.read(), index)
    else:
        for repo, dist in REPOS:
            read_index(fetch_index(repo, dist, a.arch), index)

    missing = [p for p in a.packages if p not in index]
    if missing:
        print("not in the indexes: " + ", ".join(missing), file=sys.stderr)
        return 1

    essential = [n for n, f in index.items() if f.get("Essential") == "yes"]
    extra = [n for n in a.have.split(",") if n]
    base = closure(essential + list(BOOTSTRAP_EXTRAS) + extra, index)
    need = closure(a.packages, index) - base

    dl = sum(int(index[p].get("Size", 0)) for p in need)
    disk = sum(int(index[p].get("Installed-Size", 0)) * 1024 for p in need)
    dl_mb = round(dl / 1e6)
    disk_mb = round(disk / 1e6)
    print(f"{len(need)} packages beyond a stock Termux: "
          f"{dl / 1e6:.1f} MB to download, {disk / 1e6:.1f} MB on disk")
    big = sorted(need, key=lambda p: -int(index[p].get("Installed-Size", 0)))[:8]
    print("largest on disk: " + ", ".join(
        f"{p} {int(index[p].get('Installed-Size', 0)) * 1024 / 1e6:.0f} MB" for p in big))
    print(f"pkg-size={dl_mb},{disk_mb}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
