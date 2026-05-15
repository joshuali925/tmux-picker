#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

last_pane_id=$1
pairs_file=$2
captures_dir=$3

# tmux display -p reports the *client's* active pane, which is still the
# source window at this point — so use $TMUX_PANE for our own pane id.
picker_pane_id=$TMUX_PANE

declare -a src_panes picker_panes
declare -A picker_tty_by_src
while IFS=$'\t' read -r src_pane picker_pane; do
    src_panes+=("$src_pane")
    picker_panes+=("$picker_pane")
    [[ $picker_pane == "$picker_pane_id" ]] && current_pane_id=$src_pane
done < "$pairs_file"

picker_window_id=$(tmux display -pt "$picker_pane_id" '#{window_id}')

# Replaces a list-panes|grep fork with a single targeted query.
pane_was_zoomed=$(tmux display -pt "$current_pane_id" '#{?window_zoomed_flag,1,0}')

# Fetch every picker tty in one list-panes; the render loop used to do a
# `tmux display` per pane.
while IFS=$'\t' read -r pid tty; do
    picker_tty_by_src[$pid]=$tty
done < <(tmux list-panes -t "$picker_pane_id" -F "#{pane_id}	#{pane_tty}")

eval "$(tmux show-env -g -s | grep ^PICKER)"

match_lookup_table=$(mktemp)
hinted_dir=$(mktemp -d)

declare -A match_by_hint

function extract_hints() {
    : > "$match_lookup_table"

    # Single gawk pass over every captured pane: one process startup, one
    # regex compile, and the hint pool is chosen at END from the global
    # unique-match count.
    local -a capture_paths
    local src
    for src in "${src_panes[@]}"; do
        capture_paths+=("$captures_dir/$src")
    done

    HINTED_DIR=$hinted_dir gawk -f "$CURRENT_DIR/hinter.awk" \
        3>>"$match_lookup_table" \
        "${capture_paths[@]}" >/dev/null

    # Cache hint→match in memory so per-keystroke lookup is fork-free.
    local hint match
    while IFS=: read -r hint match; do
        match_by_hint[$hint]=$match
    done < "$match_lookup_table"
}

function render_hinted_panes() {
    local i
    for (( i=0; i<${#src_panes[@]}; i++ )); do
        local src=${src_panes[i]} picker=${picker_panes[i]}
        local picker_tty=${picker_tty_by_src[$picker]}
        if [[ -n $picker_tty && -w $picker_tty ]]; then
            # clear first so the picker pane's prior content doesn't shine through
            printf '\x1b[2J\x1b[H' > "$picker_tty"
            cat "$hinted_dir/$src" > "$picker_tty"
        fi
    done
}

function swap_all_panes() {
    # -d keeps the active pane unchanged across swaps; without it the loop
    # leaves whichever pair ran last as active, clobbering the user's slot.
    local i
    for (( i=0; i<${#src_panes[@]}; i++ )); do
        tmux swap-pane -d -s "${src_panes[i]}" -t "${picker_panes[i]}"
    done
}

BACKSPACE=$'\177'

input=''
result=''

function zoom_pane() {
    local pane_id=$1

    tmux resize-pane -Z -t "$pane_id"
}

function revert_to_original_panes() {
    swap_all_panes

    if [[ ! -z "$last_pane_id" ]]; then
        tmux select-pane -t "$last_pane_id"
        tmux select-pane -t "$current_pane_id"
    fi

    [[ $pane_was_zoomed == "1" ]] && zoom_pane "$current_pane_id"
}

function handle_exit() {
    revert_to_original_panes

    if [[ ! -z "$result" ]]; then
        run_picker_copy_command "$result" "$input"
    fi

    rm -rf "$pairs_file" "$captures_dir" "$hinted_dir" "$match_lookup_table"
    tmux kill-window -t "$picker_window_id"
}


function is_valid_input() {
    local input=$1
    [[ -z $input || $input == "<ESC>" || $input =~ ^[a-zA-Z]+$ ]]
}

function hide_cursor() {
    # Inline DECTCEM hide instead of forking tput.
    printf '\x1b[?25l'
}

trap "handle_exit" EXIT

export PICKER_PATTERNS=$PICKER_PATTERNS1

extract_hints
render_hinted_panes
swap_all_panes
[[ $pane_was_zoomed == "1" ]] && zoom_pane "$picker_pane_id"

hide_cursor
input=''

function run_picker_copy_command() {
    local result="$1"
    local hint="$2"

    if [[ $input =~ ^[a-z]+$ ]]; then
        tmux set-buffer -w -- "$result "
        tmux paste-buffer -t "$current_pane_id"
    else
        tmux set-buffer -w -- "$result"
    fi
}

while read -rsn1 char; do
    if [[ $char == "$BACKSPACE" ]]; then
        input=""
    fi

    # Escape sequence, flush input
    if [[ "$char" == $'\x1b' ]]; then
        read -rsn1 -t 0.1 next_char

        if [[ "$next_char" == "[" ]]; then
            read -rsn1 -t 0.1
            continue
        elif [[ "$next_char" == "" ]]; then
            char="<ESC>"
        else
            continue
        fi

    fi

    if ! is_valid_input "$char"; then
        continue
    fi

    if [[ $char == "$BACKSPACE" ]]; then
        input=""
        continue
    elif [[ $char == "<ESC>" ]]; then
            exit
    else
        input="$input$char"
    fi

    result=${match_by_hint[${input,,}]}

    if [[ -z $result ]]; then
        continue
    fi

    exit 0
done < /dev/tty
