# fish-shell

The [fish shell](https://fishshell.com), set up for this launcher's terminal: a two-line prompt in
the style of [Pure](https://github.com/sindresorhus/pure), drawn with icons in your wallpaper's
colours, an `ls` with colours and icons, quick jumps to the folders you use, and two small fish
plugins. Once it is in, new sessions start in fish.

## The prompt

The first line says where you are and what state that place is in. The second line is where you
type. Each part shows only when there is something to say:

| part | what it shows |
| --- | --- |
| folder | the repository and the folder inside it, or the path from home with the middle shortened |
| branch | the git branch, or the commit when none is checked out; tap it to open its page on GitHub, GitLab or Codeberg |
| dots | green for staged changes, yellow for changed files, grey for untracked files, red for conflicts |
| arrows | commits waiting to be pushed (up) or pulled (down) |
| box | how many changes are stashed |
| merge, rebase 2/5 | a merge, rebase, cherry-pick, revert or bisect in progress, with its step |
| hourglass | how long the last command took, when it was 5 seconds or more |
| cross | the last command's exit code, or the signal that stopped it |
| `❯` | the prompt itself, red after a command fails |

During a merge conflict the branch gets a red squiggle underneath, the way an editor marks an
error. Over ssh the line starts with you and the device's name; as root, with your name in red. A
Python virtualenv or a nix shell shows in italics on the second line, before the `❯`.

When you run a command, the prompt above it folds to its folder and the `❯`, so the scrollback
reads as a list of the commands you ran.

The colours are the terminal's own. The launcher builds them from your wallpaper and keeps them
readable against whatever sits behind the text, so changing the wallpaper or **Terminal contrast**
recolours the prompt, earlier prompts included. In plain Termux, or with a Termux:Styling scheme,
the prompt takes that scheme's colours instead.

The icons come from the launcher's bundled Nerd Font symbols. Over ssh and in plain Termux, where
that font may be missing, the prompt uses Pure's own characters (`⇡ ⇣ ≡ * + ?`) instead.

## Settings

Set any of these in `~/.config/fish/conf.d/personal.fish`:

```fish
set -g tl_prompt_icons plain      # Pure's characters instead of icons (or nerd to force icons)
set -g tl_prompt_symbol '$'       # another prompt character
set -g tl_prompt_duration 2       # show how long a command took from 2 seconds
set -g tl_prompt_git_untracked 0  # skip untracked files, for very large repositories
set -g tl_prompt_transient 0      # keep earlier prompts whole instead of folding them
```

To use a prompt of your own, define `fish_prompt` in the same file. It loads after the store's
prompt, so yours wins.

## What it installs

| part | what it is |
| --- | --- |
| `fish` | the shell, from Termux's packages |
| `config.fish` | the launcher's fish settings: the path, the wallpaper colours for your scripts, and a prompt that stays at the bottom after `clear` |
| `conf.d/personal.fish` | your own settings, written once and never touched again |
| `conf.d/launcher-prompt.fish` | the prompt |
| `eza` | `ls` with colours and icons |
| `zoxide` | `z name` jumps to the folder you use most that matches `name` |
| `fisher` | fish's plugin manager, with [puffer-fish](https://github.com/nickeb96/puffer-fish) (`...` becomes `../..`) and [autopair.fish](https://github.com/jorgebucaran/autopair.fish) (brackets and quotes close themselves) |

## Good to know

- `config.fish` and the prompt belong to the store, and `tlstore update` brings them forward. If
  you edited one, tlstore asks before replacing it. Keep your own settings in `personal.fish`.
- `tlstore update` leaves the plugins to fisher: run `fisher update` in fish to update them.
- `tlstore remove fish-shell` stops new sessions starting in fish, as long as you have not chosen
  another shell since.
