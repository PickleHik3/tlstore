# Device map for checks

Where a check of this repository's work runs, how to reach the device, and how to stage a build
there. Written for the device-checker agent; keep it factual and short.

## Devices

| Target | What | Use for |
|---|---|---|
| `emu` (`ad -s emu`, AVD tl16, adb `emulator-5554`, x86_64, Android 16) | The developer's local emulator with Termux Launcher as home screen, a `pkg` (apt) Termux bootstrap, tlstore, and since 2026-10-14 `electron42`. | Every screen-driven check. Other agent sessions lease it too: `ad -s emu lease acquire --wait "<why>"`, never steal a lease. |
| `pong` (`ad -s pong`, `ssh termux`, aarch64) | The developer's own phone. They run live agent sessions in herdr windows on it. | ssh-side checks only (`ssh termux sh -s <<'EOF' … EOF`; the login shell is fish), or the screen with the developer's explicit go. |

If adb shows the emulator offline or missing after another session restarted it, `adb connect
127.0.0.1:5555` or `ad -s emu status` reattaches it.

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

## Reading results without the screen

terminal-browser: `tb-tl ls --all` (plain `ls` sees only its own pane), `tb-tl action --browser
<key> -- snapshot` or `-- eval '<js>'` answer from the running browser; a control request that
times out means the browser's main process is stuck. Its logs: `$HOME/.local/state/terminal-browser-<hash>/logs/stderr.log`.
