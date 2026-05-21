#!/usr/bin/env bash

: ${TMUX_PICKER_BENCH:=0}

picker_session=$1

BACKSPACE=$'\177'
input=''
result=''
swap_cmd=''

function revert_to_original_panes() {
    local cmd=$swap_cmd
    if [[ -n "$last_pane_id" ]]; then
        cmd+=" \\; select-pane -t $last_pane_id \\; select-pane -t $current_pane_id"
    fi
    [[ $pane_was_zoomed == "1" ]] && cmd+=" \\; resize-pane -Z -t $current_pane_id"
    eval "tmux $cmd"
}

function run_picker_copy_command() {
    if [[ $input =~ ^[a-z]+$ ]]; then
        tmux set-buffer -w -- "$result "
        tmux paste-buffer -p -t "$current_pane_id"
    else
        tmux set-buffer -w -- "$result"
    fi
}

function handle_exit() {
    [[ -n $swap_cmd ]] && revert_to_original_panes
    [[ -n $result ]] && run_picker_copy_command
    [[ -n $picker_session ]] && tmux kill-session -t "$picker_session" 2>/dev/null
}

# Trap installed before the blocking wait so a parent crash mid-handshake
# still reverts the panes (avoids orphaning the source session).
trap "handle_exit" EXIT

declare -A match_by_hint
tmux wait-for "$picker_session"
eval "$(tmux show-env -s -t "$picker_session" PICKER_PAIRS)"
eval "$PICKER_PAIRS"

# Bench mode: skip read loop. Trap reverts panes & kills picker session.
[[ $TMUX_PICKER_BENCH == 1 ]] && exit 0

printf '\x1b[?25l'  # hide cursor

while read -rsn1 char; do
    # Swallow CSI (arrow keys etc); bare ESC exits.
    if [[ $char == $'\x1b' ]]; then
        read -rsn1 -t 0.1 next_char
        case $next_char in
            '[') read -rsn1 -t 0.1; continue ;;
            '')  exit ;;
            *)   continue ;;
        esac
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
