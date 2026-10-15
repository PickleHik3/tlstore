# Device map for checks

Where a check of this repository's work runs, how to reach the device, and how to stage a build
there. Written for the device-checker agent; keep it factual and short.

## Devices

| Target | What | Use for |
|---|---|---|
| `emu` (`ad -s emu`, AVD tl16, adb `emulator-5554`, x86_64, Android 16) | The developer's local emulator with Termux Launcher as home screen, a `pkg` (apt) Termux bootstrap, tlstore, and since 2026-10-14 `electron42`. | Every screen-driven check. Other agent sessions lease it too: `ad -s emu lease acquire --wait "<why>"`, never steal a lease. |
| `pong` (`ad -s pong`, `ssh termux`, aarch64) | The developer's own phone. They run live agent sessions in herdr windows on it. | ssh-side checks only (`ssh termux sh -s <<'EOF' … EOF`; the login shell is fish), or the screen with the developer's explicit go. |

If adb shows the emulator offline or missing after another session restarted it, `adb connect
127.0.0.1:5555` or `ad -s emu status` reattaches it. `ad` is not on PATH: call
`~/.claude/skills/android-control/ad`. After a cold boot the launcher is not in front until
`ad -s emu launch com.termux`; `launcherctl` answers only then. Other agent sessions lease the
emulator for hours at a time: queue with `lease acquire --wait`, never steal.

## Running commands as the Termux app

Emulator (debuggable build): `adb -s emulator-5554 shell "run-as com.termux sh -c '…'"` with this
prelude inside: `export PREFIX=/data/data/com.termux/files/usr HOME=/data/data/com.termux/files/home
PATH=$PREFIX/bin:$HOME/.local/bin:$PATH LD_PRELOAD=$PREFIX/lib/libtermux-exec.so`. Pong is a release
build, so `run-as` fails there: use ssh.

`launcherctl` is on that PATH and talks to the launcher's pane API: `launcherctl window open
--print-id -- <cmd>` opens a launcher window running cmd without touching the screen; the API owns
that window, so `launcherctl pane read <id>`, `pane write <id> --enter '<text>'` and `window close
<id>` work on it. A shell in such a window has `TERM_PROGRAM=termux-launcher` and
`TERMUX_LAUNCHER_PANE`, which is what tlstore and terminal-browser detect. The new window takes
focus and can lose it to the developer's own window; `launcherctl window focus <id>` brings it back.

## Staging a build (the launcher rewrites its own copies on every start)

- Engine: `adb push engine/tlstore /data/local/tmp/tlstore-dev`, then as the app `cp
  /data/local/tmp/tlstore-dev $PREFIX/bin/tlstore && chmod 755 $PREFIX/bin/tlstore`.
- Store UI: `scripts/build-ui.sh x86_64` here, `adb push ui/dist/x86_64/tlstore-ui
  /data/local/tmp/tlstore-ui-x86_64`, then `cp … $PREFIX/libexec/termux-launcher/tlstore/tlstore-ui`.
  The signed catalog the launcher ships sits in that directory too; the engine reads it.
- A recipe build (terminal-browser): unpack the archive into `$HOME/.local/lib/<name>-tl` and
  put a two-line wrapper at `$HOME/.local/bin/<name>-tl` that execs its `bin/<name>`, so the
  installed copy stays untouched. On Pong the same layout exists as `tb-tl`.

## The browser's state, when an experiment leaves something behind

terminal-browser keeps three trees per install path hash: `$HOME/.config/terminal-browser-<hash>/`
(the Chromium profile: Preferences with per-host zoom levels, cookies), `$HOME/.local/state/
terminal-browser-<hash>/` (logs, including stderr.log) and `/data/data/com.termux/cache/
terminal-browser-<hash>/` (sockets, instances). Wipe all three of a test copy before judging a
build; a stale per-host zoom from an earlier bundle once masqueraded as a rendering bug for a
whole night. The site mode (`terminal-browser site`) lives in settings.json and survives.

## Reading results without the screen

terminal-browser: run `tb-tl …` commands from a shell inside a launcher window (a helper window
`launcherctl window open -- sh -c "sh $HOME/x.cmd > $HOME/x.out 2>&1; sleep 1"` works; from a
plain `run-as` shell `ls` says no browser is running and can drop the instance record). The
browser key is the `<pid>-1` part of the socket name under the cache dir's `instances/`;
`tb-tl action --browser <key> -- eval '<js>'`, `-- snapshot`, `-- tab new <url>`, `-- navigate
<url>` answer from the running browser; a control request that times out means its main process
is stuck. Keys go to the browser's pane as bytes via `launcherctl pane write <pane> < file`:
Ctrl+Q `\021`, Ctrl+Shift+M `ESC[109;6u`, Ctrl+0 `ESC[48;5u`, Ctrl+= `ESC[61;5u`. `-- close`
closes agent-browser's tab, not the browser; each `action` call leaves an agent-browser daemon
to kill afterwards. A tap on page content: take the element's getBoundingClientRect, add the
content origin (about (52, 326) px on the emulator) and multiply by devicePixelRatio.
