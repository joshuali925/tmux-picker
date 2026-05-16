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
# in the stream); FCS allows escapes inside the body so a path can span color
# resets between segments. SP-prefixed arms share one ((SP)(body|...)) wrapper
# so the regex engine has fewer top-level alternations to track per match.
CS=$'\x1b'"\[[0-9;]{1,9}m"
START_DELIM="[[:space:]:<>)(&#'\"]"
SP="($CS|^|$START_DELIM)"
FCS="([[:alnum:]_.%/~-]|$CS)"
SP_BODIES=(
"${FCS}*\.${FCS}+"                                                                                  # filename / dotted path
"ds-[[:alnum:]_]+"
"i-[[:alnum:]_]+"
"[0-9]+:[[:alnum:]_-]+"
"(https?://|git@|git://|ssh://|ftp://|file://)[^[:space:]]+"
"${FCS}*/${FCS}+"                                                                                   # path
"#[0-9a-fA-F]{6}"
"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"                                      # uuid
"Qm[[:alnum:]]{44}"                                                                                 # ipfs
"[0-9a-f]{7,40}"                                                                                    # sha
"[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"                                                    # ipv4
"[A-Fa-f0-9:]+:+[A-Fa-f0-9:]+[%[:alnum:]_]+"                                                        # ipv6
"0x[0-9a-fA-F]+"
"[0-9]{4,}"
)
PATTERNS_LIST=(
"(${SP}($(array_join "|" "${SP_BODIES[@]}")))"
"((\[[^]]*\]\()[^)]+)"                                                                              # markdown_url
"((--- a/)[^[:space:]]+)"
"((\+\+\+ b/)[^[:space:]]+)"
"((sha256:)[0-9a-f]{64})"
)

BLACKLIST=()

# "-n M-/" for Alt-/ without prefix
# "f" for prefix-F
PICKER_KEY="-n M-/"
set_tmux_env PICKER_KEY "$PICKER_KEY"

set_tmux_env PICKER_PATTERNS "$(array_join "|" "${PATTERNS_LIST[@]}")"
set_tmux_env PICKER_BLACKLIST_PATTERNS "$(array_join "|" "${BLACKLIST[@]}")"

# Direct ANSI escapes — tput emits SI/^O bytes that tmux 3.4+ mangles.
set_tmux_env PICKER_HINT_FORMAT $'\x1b[38;2;0;0;0;48;2;255;140;0;1m%s\x1b[0m'
set_tmux_env PICKER_HINT_FORMAT_NOCOLOR "%s"
set_tmux_env PICKER_HIGHLIGHT_FORMAT $'\x1b[38;2;255;255;255;48;2;0;102;204;1m%s\x1b[0m'

#
# BIND
#

tmux bind $PICKER_KEY run-shell "$CURRENT_DIR/tmux-picker.sh"

