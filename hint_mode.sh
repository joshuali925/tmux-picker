#!/usr/bin/env bash

: ${TMUX_PICKER_BENCH:=0}

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
picker_session=$1

BACKSPACE=$'\177'
input=''
result=''
swap_cmd=''
feedback_buffer=''
FEEDBACK_PROCESS_PID=''
FEEDBACK_READ_FD=''
FEEDBACK_WRITE_FD=''

function redraw_hints() {
    [[ -n $FEEDBACK_WRITE_FD && -n $FEEDBACK_READ_FD ]] || return
    local _feedback_ack
    printf '%s\n' "${1,,}" >&"$FEEDBACK_WRITE_FD"
    IFS= read -r _feedback_ack <&"$FEEDBACK_READ_FD"
}

function start_feedback_worker() {
    [[ -n $feedback_buffer ]] || return 1
    coproc FEEDBACK { gawk -f "$CURRENT_DIR/key_feedback.awk"; }
    FEEDBACK_PROCESS_PID=$FEEDBACK_PID
    exec {FEEDBACK_READ_FD}<&"${FEEDBACK[0]}"
    exec {FEEDBACK_WRITE_FD}>&"${FEEDBACK[1]}"
    exec {FEEDBACK[0]}<&-
    exec {FEEDBACK[1]}>&-

    if ! tmux save-buffer -b "$feedback_buffer" - \
        \; delete-buffer -b "$feedback_buffer" >&"$FEEDBACK_WRITE_FD"; then
        return 1
    fi
    # Bounded: panes are already swapped by the parent, so a crashed or
    # truncated frame stream must not wedge us on an unbounded read.
    local _feedback_ready
    IFS= read -r -t 2 _feedback_ready <&"$FEEDBACK_READ_FD"
    [[ $_feedback_ready == "ready" ]]
}

function cleanup_feedback_worker() {
    [[ -n $feedback_buffer ]] &&
        tmux delete-buffer -b "$feedback_buffer" 2>/dev/null
    if [[ -n $FEEDBACK_WRITE_FD ]]; then
        exec {FEEDBACK_WRITE_FD}>&-
        FEEDBACK_WRITE_FD=''
    fi
    if [[ -n $FEEDBACK_READ_FD ]]; then
        exec {FEEDBACK_READ_FD}<&-
        FEEDBACK_READ_FD=''
    fi
    if [[ -n $FEEDBACK_PROCESS_PID ]]; then
        wait "$FEEDBACK_PROCESS_PID" 2>/dev/null
        FEEDBACK_PROCESS_PID=''
    fi
}

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
    cleanup_feedback_worker
    [[ -n $picker_session ]] && tmux kill-session -t "$picker_session" 2>/dev/null
}

# Trap installed before the blocking wait so a parent crash mid-handshake
# still reverts the panes (avoids orphaning the source session).
trap "handle_exit" EXIT

declare -A match_by_hint
# Enter raw mode before the metadata handoff so early keypresses queue as
# individual bytes while the rendered panes are becoming visible.
stty -echo -icanon min 1 time 0 < /dev/tty
printf '\x1b[?25l'  # hide cursor
tmux wait-for "$picker_session"
eval "$(tmux save-buffer -b "$picker_session" - \; delete-buffer -b "$picker_session")"
start_feedback_worker || exit 1

# Bench mode: skip read loop. Trap reverts panes & kills picker session.
[[ $TMUX_PICKER_BENCH == 1 ]] && exit 0

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
        if [[ -n $input ]]; then
            input=${input::-1}
            redraw_hints "$input"
        fi
        continue
    fi

    [[ $char =~ ^[a-zA-Z]$ ]] || continue

    # Only accept the keystroke if it extends some hint's prefix.
    candidate="$input$char"
    extends_prefix=0
    for hint in "${!match_by_hint[@]}"; do
        if [[ ${hint,,} == "${candidate,,}"* ]]; then
            extends_prefix=1
            break
        fi
    done
    (( extends_prefix )) || continue
    input=$candidate

    result=${match_by_hint[${input,,}]}
    [[ -n $result ]] && exit 0
    redraw_hints "$input"
done < /dev/tty
