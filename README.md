# tmux-picker

**tmux-picker**: Selecting and copy-pasting in terminal using Vimium-like hint mode for tmux.

![screencast](https://i.imgur.com/sz0176k.gif)

This is a slimmed-down, improved and extended fork of [tmux-fingers](https://github.com/Morantron/tmux-fingers). Check [Acknowledgements](#acknowledgements) for comparison.

# Usage

Press ( <kbd>Meta</kbd> + <kbd>F</kbd> ) to enter **[picker]** hint mode. Relevant stuff (file paths, URLs,
git SHAs, IPs, UUIDs, …) across **every pane in the current window** is highlighted with letter hints.

* Type a hint in **lowercase** to paste the match into the originating pane (a trailing space is appended).
* Type a hint in **UPPERCASE** to copy the match to the tmux/system clipboard without pasting.
* <kbd>Backspace</kbd> clears the in-progress hint, <kbd>Esc</kbd> exits hint mode.

By default the following are highlighted:

* File paths and dotted paths (e.g. `foo/bar`, `pkg.module.func`, `file.ext`)
* URLs (`http(s)://`, `git@`, `git://`, `ssh://`, `ftp://`, `file://`) and Markdown link targets
* Diff paths (`--- a/...`, `+++ b/...`)
* Git SHAs (7–40 hex), `sha256:…` digests, IPFS CIDs (`Qm…`)
* UUIDs, IPv4 / IPv6 addresses, hex colors (`#rrggbb`), `0x…` literals, integers (4+ digits)

# Installation

* Clone the repo: `git clone https://github.com/pawel-wiejacha/tmux-picker ~/.tmux/tmux-picker`
* Add `run-shell ~/.tmux/tmux-picker/tmux-picker.tmux` to your `~/.tmux.conf`
* Reload tmux config by running: `tmux source-file ~/.tmux.conf`

# Configuration

All configuration lives in `tmux-picker.tmux`. Edit that file (or set the same env vars before
sourcing it) and reload tmux. The variables of interest:

### Key binding

```bash
# default: Alt-F, no tmux prefix needed
PICKER_KEY="-n M-f"
# prefix-F instead:
# PICKER_KEY="f"
```

The string is passed verbatim to `tmux bind`, so any flags `tmux bind` accepts work here.

### Patterns

`PATTERNS_LIST1` is a bash array of extended regexes (gawk flavor) joined with `|` into
`PICKER_PATTERNS`. **Each pattern must be wrapped as `((prefix)body)`** — the matcher strips the
leading `prefix` capture from the hinted text so the visible hint covers only the body. The helper
variables defined at the top of `tmux-picker.tmux` make this convenient:

| Variable | Meaning |
|---|---|
| `CS` | one ANSI color escape (`\e[…m`) — patterns must allow these inside bodies because `capture-pane -e` keeps colors in the stream |
| `START_DELIM` | the punctuation set treated as a word boundary: ``[[:space:]:<>)(&#'"]`` |
| `SP` | "start position" — `($CS\|^\|$START_DELIM)`, the standard `prefix` capture |
| `FCS` | "filename char or color escape" — `[[:alnum:]_.%/~-]` ∪ `$CS` |

Add a pattern by appending another `"((prefix)body)"` entry to the array. For example, to also
highlight Jira-style ticket IDs:

```bash
PATTERNS_LIST1+=(
    "(${SP}[A-Z]+-[0-9]+)"
)
```

`BLACKLIST` is an array of regexes for matches you want to suppress (anchored with the same
`START_DELIM` boundary as the matcher). It is empty by default.

There is no longer a separate "press SPACE for more patterns" mode — everything lives in a single
list.

### Colors

Hint and highlight styles are raw ANSI escape sequences with a single `%s` placeholder. Raw
escapes are used (rather than tmux `#[…]` format strings) because tput emits SI/^O bytes that
tmux 3.4+ mangles. Defaults match the wezterm quick-select palette:

```bash
# black on orange, bold — the hint key letters
PICKER_HINT_FORMAT=$'\x1b[38;2;0;0;0;48;2;255;140;0;1m%s\x1b[0m'

# white on blue, bold — the rest of the matched item
PICKER_HIGHLIGHT_FORMAT=$'\x1b[38;2;255;255;255;48;2;0;102;204;1m%s\x1b[0m'

# fallback used when computing the rendered length of a hint
PICKER_HINT_FORMAT_NOCOLOR="%s"
```

The `38;2;R;G;B` / `48;2;R;G;B` form is 24-bit truecolor; swap in the 256-color form
(`38;5;N` / `48;5;N`) or the 8-color form (`30`–`37` / `40`–`47`) if your terminal needs it.

### Copy / paste behavior

The picker always writes the match to the tmux paste buffer with `tmux set-buffer -w` (the `-w`
flag forwards it to the system clipboard via OSC 52 when your terminal supports it). When the
hint is typed in **lowercase** the buffer is then pasted into the originating pane with a
trailing space appended. Typing the hint in **UPPERCASE** skips the paste step. This is wired
directly in `hint_mode.sh::run_picker_copy_command` — adjust it there if you want a different
action (e.g. open in `$EDITOR`).

# Requirements

* tmux 2.2+
* bash 4+
* gawk 4.1+ (which was released in 2013)

# Troubleshooting

- <kbd>Meta</kbd> + <kbd>F</kbd> does not work in copy mode
    - Set `set-option -g mode-keys vi`, adjust your key bindings or change `PICKER_KEY`

# Acknowledgements

It started as a fork of [tmux-fingers](https://github.com/Morantron/tmux-fingers). I would like to thank to [Morantron](https://github.com/Morantron) (the tmux-fingers author) for a really good piece of code!

My main problem with tmux-fingers was that it did not support terminal colors (it strips them down). I have fancy powerline prompt, colored `ls`, zsh syntax highlighting, colored git output, etc. So after entering tmux-fingers hint mode it was like *'WTF? Where are all my colors? Where am I? Where's the item I want to highlight??!'*. I could enable capturing escape sequences for colors in `tmux capture-pane`, but it would break tmux-fingers pattern matching. 

My other problem with tmux-fingers was that it was sluggish. So I started adding color support to `tmux-fingers` and improving its performance. I had to simplify things to make it reliable. I completely rewrote awk part, added Huffman Coding, added second hint mode. I therefore decided to fork and rename project instead of submitting pull requests that turn things upside down.

## Comparison

Comparing to tmux-fingers, tmux-picker:

- **supports terminal colors** (does not strip color escape codes)
- uses Huffman Coding to generate hints (**shorter hints**, less typing)
    - and supports unlimited number of hints
- is **noticeably faster** 
    - and does not have redraw glitches
- has **better patterns** and **two modes** (with different pattern sets)
    - and blacklist pattern
- is self-contained, smaller and easier to hack

Like tmux-fingers, tmux-picker still supports: 

- hints in copy-mode
- split windows/multiple panes
- zoomed panes
- two different commands
- configurable hint/highlight styles
- configurable patterns

# How it works?

The basic idea is:

- create an auxiliary `[picker]` window with one pane per pane in the source window, laid out
  identically (`tmux select-layout` on the captured `window_layout`)
- for each source pane, `tmux capture-pane -e -J -p | gawk -f hinter.awk` into its picker twin,
  drawing hints from a shared, window-wide pool so each key is unique
- swap each source pane with its picker twin (the easiest way not to break things like copy-mode);
  the realignment step keeps the originally-active pane active so keystrokes reach the read loop
- read typed keys, look up the match by hint, and either paste it back or just stash it in the
  paste buffer

# License

[MIT](https://github.com/pawel-wiejacha/tmux-picker/blob/master/LICENSE)
