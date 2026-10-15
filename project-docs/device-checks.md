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
9. In the store app (Termux Launcher): terminal-browser's page shows the "Also installs …" line
   above the README while it is not installed; the first `i` puts "153 MB download, 862 MB on
   disk · press i again" on the notice row and starts nothing; a second `i` installs; any other
   key or tap in between lets it go. The notice fits at the phone's usual width (47 columns).
10. The same from Front, on terminal-browser's row and with it selected among other items.
11. On an io.vaj.tl phone: x11-repo and electron42 (com.termux only) have no row, so
    terminal-browser, once its row is in, is not installable there; check whether that edition's
    own repository has electron42 before widening them.

## dev 2026-10-14 — Installing: one bar per job; terminal-browser from the fork (0.13.4+6fe3538)

The store UI from this branch's `ui/` (scripts/build-ui.sh) and the engine from `engine/tlstore`;
terminal-browser from the recipe (`recipes/cross/build-terminal-browser.sh`, fork
PickleHik3/terminal-browser@6fe3538) staged beside the installed copy as `tb-tl`:

1. In the store, install an item that pulls in parts (`fish-shell`; on a phone without the musl
   loader, `dawn` or `opencode`): one number and one bar that never step back, the parts as lines
   beside the number (waiting quiet, the live one with its step words, finished ones `ready`),
   100 and the summary at the end. Record it: the old screen restarted the bar once per part.
   ~~Seen on the emulator, 2026-10-15: `opencode` (14 rows) in about two minutes, one number
   0 → 36 → 100 that never went down, the bar filled once, the four-line window followed the live
   part, finished parts `ready`, 100 and the summary at the end (scratchpad/emu/02-opencode-a.mp4).
   The engine's half on pong, 2026-10-14: `install opencode --progress` in a sandbox HOME printed
   its 14 `row` lines before the first step, every row's percentages only grew, all 14 ended ok.~~
2. ~~An item with no parts shows one line (`sigye  signature checked`) — emulator 2026-10-15.~~
   An item already installed shows `already installed` on its lines and still ends at 100: not
   reachable from the store (an installed item offers remove, not install); needs an update plan
   with a part already current, or a bundle with an installed member.
3. ~~Esc during a running install goes back while the job runs on; the Front row shows the step
   word; Installing shows the current state when reopened — emulator 2026-10-15 (fish-shell).~~
4. ~~terminal-browser (`tb-tl open en.wikipedia.org`) draws the page in the launcher's terminal,
   in the mobile layout at phone size (compact header, hamburger menu, no sidebar) — pong,
   2026-10-14, screenshot: the page is served with a mobile Chrome agent, 412 CSS pixels across at
   scale 2.4, touch emulation on.~~
5. ~~Taps follow links, a swipe scrolls, typing in the address bar navigates, Ctrl+Q closes the
   window (fingers still act as a mouse until the launcher's touch mode ships) — emulator,
   2026-10-15 (fork c140fc1): taps on article links, the hamburger menu, search fields on
   Wikipedia, Google and DuckDuckGo all land; fast swipes scroll a long page; Ctrl+Q closes the
   browser and its launcher window with no electron process left.~~
6. ~~`tb-tl site desktop` from another shell reopens the tabs in the desktop layout; `site auto`
   returns them to mobile; Ctrl+Shift+M toggles; no blank tab or frozen size after a switch —
   emulator, 2026-10-15: mobile 404–412 CSS px at 2.35–2.40, desktop 969 at 1.00 with Wikipedia's
   sidebar, both directions repeatedly, tabs kept in order with the active one, a user zoom in
   desktop mode kept per host and ignored in mobile mode.~~
7. ~~From a shell in a launcher pane narrower than 88 columns, `tb-tl open --split right <url>`
   opens the browser in a new launcher window; `tb-tl ls --all` lists it; `action --browser
   <key> -- snapshot` prints the page; Ctrl+Q closes the browser's window and leaves the shell's
   — pong 2026-10-14 (71-column pane: a window, not a split; ls and snapshot) and emulator
   2026-10-15 (the window closes on Ctrl+Q, the shell window stays).~~ A split on a pane 88
   columns or wider is still unseen (no such pane on either device).
8. The installed `terminal-browser` is untouched by the staged copy and still opens a page (seen
   on pong 2026-10-14 before the fork's build was staged beside it; not since).
9. With a launcher that has touch reports (branch feat/terminal-browser-launcher of the app, not
   built yet): a long page flings, a pinch zooms, a long press on a link opens its menu, the tab
   bar still takes taps, a Bluetooth mouse still clicks and scrolls.
