#!/usr/bin/env bash

#
# HELPERS
#

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TMUX_PRINTER="$CURRENT_DIR/tmux-printer/tmux-printer"

function set_tmux_env() {
    local option_name="$1"
    local final_value="$2"

    if [[ -z ${!option_name} ]]; then
      tmux setenv -g "$option_name" "$final_value"
    fi
}

function process_format () {
    echo -ne "$($TMUX_PRINTER "$1")"
}

function array_join() {
    local IFS="$1"; shift; echo "$*";
}

#
# CONFIG
#

# Every pattern have be of form ((A)B) where:
#  - A is part that will not be highlighted (e.g. escape sequence, whitespace)
#  - B is part will be highlighted (can contain subgroups)
#
# Valid examples:
#   (( )([a-z]+))
#   (( )[a-z]+)
#   (( )(http://)[a-z]+)
#   (( )(http://)([a-z]+))
#   (( |^)([a-z]+))
#   (( |^)(([a-z]+)|(bar)))
#   ((( )|(^))|(([a-z]+)|(bar)))
#   (()([0-9]+))
#   (()[0-9]+)
#
# Invalid examples:
#   (([0-9]+))
#   ([0-9]+)
#   [0-9]+

# patterns mirror wezterm's quick-select highlights: user-provided patterns
# first, then wezterm's built-in defaults. each top-level alternation is
# wrapped as ((prefix)item) so hinter.awk can strip a leading prefix from
# the highlighted/selected text — equivalent to wezterm picking the
# highest-indexed matched capture group.
#
# tmux-picker captures with `tmux capture-pane -e`, so input contains ANSI
# color escapes. without an explicit boundary the regex can match starting
# inside an escape (e.g. the digits of "\x1b[38;5;231m") and pull part of
# the escape into the hint. SP forces every match to be preceded by a CS,
# BOL, or a clean delimiter; FCS/TCS allow CS escapes to appear inside the
# body so multi-color paths still match end-to-end.
CS=$'\x1b'"\[[0-9;]{1,9}m"
START_DELIM="[[:space:]:<>)(&#'\"]"
SP="($CS|^|$START_DELIM)"
FCS="([[:alnum:]_.%/-]|$CS)"
TCS="([[:alnum:]_.%/~-]|$CS)"
PATTERNS_LIST1=(
# user patterns from wezterm config
"(${SP}${FCS}*\.${TCS}+)"                                                                           # filename / dotted path
"(${SP}ds-[[:alnum:]_]+)"                                                                           # ds-* ids
"(${SP}i-[[:alnum:]_]+)"                                                                            # i-* ids (e.g. EC2 instance)
"(${SP}[0-9]+:[[:alnum:]_-]+)"                                                                      # number:word
# wezterm built-in defaults
"((\[[^]]*\]\()[^)]+)"                                                                              # markdown_url
"(${SP}(https?://|git@|git://|ssh://|ftp://|file://)[^[:space:]]+)"                                 # url
"((--- a/)[^[:space:]]+)"                                                                           # diff_a
"((\+\+\+ b/)[^[:space:]]+)"                                                                        # diff_b
"((sha256:)[0-9a-f]{64})"                                                                           # docker
"(${SP}${FCS}*/${FCS}+)"                                                                            # path (anything containing /)
"(${SP}#[0-9a-fA-F]{6})"                                                                            # color
"(${SP}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"                               # uuid
"(${SP}Qm[[:alnum:]]{44})"                                                                          # ipfs
"(${SP}[0-9a-f]{7,40})"                                                                             # sha
"(${SP}[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})"                                             # ip
"(${SP}[A-Fa-f0-9:]+:+[A-Fa-f0-9:]+[%[:alnum:]_]+)"                                                 # ipv6
"(${SP}0x[0-9a-fA-F]+)"                                                                             # address
"(${SP}[0-9]{4,})"                                                                                  # number
)

# kept as an alias for back-compat with the SPACE-toggle codepath; same as LIST1
PATTERNS_LIST2=("${PATTERNS_LIST1[@]}")

# wezterm has no equivalent blacklist; leave empty so we don't filter matches
BLACKLIST=()

# "-n M-f" for Alt-F without prefix
# "f" for prefix-F
PICKER_KEY="-n M-f"
set_tmux_env PICKER_KEY "$PICKER_KEY"

set_tmux_env PICKER_PATTERNS1 "$(array_join "|" "${PATTERNS_LIST1[@]}")"
set_tmux_env PICKER_PATTERNS2 "$(array_join "|" "${PATTERNS_LIST2[@]}")"
set_tmux_env PICKER_BLACKLIST_PATTERNS "$(array_join "|" "${BLACKLIST[@]}")"

# Use direct ANSI escape sequences instead of tput (avoids SI/^O character issues in tmux 3.4+)
# Format: \x1b[<attrs>m where attrs: 0=reset, 1=bold, 30-37=fg color, 40-47=bg color
# Colors: 0=black, 1=red, 2=green, 3=yellow, 4=blue, 5=magenta, 6=cyan, 7=white
set_tmux_env PICKER_HINT_FORMAT $'\x1b[30;41;1m%s\x1b[0m'        # black on red, bold
set_tmux_env PICKER_HINT_FORMAT_NOCOLOR "%s"
set_tmux_env PICKER_HIGHLIGHT_FORMAT $'\x1b[30;43;1m%s\x1b[0m'   # black on yellow, bold

#
# BIND
#

tmux bind $PICKER_KEY run-shell "$CURRENT_DIR/tmux-picker.sh"

