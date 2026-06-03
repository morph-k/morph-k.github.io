---
layout: post
title:  "Edit Command Output: a ZLE widget for interactive shell pipelines"
categories: macos linux zsh shell
---

One pattern I run into constantly: I execute a command, scan the output, then manually copy parts of it into the next command. Listing files, grepping logs, reading process output - the result is always text that I want to *transform* before using. The usual approach is to re-run the command inside a substitution or pipe chain, but that gets awkward fast when the editing is ad-hoc.

`edit-command-output` is a small ZLE widget that closes this gap. Press `Alt+e` with a command typed into your prompt, and it:

1. Runs the command, capturing stdout to a temp file
2. Opens the captured output in `$EDITOR`
3. Replaces your command line buffer with whatever you save

The entire flow stays inside the shell line editor, no subshell juggling, no copy-paste.

## The code

```zsh
edit-command-output() {
    local cmd="$BUFFER"
    [[ -z "${cmd// }" ]] && return 0

    local tmpf="${TMPDIR:-/tmp}/zsh-eco-$$.txt"

    # Run command, capture stdout (stderr passes through to terminal)
    if ! eval "$cmd" > "$tmpf" 2>/dev/tty; then
        print -u2 "edit-command-output: command failed: $cmd"
        command rm -f "$tmpf"
        return 0
    fi

    # Bail if nothing was captured
    if [[ ! -s "$tmpf" ]]; then
        command rm -f "$tmpf"
        return 0
    fi

    # Open editor on the captured output
    exec </dev/tty
    "${EDITOR:-vim}" "$tmpf"

    BUFFER="$(<$tmpf)"
    CURSOR=${#BUFFER}
    command rm -f "$tmpf"
}

zle -N edit-command-output

bindkey '^[e' edit-command-output
bindkey -M vicmd '^[e' edit-command-output
```

## How it works

The widget reads `$BUFFER`, zsh's variable holding the current command line text, and `eval`s it, redirecting stdout to a temp file while letting stderr pass through to the terminal via `2>/dev/tty`. If the command fails or produces no output, it bails early and cleans up.

Once output is captured, it reconnects stdin to the tty (`exec </dev/tty`) so the editor can run interactively, then opens the temp file in `$EDITOR`. When the editor exits, the saved contents replace `$BUFFER` and `$CURSOR` is placed at the end. The temp file is removed immediately after.

The binding `^[e` (`Alt+e`) is registered in both the default and `vicmd` keymaps so it works regardless of vi-mode state.

## Where this is useful

**Filtering file lists.** Type `find . -name '*.log'`, press `Alt+e`, delete the paths you don't care about, save. Your buffer now contains only the paths you want. Hit enter or append `| xargs rm` and continue.

**Editing command output before piping.** Type `kubectl get pods`, press `Alt+e`, trim the output to just the pod names you need, save. The buffer is ready to pipe into the next command.

**Building arguments interactively.** Type `git branch -a`, press `Alt+e`, keep only the branch you want, save. You now have a clean branch name sitting in your prompt.

The key advantage over `C-x C-e` (zsh's built-in `edit-command-line`) is that `edit-command-line` edits the *command itself* before running it, while `edit-command-output` edits the *output* after running it. They complement each other well.

## nota bene

`:h zle` in zsh docs, `man zshzle`

[Source: dots/zsh/.edit-command-output.zsh](https://github.com/morph-k/dots/blob/main/zsh/.edit-command-output.zsh)
