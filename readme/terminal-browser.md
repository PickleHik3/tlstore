# terminal-browser

A real web browser inside the terminal. It runs Chromium and draws the page in the launcher's
terminal with the kitty graphics protocol, so full web pages (images, layout, scripts) show up
right next to your shell and your coding agents.

## What it does

- **Shows whole web pages in the terminal.** Not a text-mode browser: the page is rendered by
  Chromium and drawn as pictures in the terminal pane.
- **Works with touch.** Tap a link to follow it, swipe to scroll, and type in the address bar.
- **Lets coding agents use the web.** `terminal-browser action` is a command line for driving the
  browser that is already open (clicking, typing, reading the page), compatible with
  agent-browser, so an agent can look at the same page you are looking at.
- **Opens files and local servers.** Point it at a web address, a `localhost` port, or an HTML
  file an agent just wrote.

## Getting started

Start it in the launcher's terminal:

```sh
terminal-browser
```

or go straight to a page:

```sh
terminal-browser open en.wikipedia.org
terminal-browser open localhost:3000
terminal-browser open ./report.html
```

`terminal-browser ls` lists the browsers that are open, and `terminal-browser help` lists every
command.

## Agents

A coding agent running in the launcher's terminal (Claude Code, Codex, ...) can open the browser
in a pane beside itself and then drive it:

```sh
terminal-browser open --split right localhost:3000
terminal-browser action -- snapshot
```

This needs **Let programs and agents control panes** turned on in the launcher's settings (it is
on unless you turned it off). Where the pane goes and how big it is follow `--split` and `--size`
when your launcher's pane API supports placing panes; on an older launcher, the pane layout
decides. A pane too narrow to share (under 88 columns side by side, under 48 rows stacked) gets
the browser in a new launcher window instead, and `ls` and `action` still find it. Quitting the
browser closes its pane.

## Mobile or desktop sites

Inside the launcher, sites are asked for their mobile version, as a phone's browser would, so
pages fit the pane and touch works the way sites expect. `terminal-browser site desktop` switches
to desktop sites (`site mobile` back, `site auto` for the default), live for every open tab; in
the browser, ctrl+shift+m toggles it. The setting is `site.mode` in the settings screen.

## Keys

| Action | Keys |
| --- | --- |
| Quit | ctrl+q |
| Type a web address | ctrl+l |
| New tab | ctrl+t |
| Command palette | ctrl+k or alt+k |
| Find in page | ctrl+shift+f |
| Next / previous match | enter / shift+enter |
| Reload | ctrl+r |
| Back / forward | ctrl+[ / ctrl+] |
| Copy / paste / cut | ctrl+c / ctrl+v / ctrl+x |
| Close a popup | escape |

## Good to know

- It runs on Termux's `electron42` package, from Termux's x11 repository. The store turns that
  repository on for you (it installs Termux's `x11-repo` package) and installs Electron and the
  libraries it needs alongside the browser: on a fresh Termux that is about 153 MB to download
  and 862 MB on disk, less if you already have some of them. The browser itself is about 13 MB.
- This build runs on Electron 42, not the Electron 44 upstream ships with its desktop builds.
- Pasting an image from the clipboard into a page does not work on Android; pasting text does.
- Telemetry is off in this build. Upstream sends anonymous usage events and crash reports; to send
  them, set `TERMINAL_BROWSER_NO_TELEMETRY=0` before starting it.
- Keep it current with `tlstore upgrade`, like everything else from the store.
  `terminal-browser upgrade` is turned off here, because it would install upstream's desktop
  build over this one.
- Upstream's project page is
  [github.com/zenbu-labs/terminal-browser](https://github.com/zenbu-labs/terminal-browser).
