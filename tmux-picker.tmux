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

CS=$'\x1b'"\[[0-9;]{1,9}m" # color escape sequence
FILE_CHARS="[[:alnum:]_.#$%&+=/@~-]"
FILE_START_CHARS="[[:space:]:<>)(&#'\"]"

# default patterns group
PATTERNS_LIST1=(
"(($CS|^|$FILE_START_CHARS)$FILE_CHARS*/$FILE_CHARS+)" # file paths with /
"(($CS|^|$FILE_START_CHARS)$FILE_CHARS+\.$FILE_CHARS{1,4})" # anything that looks like file/file path but not too short
"(()[0-9]+\.[0-9]{3,}|[0-9]{5,})" # long numbers
"(()[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})" # UUIDs
"(()[0-9a-f]{7,40})" # hex numbers (e.g. git hashes)
"(()(https?://|git@|git://|ssh://|ftp://|file:///)[[:alnum:]?=%/_.:,;~@!#$&)(*+-]*)" # URLs
"(()[[:digit:]]{1,3}\.[[:digit:]]{1,3}\.[[:digit:]]{1,3}\.[[:digit:]]{1,3})" # IP adresses
)

# alternative patterns group (shown after pressing the SPACE key)
PATTERNS_LIST2=(
"(($CS|^|$FILE_START_CHARS)$FILE_CHARS*/$FILE_CHARS+)" # file paths with /
"(($CS|^|$FILE_START_CHARS)$FILE_CHARS{5,})" # anything that looks like file/file path but not too short
"(()(https?://|git@|git://|ssh://|ftp://|file:///)[[:alnum:]?=%/_.:,;~@!#$&)(*+-]*)" # URLs
)

# items that will not be hightlighted
BLACKLIST=(
"(deleted|modified|renamed|copied|master|mkdir|[Cc]hanges|update|updated|committed|commit|working|discard|directory|staged|add/rm|checkout)"
)

# "-n M-f" for Alt-F without prefix
# "f" for prefix-F
PICKER_KEY="-n M-'"
set_tmux_env PICKER_KEY "$PICKER_KEY"

set_tmux_env PICKER_PATTERNS1 $(array_join "|" "${PATTERNS_LIST1[@]}")
set_tmux_env PICKER_PATTERNS2 $(array_join "|" "${PATTERNS_LIST2[@]}")
set_tmux_env PICKER_BLACKLIST_PATTERNS $(array_join "|" "${BLACKLIST[@]}")

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

