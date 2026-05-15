#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

last_pane_id=$1
pairs_file=$2
captures_dir=$3

picker_pane_id=$(tmux display -p '#{pane_id}')
picker_window_id=$(tmux display -p '#{window_id}')
current_pane_id=$(awk -F$'\t' -v p="$picker_pane_id" '$2==p{print $1; exit}' "$pairs_file")

eval "$(tmux show-env -g -s | grep ^PICKER)"

match_lookup_table=$(mktemp)
hinted_dir=$(mktemp -d)

export match_lookup_table hinted_dir

function lookup_match() {
    local input=$1

    input="$(echo "$input" | tr "A-Z" "a-z")"
    grep -i "^$input:" $match_lookup_table | sed "s/^$input://" | head -n 1
}

function extract_hints() {
    : > "$match_lookup_table"

    # NUM_HINTS_NEEDED picks the right hint pool size in hinter.awk, so it
    # must be set before any pane is hinted. Count first, cache, then hint
    # each pane with a disjoint hint_offset so keys are unique window-wide.
    local total_matches=0
    local -a counts
    local i=0
    while IFS=$'\t' read -r src_pane picker_pane; do
        counts[i]=$(gawk -f "$CURRENT_DIR/counter.awk" < "$captures_dir/$src_pane")
        total_matches=$((total_matches + counts[i]))
        i=$((i + 1))
    done < "$pairs_file"
    export NUM_HINTS_NEEDED=$total_matches

    local hint_offset=0
    i=0
    while IFS=$'\t' read -r src_pane picker_pane; do
        HINT_OFFSET=$hint_offset gawk -f "$CURRENT_DIR/hinter.awk" \
            3>>"$match_lookup_table" \
            < "$captures_dir/$src_pane" \
            > "$hinted_dir/$src_pane"
        hint_offset=$((hint_offset + counts[i]))
        i=$((i + 1))
    done < "$pairs_file"
}

function render_hinted_panes() {
    while IFS=$'\t' read -r src_pane picker_pane; do
        local picker_tty
        picker_tty=$(tmux display -pt "$picker_pane" '#{pane_tty}')
        if [[ -n "$picker_tty" && -w "$picker_tty" ]]; then
            # clear first so the /bin/sh prompt doesn't shine through
            printf '\x1b[2J\x1b[H' > "$picker_tty"
            cat "$hinted_dir/$src_pane" > "$picker_tty"
        fi
    done < "$pairs_file"
}

function swap_all_panes() {
    # -d keeps the active pane unchanged across swaps; without it the loop
    # leaves whichever pair ran last as active, clobbering the user's slot.
    while IFS=$'\t' read -r src_pane picker_pane; do
        tmux swap-pane -d -s "$src_pane" -t "$picker_pane"
    done < "$pairs_file"
}

BACKSPACE=$'\177'

input=''
result=''

function is_pane_zoomed() {
    local pane_id=$1

    tmux list-panes \
        -F "#{pane_id}:#{?pane_active,active,nope}:#{?window_zoomed_flag,zoomed,nope}" \
        | grep -c "^${pane_id}:active:zoomed$"
}

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
    local is_valid=1

    if [[ $input == "" ]] || [[ $input == "<ESC>" ]]; then
        is_valid=1
    else
        for (( i=0; i<${#input}; i++ )); do
            char=${input:$i:1}

            if [[ ! "$char" =~ ^[a-zA-Z]$ ]]; then
                is_valid=0
                break
            fi
        done
    fi

    echo $is_valid
}

function hide_cursor() {
    echo -n $(tput civis)
}

trap "handle_exit" EXIT

export PICKER_PATTERNS=$PICKER_PATTERNS1
export PICKER_BLACKLIST_PATTERNS=$PICKER_BLACKLIST_PATTERNS

pane_was_zoomed=$(is_pane_zoomed "$current_pane_id")

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

    if [[ ! $(is_valid_input "$char") == "1" ]]; then
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

    result=$(lookup_match "$input")

    if [[ -z $result ]]; then
        continue
    fi

    exit 0
done < /dev/tty
