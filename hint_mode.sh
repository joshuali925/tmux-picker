#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

last_pane_id=$1
pairs_file=$2
captures_dir=$3

# tmux display -p reports the *client's* active pane, which is still the
# source window at this point — so use $TMUX_PANE for our own pane id.
picker_pane_id=$TMUX_PANE

declare -a src_panes picker_panes
while IFS=$'\t' read -r src_pane picker_pane; do
    src_panes+=("$src_pane")
    picker_panes+=("$picker_pane")
    [[ $picker_pane == "$picker_pane_id" ]] && current_pane_id=$src_pane
done < "$pairs_file"

pane_was_zoomed=$(tmux display -pt "$current_pane_id" '#{?window_zoomed_flag,1,0}')

# Fetch picker ttys after respawn-pane reassigns picker_pane_id's pty —
# capturing them in tmux-picker.sh would store the pre-respawn tty, which
# the user no longer owns (-> EACCES when gawk redirects to it).
declare -A picker_tty_by_id
while IFS=$'\t' read -r pid tty; do
    picker_tty_by_id[$pid]=$tty
done < <(tmux list-panes -t "$picker_pane_id" -F "#{pane_id}	#{pane_tty}")

eval "$(tmux show-env -g -s | grep ^PICKER)"

match_lookup_table=$(mktemp)

declare -A match_by_hint

function build_swap_cmd() {
    local i cmd=""
    for (( i=0; i<${#src_panes[@]}; i++ )); do
        cmd+="${cmd:+ \\; }swap-pane -d -s ${src_panes[i]} -t ${picker_panes[i]}"
    done
    printf '%s' "$cmd"
}

function extract_hints() {
    : > "$match_lookup_table"

    local -a capture_paths
    local i tty_list=""
    for (( i=0; i<${#src_panes[@]}; i++ )); do
        capture_paths+=("$captures_dir/${src_panes[i]}")
        tty_list+="${picker_tty_by_id[${picker_panes[i]}]}"$'\n'
    done

    TTY_LIST=$tty_list gawk -f "$CURRENT_DIR/hinter.awk" \
        3>>"$match_lookup_table" \
        "${capture_paths[@]}"

    local hint match
    while IFS=: read -r hint match; do
        [[ -z $hint ]] && continue
        match_by_hint[$hint]=$match
    done < "$match_lookup_table"
}

function swap_all_panes_and_zoom() {
    # -d keeps the active pane unchanged; without it the loop leaves whichever
    # pair ran last as active, clobbering the user's slot.
    local cmd
    cmd=$(build_swap_cmd)
    [[ $pane_was_zoomed == "1" ]] && cmd+=" \\; resize-pane -Z -t $picker_pane_id"
    eval "tmux $cmd"
}

BACKSPACE=$'\177'

input=''
result=''

function revert_to_original_panes() {
    local cmd
    cmd=$(build_swap_cmd)
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
    tmux kill-window -t "$picker_pane_id"
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
