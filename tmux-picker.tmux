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

# Each pattern is ((prefix)body); hinter.awk strips the prefix from the hint
# text. SP anchors matches outside ANSI escapes (capture-pane -e leaves them
# in the stream); FCS/TCS allow escapes inside the body so a path can span
# color resets between segments.
CS=$'\x1b'"\[[0-9;]{1,9}m"
START_DELIM="[[:space:]:<>)(&#'\"]"
SP="($CS|^|$START_DELIM)"
FCS="([[:alnum:]_.%/~-]|$CS)"
PATTERNS_LIST1=(
"(${SP}${FCS}*\.${FCS}+)"                                                                           # filename / dotted path
"(${SP}ds-[[:alnum:]_]+)"
"(${SP}i-[[:alnum:]_]+)"
"(${SP}[0-9]+:[[:alnum:]_-]+)"
"((\[[^]]*\]\()[^)]+)"                                                                              # markdown_url
"(${SP}(https?://|git@|git://|ssh://|ftp://|file://)[^[:space:]]+)"
"((--- a/)[^[:space:]]+)"
"((\+\+\+ b/)[^[:space:]]+)"
"((sha256:)[0-9a-f]{64})"
"(${SP}${FCS}*/${FCS}+)"                                                                            # path
"(${SP}#[0-9a-fA-F]{6})"
"(${SP}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"                               # uuid
"(${SP}Qm[[:alnum:]]{44})"                                                                          # ipfs
"(${SP}[0-9a-f]{7,40})"                                                                             # sha
"(${SP}[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})"                                             # ipv4
"(${SP}[A-Fa-f0-9:]+:+[A-Fa-f0-9:]+[%[:alnum:]_]+)"                                                 # ipv6
"(${SP}0x[0-9a-fA-F]+)"
"(${SP}[0-9]{4,})"
)

BLACKLIST=()

# "-n M-f" for Alt-F without prefix
# "f" for prefix-F
PICKER_KEY="-n M-f"
set_tmux_env PICKER_KEY "$PICKER_KEY"

set_tmux_env PICKER_PATTERNS1 "$(array_join "|" "${PATTERNS_LIST1[@]}")"
set_tmux_env PICKER_BLACKLIST_PATTERNS "$(array_join "|" "${BLACKLIST[@]}")"

# Direct ANSI escapes — tput emits SI/^O bytes that tmux 3.4+ mangles.
set_tmux_env PICKER_HINT_FORMAT $'\x1b[30;41;1m%s\x1b[0m'
set_tmux_env PICKER_HINT_FORMAT_NOCOLOR "%s"
set_tmux_env PICKER_HIGHLIGHT_FORMAT $'\x1b[30;43;1m%s\x1b[0m'

#
# BIND
#

tmux bind $PICKER_KEY run-shell "$CURRENT_DIR/tmux-picker.sh"

