# Device checks owed

Checks that only a real phone can answer, one heading per branch, numbered. Strike one through
(or delete it) once it has been run on a device, with the device and the date.

## worktree-agent-a3d56bef138c4c4bf — Revision 15: large Termux packages, x11-repo first (tlstore 0.16)

On a stock Termux (com.termux, aarch64, x11 repository not turned on), with this branch's engine
and a catalog that has the terminal-browser row from `docs/maintainer/catalog.md`:

1. `LC_ALL=C apt-get install --print-uris --assume-no -q ripgrep`, with ripgrep not installed (so
   apt needs nothing beyond the name and would not ask): it prints the "Need to get" and "After
   this operation" lines, prints URIs, and leaves ripgrep NOT installed (`dpkg -s ripgrep` fails).
   This is the case where a plain `--assume-no` installs without asking.
2. The same with a package that pulls in others: both lines, `Abort.`, nothing installed. Record
   `apt --version` and whether it prints apt 2's lines or apt 3's `Download size:` / `Space
   needed:` summary.
3. `tlstore install terminal-browser` prints, before `Go ahead?`, the catalog's sentence ("Also
   installs Termux's Electron and the libraries it needs: about 153 MB to download, 862 MB on
   disk …"), since apt does not know electron42 yet. Answering `n` installs nothing
   (`dpkg -s x11-repo` fails).
4. Answering yes: `x11-repo` installs in a call of its own, then the lists are read again
   (`apt-get update` output naming the x11 source), then electron42 and its libraries install and
   terminal-browser starts. Note whether x11-repo's own postinst already ran `apt update` (harmless
   twice, but worth knowing).
5. With x11 already on and electron42 removed (`tlstore remove terminal-browser`, `pkg uninstall
   electron42`), `tlstore install terminal-browser` shows apt's own figures ("The packages this
   needs from Termux take … MB to download and … MB more on disk.") in the range `apt install
   electron42` itself reports.
6. A small install (`tlstore install fish-shell` on a phone without fish) shows no size line and
   reads as before; note how long the extra apt question takes before `Go ahead?`.
7. With the first call failing (airplane mode as it starts): terminal-browser ends skipped ("needs
   electron42, which did not install"), another item in the same install still installs, and the
   next `tlstore install terminal-browser` starts from x11-repo again.
8. `tlstore update` on a phone with several pkg items and an upgrade over 50 MB waiting asks
   `Go ahead?` after the size line; with only small upgrades it asks nothing, as before.
