#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

last_pane_id=$1
pane_was_zoomed=$2
picker_session=$3

picker_pane_id=$TMUX_PANE

# Wait for parent to populate PICKER_PAIRS and signal. Our bash startup runs
# in parallel with parent's IPC; tmux queues the signal, so order is safe.
tmux wait-for "$picker_session"

eval "$(tmux show-env -s -t "$picker_session" PICKER_PAIRS)"

declare -a src_panes picker_panes capture_starts capture_ends
declare -A picker_tty_by_id
while IFS=$'\t' read -r src_pane picker_pane start end tty; do
    [[ -z $src_pane ]] && continue
    src_panes+=("$src_pane")
    picker_panes+=("$picker_pane")
    capture_starts+=("$start")
    capture_ends+=("$end")
    picker_tty_by_id[$picker_pane]=$tty
    [[ $picker_pane == "$picker_pane_id" ]] && current_pane_id=$src_pane
done <<< "$PICKER_PAIRS"

declare -A match_by_hint

# Build the swap command once — used for both the forward swap and the revert.
# Per-pair shape doesn't change between the two calls.
swap_cmd=""
for (( i=0; i<${#src_panes[@]}; i++ )); do
    swap_cmd+="${swap_cmd:+ \\; }swap-pane -d -s ${src_panes[i]} -t ${picker_panes[i]}"
done

function extract_hints() {
    # Stream all N pane captures through one tmux call, with each capture
    # prefixed by an FS (\x1c) sentinel line so hinter.awk can demux.
    # Saves N-1 tmux forks vs. one process substitution per pane.
    local i tty_list="" tmux_cmd=""
    for (( i=0; i<${#src_panes[@]}; i++ )); do
        tty_list+="${picker_tty_by_id[${picker_panes[i]}]}"$'\n'
        tmux_cmd+="${tmux_cmd:+ \\; }display-message -p $'\\x1c'"
        tmux_cmd+=" \\; capture-pane -e -J -p -t ${src_panes[i]} -S ${capture_starts[i]} -E ${capture_ends[i]}"
    done

    local hint match
    while IFS=: read -r hint match; do
        [[ -z $hint ]] && continue
        match_by_hint[$hint]=$match
    done < <(eval "tmux $tmux_cmd" | TTY_LIST=$tty_list gawk -f "$CURRENT_DIR/hinter.awk")
}

function swap_all_panes_and_zoom() {
    # -d keeps the active pane unchanged; without it the loop leaves whichever
    # pair ran last as active, clobbering the user's slot.
    local cmd=$swap_cmd
    [[ $pane_was_zoomed == "1" ]] && cmd+=" \\; resize-pane -Z -t $picker_pane_id"
    eval "tmux $cmd"
}

BACKSPACE=$'\177'

input=''
result=''

function revert_to_original_panes() {
    local cmd=$swap_cmd
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

    # Kill the side session — this also tears down its window, its env, and our pane.
    tmux kill-session -t "$picker_session"
}


function is_valid_input() {
    local input=$1
    [[ -z $input || $input == "<ESC>" || $input =~ ^[a-zA-Z]+$ ]]
}

function hide_cursor() {
    printf '\x1b[?25l'
}

trap "handle_exit" EXIT

extract_hints
swap_all_panes_and_zoom

hide_cursor
input=''

function run_picker_copy_command() {
    local result="$1"
    local hint="$2"

    if [[ $input =~ ^[a-z]+$ ]]; then
        tmux set-buffer -w -- "$result "
        tmux paste-buffer -p -t "$current_pane_id"
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

    [[ -z $input ]] && continue
    result=${match_by_hint[${input,,}]}

    if [[ -z $result ]]; then
        continue
    fi

    exit 0
done < /dev/tty
