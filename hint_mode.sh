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

declare -A match_by_hint

function extract_hints() {
    : > "$match_lookup_table"

    # Single gawk pass over every captured pane: one process startup, one
    # regex compile. TTY_PATHS lets awk paint hints straight to each picker
    # pane in END, skipping a temp file + cat round-trip per pane.
    local -a capture_paths
    local i tty_paths=""
    for (( i=0; i<${#src_panes[@]}; i++ )); do
        capture_paths+=("$captures_dir/${src_panes[i]}")
        tty_paths+="${src_panes[i]}"$'\t'"${picker_tty_by_src[${picker_panes[i]}]}"$'\n'
    done

    TTY_PATHS=$tty_paths gawk -f "$CURRENT_DIR/hinter.awk" \
        3>>"$match_lookup_table" \
        "${capture_paths[@]}"

    # Cache hint→match in memory so per-keystroke lookup is fork-free.
    local hint match
    while IFS=: read -r hint match; do
        [[ -z $hint ]] && continue
        match_by_hint[$hint]=$match
    done < "$match_lookup_table"
}

function swap_all_panes_and_zoom() {
    # -d keeps the active pane unchanged across swaps; without it the loop
    # leaves whichever pair ran last as active, clobbering the user's slot.
    # Batched as one tmux command (swap × N + optional zoom) so the whole
    # transition costs one IPC round-trip.
    local i cmd=""
    for (( i=0; i<${#src_panes[@]}; i++ )); do
        cmd+="${cmd:+ \\; }swap-pane -d -s ${src_panes[i]} -t ${picker_panes[i]}"
    done
    [[ $pane_was_zoomed == "1" ]] && cmd+=" \\; resize-pane -Z -t $picker_pane_id"
    eval "tmux $cmd"
}

BACKSPACE=$'\177'

input=''
result=''

function revert_to_original_panes() {
    # Build one tmux command that swaps every pane back, restores the
    # last-pane / current-pane focus order, and (if needed) re-zooms the
    # current pane. Replaces N swap-pane forks plus 2 select-panes plus a
    # resize-pane with a single IPC round-trip.
    local i cmd=""
    for (( i=0; i<${#src_panes[@]}; i++ )); do
        cmd+="${cmd:+ \\; }swap-pane -d -s ${src_panes[i]} -t ${picker_panes[i]}"
    done
    if [[ -n "$last_pane_id" ]]; then
        cmd+=" \\; select-pane -t $last_pane_id \\; select-pane -t $current_pane_id"
    fi
    [[ $pane_was_zoomed == "1" ]] && cmd+=" \\; resize-pane -Z -t $current_pane_id"
    eval "tmux $cmd"
}

function handle_exit() {
    revert_to_original_panes

    if [[ ! -z "$result" ]]; then
        run_picker_copy_command "$result" "$input"
    fi

    rm -rf "$pairs_file" "$captures_dir" "$match_lookup_table"
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
swap_all_panes_and_zoom

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
