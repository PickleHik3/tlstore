# tlstore's fish prompt: Pure's two-line layout, drawn with Nerd Font icons.
#
# The fish-shell bundle installs this as ~/.config/fish/conf.d/launcher-prompt.fish and replaces
# it on update (a copy you edited is kept, as for every file item). conf.d loads in name order,
# so personal.fish runs after this file: set any tl_prompt_* variable there, or define your own
# fish_prompt there and yours wins.
#
# Colours are ANSI names only, never hex. The launcher builds the terminal's sixteen colours from
# the wallpaper and keeps each one legible against what the text stands on, so this prompt follows
# the wallpaper, Terminal contrast and a light ground without reading a file, earlier prompts in
# the scrollback recolour with it, and over ssh or under a Termux:Styling scheme it takes that
# scheme's colours instead.
#
# Settings, all optional:
#   tl_prompt_icons          nerd or plain (default: nerd in the launcher's terminal, else plain)
#   tl_prompt_symbol         the prompt character (default ❯)
#   tl_prompt_duration       seconds a command must run before its time shows (default 5)
#   tl_prompt_git_untracked  0 skips untracked files, for very large repositories (default 1)
#   tl_prompt_transient      0 keeps earlier prompts whole instead of folding them (default 1)

status is-interactive; or return

# The icon set. Nerd glyphs need the launcher's bundled Symbols Nerd Font (3.5); elsewhere the
# plain set keeps Pure's own characters and leaves the pictures out.
function __tl_prompt_icons --on-variable tl_prompt_icons
    set -l mode $tl_prompt_icons
    if test -z "$mode"
        set mode plain
        if not set -q SSH_CONNECTION
            and begin
                test "$TERM_PROGRAM" = termux-launcher; or command -q launcherctl
            end
            set mode nerd
        end
    end
    if test "$mode" = nerd
        # Written as \U escapes: fish_indent turns the four-digit form into the glyph itself,
        # which most editors show as nothing at all.
        set -g __tlp_i_home \U0000f015 # fa-home
        set -g __tlp_i_dir \U0000f07b # fa-folder
        set -g __tlp_i_repo \U0000f401 # oct-repo
        set -g __tlp_i_branch \U0000e725 # dev-git_branch
        set -g __tlp_i_commit \U0000f417 # oct-git_commit
        # The change dots come from the text font: a symbol packed against another symbol is
        # squeezed into one cell while one before a space spreads over two, so icon dots in a
        # row would come out in two sizes.
        set -g __tlp_i_dirty ●
        set -g __tlp_i_staged ●
        set -g __tlp_i_untracked ●
        set -g __tlp_i_conflict ●
        set -g __tlp_i_ahead \U0000f431 # oct-arrow_up
        set -g __tlp_i_behind \U0000f433 # oct-arrow_down
        set -g __tlp_i_stash \U000f003c # md-archive
        set -g __tlp_i_action \U000f062d # md-source_merge
        set -g __tlp_i_venv \U000f0320 # md-language_python
        set -g __tlp_i_nix \U0000f313 # linux-nixos
        set -g __tlp_i_jobs \U0000f013 # fa-gear
        set -g __tlp_i_time \U000f051f # md-timer_sand
        set -g __tlp_i_fail \U000f0159 # md-close_circle
        set -g __tlp_i_ssh \U000f08c0 # md-ssh
        set -g __tlp_i_root \U000f140b # md-lightning_bolt
        # The launcher draws an icon two cells wide over the space after it, so one space would
        # leave the text touching the picture.
        set -g __tlp_gap '  '
    else
        set -g __tlp_i_home ''
        set -g __tlp_i_dir ''
        set -g __tlp_i_repo ''
        set -g __tlp_i_branch ''
        set -g __tlp_i_commit '@'
        set -g __tlp_i_dirty '*'
        set -g __tlp_i_staged '+'
        set -g __tlp_i_untracked '?'
        set -g __tlp_i_conflict '!'
        set -g __tlp_i_ahead '⇡'
        set -g __tlp_i_behind '⇣'
        set -g __tlp_i_stash '≡'
        set -g __tlp_i_action ''
        set -g __tlp_i_venv ''
        set -g __tlp_i_nix nix
        set -g __tlp_i_jobs '✦'
        set -g __tlp_i_time ''
        set -g __tlp_i_fail '✘'
        set -g __tlp_i_ssh ''
        set -g __tlp_i_root '#'
        set -g __tlp_gap ' '
    end
end
__tl_prompt_icons

# An icon and its text, with no gap when the plain set has no icon.
function __tl_prompt_pair -a icon text
    if test -n "$icon"
        printf '%s%s%s' $icon $__tlp_gap $text
    else
        printf '%s' $text
    end
end

# Who you are, shown only where it is news: over ssh, or as root. A phone calls itself
# "localhost", so the device name stands in for it.
set -g __tlp_host $hostname
if test "$__tlp_host" = localhost; and command -q getprop
    set -l device (getprop ro.product.device 2>/dev/null)
    test -n "$device"; and set __tlp_host $device
end
set -g __tlp_user $USER
test -n "$__tlp_user"; or set __tlp_user (id -un 2>/dev/null)

# OSC 7: tell the terminal where the shell is, so a new session or split opens here.
function __tl_prompt_cwd --on-variable PWD
    isatty stdout; or return
    printf '\e]7;file://%s%s\e\\\\' $hostname (string escape --style=url -- $PWD)
end
__tl_prompt_cwd

# A command's time and outcome show once, under the prompt that follows it; an empty Enter or a
# cancelled line draws a fresh prompt without them. Repaints (a vi mode change, a resize) keep
# whatever the prompt already showed.
function __tl_prompt_ran --on-event fish_postexec
    set -g __tlp_ran 1
    # git init, clone or a removed .git can move the repository under the same folder.
    string match -qr '^\s*git\b' -- $argv[1]; and set -e __tlp_where_pwd
end
function __tl_prompt_new --on-event fish_prompt
    if set -q __tlp_ran
        set -g __tlp_fresh 1
        set -e __tlp_ran
    else
        set -e __tlp_fresh
    end
end

# The web page for a remote URL: https for scp-style and ssh remotes, no user, no .git.
function __tl_prompt_web -a url
    test -n "$url"; or return 1
    set url (string replace -r '\.git/?$' '' -- $url)
    set url (string replace -r '^[^@/]+@([^:/]+):' 'https://$1/' -- $url)
    set url (string replace -r '^(?:ssh|git|https?)://(?:[^@/]+@)?([^/:]+)(?::\d+)?/' 'https://$1/' -- $url)
    string match -rq '^https://[^/]+/.' -- $url; or return 1
    printf '%s' $url
end

# The git segment, or nothing outside a repository. Where the repository is only changes with the
# folder (or a git command), so that is asked once per folder; each prompt then costs one porcelain
# v2 status, which carries the branch, its distance from upstream and the stash.
function __tl_prompt_git
    if test "$__tlp_where_pwd" != "$PWD"
        set -g __tlp_where_pwd $PWD
        set -g __tlp_where (command git rev-parse --show-toplevel --absolute-git-dir 2>/dev/null)
    end
    set -q __tlp_where[2]; or return 1
    set -l top $__tlp_where[1]
    set -l gitdir $__tlp_where[2]

    set -l args --no-optional-locks status --porcelain=v2 --branch --show-stash --ignore-submodules=dirty
    test "$tl_prompt_git_untracked" = 0; and set -a args --untracked-files=no
    set -l st (command git $args 2>/dev/null); or return 1

    set -l head (string replace -rf '^# branch\.head ' '' -- $st)
    set -l oid (string replace -rf '^# branch\.oid ' '' -- $st)
    set -l upstream (string replace -rf '^# branch\.upstream ' '' -- $st)
    set -l ab (string match -rg '^# branch\.ab \+(\d+) -(\d+)$' -- $st)
    set -l stash (string replace -rf '^# stash ' '' -- $st)

    # The branch links to its page on the remote (OSC 8): a tap offers to open it.
    set -l remote origin
    test -n "$upstream"; and set remote (string split -m1 / -- $upstream)[1]
    if test "$__tlp_web_key" != "$top:$remote"
        set -g __tlp_web_key "$top:$remote"
        set -g __tlp_web (__tl_prompt_web (command git config --get remote.$remote.url 2>/dev/null))
    end

    set -l label
    set -l link
    if test "$head" = '(detached)'
        set label (__tl_prompt_pair $__tlp_i_commit (string sub -l 7 -- $oid))
        test -n "$__tlp_web"; and set link $__tlp_web/commit/$oid
    else
        set label (__tl_prompt_pair $__tlp_i_branch (string shorten -m 24 -- $head))
        if test -n "$__tlp_web"
            set -l b (string escape --style=url -- $head)
            switch $__tlp_web
                case 'https://github.com/*'
                    set link $__tlp_web/tree/$b
                case 'https://gitlab.*'
                    set link $__tlp_web/-/tree/$b
                case 'https://codeberg.org/*'
                    set link $__tlp_web/src/branch/$b
                case '*'
                    set link $__tlp_web
            end
        end
    end

    set -l out
    # A conflict underlines the branch with a red squiggle, the way an editor marks an error.
    if string match -rq '^u ' -- $st
        set label (set_color --underline=curly --underline-color red)$label(set_color normal)
    end
    if test -n "$link"
        set label (printf '\e]8;;%s\e\\\\%s\e]8;;\e\\\\' $link $label)
    end
    set -a out (set_color brblack)$label

    # One dot per kind of change: staged green, changed yellow, untracked grey, conflict red.
    set -l dots
    string match -rq '^[12] [^.]' -- $st; and set -a dots (set_color green)$__tlp_i_staged
    string match -rq '^[12] .[^.]' -- $st; and set -a dots (set_color yellow)$__tlp_i_dirty
    string match -rq '^\? ' -- $st; and set -a dots (set_color brblack)$__tlp_i_untracked
    string match -rq '^u ' -- $st; and set -a dots (set_color red)$__tlp_i_conflict
    test -n "$dots"; and set -a out (string join '' $dots)

    if test -n "$ab[1]"; and test "$ab[1]" -gt 0
        set -a out (set_color cyan)$__tlp_i_ahead$ab[1]
    end
    if test -n "$ab[2]"; and test "$ab[2]" -gt 0
        set -a out (set_color cyan)$__tlp_i_behind$ab[2]
    end
    test -n "$stash"; and set -a out (set_color cyan)(__tl_prompt_pair $__tlp_i_stash $stash)

    # A rebase, merge, cherry-pick, revert or bisect in progress, with its step where git keeps one.
    set -l action
    set -l step
    set -l total
    if test -d $gitdir/rebase-merge
        set action rebase
        read step <$gitdir/rebase-merge/msgnum 2>/dev/null
        read total <$gitdir/rebase-merge/end 2>/dev/null
    else if test -d $gitdir/rebase-apply
        set action am
        test -f $gitdir/rebase-apply/rebasing; and set action rebase
        read step <$gitdir/rebase-apply/next 2>/dev/null
        read total <$gitdir/rebase-apply/last 2>/dev/null
    else if test -f $gitdir/MERGE_HEAD
        set action merge
    else if test -f $gitdir/CHERRY_PICK_HEAD
        set action cherry-pick
    else if test -f $gitdir/REVERT_HEAD
        set action revert
    else if test -f $gitdir/BISECT_LOG
        set action bisect
    end
    if test -n "$action"
        test -n "$step"; and test -n "$total"; and set action "$action $step/$total"
        set -a out (set_color yellow)(__tl_prompt_pair $__tlp_i_action $action)
    end

    printf '%s\n' $top
    string join ' ' -- $out
end

# Where you are: the repository and the path inside it, or the shortened path from home.
function __tl_prompt_path -a top
    set -l icon $__tlp_i_dir
    set -l text
    # git names the top by its real path; $PWD may reach it through a link.
    set -l here (path resolve -- $PWD)
    if test -n "$top"; and string match -q -- "$top*" $here
        set icon $__tlp_i_repo
        set text (path basename -- $top)
        set -l inner (string sub -s (math (string length -- $top) + 1) -- $here)
        if test -n "$inner"
            set text $text(prompt_pwd --dir-length 1 --full-length-dirs 2 -- $inner)
        end
    else if test "$PWD" = "$HOME"
        set icon $__tlp_i_home
        set text '~'
    else
        set text (prompt_pwd --dir-length 1 --full-length-dirs 2)
    end
    set_color blue
    test -n "$icon"; and printf '%s%s' $icon $__tlp_gap
    set_color --bold blue
    printf '%s' $text
end

# 1h 4m, 3m 12s, 7s.
function __tl_prompt_duration -a ms
    set -l s (math --scale=0 "floor($ms / 1000)")
    if test $s -ge 3600
        printf '%dh %dm' (math --scale=0 "floor($s / 3600)") (math --scale=0 "floor($s % 3600 / 60)")
    else if test $s -ge 60
        printf '%dm %ds' (math --scale=0 "floor($s / 60)") (math "$s % 60")
    else
        printf '%ds' $s
    end
end

function fish_mode_prompt
    # The prompt character shows the vi mode itself.
end

function fish_prompt
    set -l last $status
    set -l duration $CMD_DURATION
    set -l normal (set_color normal)

    set -l symbol ❯
    set -q tl_prompt_symbol; and set symbol $tl_prompt_symbol
    set -l symbol_color magenta
    test $last -ne 0; and set -q __tlp_fresh; and set symbol_color red
    # In vi mode the character turns round outside insert mode. Emacs bindings also call their
    # mode "default", so the bindings decide whether this applies at all.
    if contains -- "$fish_key_bindings" fish_vi_key_bindings fish_hybrid_key_bindings
        switch $fish_bind_mode
            case default replace_one visual
                set symbol ❮
        end
    end

    # An earlier prompt folds to its last directory and the character, so the scrollback reads as
    # the commands you ran.
    if contains -- --final-rendering $argv
        set -l here (path basename -- $PWD)
        test "$PWD" = "$HOME"; and set here '~'
        printf '%s%s%s %s%s%s ' (set_color brblack) $here $normal (set_color $symbol_color) $symbol $normal
        return
    end

    # Pure's blank line between one command's output and the next prompt, except at the top.
    set -q __tlp_drawn; and echo
    set -g __tlp_drawn 1

    set -l line
    if fish_is_root_user
        set -a line (set_color --bold red)(__tl_prompt_pair $__tlp_i_root $__tlp_user)$normal
    else if set -q SSH_CONNECTION
        set -a line (set_color brblack)(__tl_prompt_pair $__tlp_i_ssh "$__tlp_user@$__tlp_host")$normal
    end

    set -l git (__tl_prompt_git)
    set -a line (__tl_prompt_path $git[1])$normal
    test -n "$git[2]"; and set -a line $git[2]$normal

    set -l jobs (count (jobs -p 2>/dev/null))
    test $jobs -gt 0; and set -a line (set_color brblack)(__tl_prompt_pair $__tlp_i_jobs $jobs)$normal

    if set -q __tlp_fresh
        set -l threshold 5
        set -q tl_prompt_duration; and set threshold $tl_prompt_duration
        if test -n "$duration"; and test $duration -ge (math "$threshold * 1000")
            set -a line (set_color yellow)(__tl_prompt_pair $__tlp_i_time (__tl_prompt_duration $duration))$normal
        end
        if test $last -ne 0
            set -l what $last
            test $last -gt 128; and set what (fish_status_to_signal $last)
            set -a line (set_color red)(__tl_prompt_pair $__tlp_i_fail $what)$normal
        end
    end

    string join ' ' -- $line

    # The second line: what the next command runs inside, then the character.
    if set -q VIRTUAL_ENV
        printf '%s%s%s ' (set_color --italics brblack) (__tl_prompt_pair $__tlp_i_venv (path basename -- $VIRTUAL_ENV)) $normal
    end
    if set -q IN_NIX_SHELL
        printf '%s%s%s ' (set_color --italics brblack) $__tlp_i_nix $normal
    end
    printf '%s%s%s ' (set_color $symbol_color) $symbol $normal
end

# Earlier prompts fold (fish's transient prompt) unless tl_prompt_transient is 0. Read whenever it
# changes, since personal.fish sets it after this file has run.
function __tl_prompt_transient --on-variable tl_prompt_transient
    if test "$tl_prompt_transient" = 0
        set -g fish_transient_prompt 0
    else
        set -g fish_transient_prompt 1
    end
end
__tl_prompt_transient
