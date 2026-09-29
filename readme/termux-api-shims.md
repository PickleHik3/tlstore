# termux-api-shims

The `termux-*` commands that scripts and tools already know, working in Termux Launcher without the
Termux:API app. Each one is a small shell script over `launcherctl`, which the launcher installs
and which talks to the app on this phone.

| command | what it does here |
| --- | --- |
| `termux-clipboard-get` | prints the clipboard as plain text (the launcher must be on screen) |
| `termux-clipboard-set` | puts text on the clipboard, from arguments or stdin |
| `termux-notification` | shows a notification: `-t/--title`, `-c/--content` (or stdin), `-i/--id`, `--priority` |
| `termux-notification-remove` | takes down a notification shown with `--id` |
| `termux-notification-list` | lists the notifications in the shade, as JSON |
| `termux-toast` | shows a toast; `-s` for the short one |
| `termux-vibrate` | vibrates; `-d` milliseconds, `-f` to force |
| `termux-torch` | `on` or `off` |
| `termux-battery-status` | the battery as JSON, in Termux:API's fields |
| `termux-volume` | the audio streams as a JSON array, or `termux-volume music 7` to set one |
| `termux-wallpaper` | `-f FILE` (or `-u URL`, with curl) for the home screen, `-l` for the lock screen |

Options the launcher cannot honour — a notification's buttons, actions, sounds, LED and image, a
toast's colours and position — are accepted and ignored, with a one-line warning on stderr, so
scripts written for Termux:API keep running.

## Good to know

- They install under `~/.local/bin`, like everything tlstore installs.
- If the Termux:API package (`termux-api`) is installed, tlstore will not install these: both
  provide the same commands. Remove the package first with `pkg uninstall termux-api`.
- `termux-notification-list` only lists notifications from the apps you enabled in the launcher's
  notification history settings, and only those still in the shade.
- `termux-wallpaper` needs a launcher build that has `launcherctl wallpaper`; on an older one it
  says so.
- When the launcher is not running, or `launcherctl` is missing, they exit with a non-zero status
  and say why.
