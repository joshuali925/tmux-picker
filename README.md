# tmux-picker

**tmux-picker**: Selecting and copy-pasting in terminal using Vimium-like hint mode for tmux.

![screencast](https://i.imgur.com/sz0176k.gif)

This is a slimmed-down, improved and extended fork of [tmux-fingers](https://github.com/Morantron/tmux-fingers). Check [Acknowledgements](#acknowledgements) for comparison.

# Usage

Press ( <kbd>Meta</kbd> + <kbd>/</kbd> ) to enter **[picker]** hint mode. Relevant stuff (file paths, URLs,
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

### Key binding

`PICKER_KEY` (set before `tmux-picker.tmux` runs) is passed verbatim to `tmux bind`:

```bash
PICKER_KEY="-n M-/"   # default: Alt-/, no tmux prefix
# PICKER_KEY="f"      # prefix-F instead
```

### Patterns and colors

Patterns and the hint/highlight ANSI styles are hard-coded in `hinter.awk`'s `BEGIN` block —
edit that file directly. Each top-level pattern is wrapped as `((prefix)body)` so the matcher
can strip the leading `prefix` from the hinted text. Helpers `CS` (one `\e[…m` escape),
`START_DELIM`, `SP` (`(CS|^|START_DELIM)`), and `FCS` (filename-char-or-CS) are defined at the
top of the block.

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

- <kbd>Meta</kbd> + <kbd>/</kbd> does not work in copy mode
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
