#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

function init_picker_window() {
    local source_pane_count=$1
    local source_layout=$2
    local last_pane_id=$3
    local pane_was_zoomed=$4
    local source_window_name=$5

    # Picker window lives in a detached side session so its name never appears
    # in the source session's status bar — the user sees no [picker] entry, no
    # window-list shift, no status flash. Same client (active session) keeps
    # the visible source window; we only swap *panes* across, not windows.
    # The session is named with our pid so concurrent invocations don't clash.
    local picker_session="picker-$$"

    # The active picker pane runs hint_mode.sh directly from new-session,
    # NOT a sleep + later respawn-pane. Saves ~12 ms (the cost of tmux's
    # respawn-pane bookkeeping + bash re-fork). hint_mode.sh blocks on
    # `tmux wait-for $picker_session` until the parent finishes setup and
    # signals via `wait-for -S`; tmux queues the signal so order is safe.
    local hint_cmd="exec '$CURRENT_DIR/hint_mode.sh' '$last_pane_id' '$pane_was_zoomed' '$picker_session'"
    # Name the picker window after the source window so if any tmux machinery
    # ever surfaces it (e.g. user lists sessions), it doesn't show "bash".
    # -n alone isn't enough because automatic-rename (default on) would
    # overwrite it once bash starts; the explicit set-option below pins it.
    local picker_ids=$(tmux new-session -d -s "$picker_session" -n "$source_window_name" -F "#{pane_id}:#{window_id}" -P -x 200 -y 80 "$hint_cmd")
    local picker_pane_id=${picker_ids%%:*}
    local picker_window_id=${picker_ids#*:}

    local i cmd="set-option -wt $picker_window_id automatic-rename off"
    for (( i=1; i<source_pane_count; i++ )); do
        cmd+=" \\; split-window -d -t $picker_pane_id 'sleep 2147483647'"
    done
    if [[ -n "$source_layout" ]]; then
        cmd+=" \\; select-layout -t $picker_window_id '$source_layout'"
    fi
    eval "tmux $cmd >/dev/null"

    echo "$picker_ids:$picker_session"
}

# Insertion-sort lines by (pane_top, pane_left) numerically, then strip those
# two leading tab fields. Bash-only — saves a gawk fork on the hot path. Pane
# counts are tiny (typically 1-10) so O(n²) is fine.
function _sort_panes_by_top_left() {
    local -a tops=() lefts=() lines=()
    local _t _l _rest
    while IFS=$'\t' read -r _t _l _rest; do
        [[ -z $_t ]] && continue
        tops+=("$_t"); lefts+=("$_l"); lines+=("$_rest")
    done
    local n=${#tops[@]} i j tmp
    for (( i=1; i<n; i++ )); do
        j=$i
        while (( j>0 )) && {
            (( tops[j] < tops[j-1] )) ||
            (( tops[j] == tops[j-1] && lefts[j] < lefts[j-1] ))
        }; do
            tmp=${tops[j]};  tops[j]=${tops[j-1]};   tops[j-1]=$tmp
            tmp=${lefts[j]}; lefts[j]=${lefts[j-1]}; lefts[j-1]=$tmp
            tmp=${lines[j]}; lines[j]=${lines[j-1]}; lines[j-1]=$tmp
            (( j-- ))
        done
    done
    for (( i=0; i<n; i++ )); do printf '%s\n' "${lines[i]}"; done
}

function prompt_picker_for_window() {
    local current_pane_id=$1
    local last_pane_id=$2
    local source_layout=$3
    local pane_was_zoomed=$4
    local source_window_name=$5

    # Source window: get id+height+scroll+mode in one list-panes call (saves
    # a fork over a second list-panes for height/scroll/mode).
    local -a source_panes
    declare -A pane_height pane_scroll pane_in_mode
    local _id _h _s _m
    while IFS=$'\t' read -r _id _h _s _m; do
        [[ -z $_id ]] && continue
        source_panes+=("$_id")
        pane_height[$_id]=$_h
        pane_scroll[$_id]=$_s
        pane_in_mode[$_id]=$_m
    done < <(
        tmux list-panes -t "$current_pane_id" \
            -F '#{pane_top}	#{pane_left}	#{pane_id}	#{pane_height}	#{scroll_position}	#{?pane_in_mode,1,0}' |
        _sort_panes_by_top_left
    )
    local source_pane_count=${#source_panes[@]}

    local picker_pane_id picker_window_id picker_session
    IFS=: read -r picker_pane_id picker_window_id picker_session < <(
        init_picker_window "$source_pane_count" "$source_layout" "$last_pane_id" "$pane_was_zoomed" "$source_window_name"
    )

    # Picker window: collect ordered ids and ttys here. Stashing ttys upstream
    # spares hint_mode.sh a tmux list-panes fork.
    local -a picker_panes
    declare -A picker_tty
    local _pid _tty
    while IFS=$'\t' read -r _pid _tty; do
        [[ -z $_pid ]] && continue
        picker_panes+=("$_pid")
        picker_tty[$_pid]=$_tty
    done < <(
        tmux list-panes -t "$picker_window_id" \
            -F '#{pane_top}	#{pane_left}	#{pane_id}	#{pane_tty}' |
        _sort_panes_by_top_left
    )

    # Realign picker panes so picker_pane_id (which runs hint_mode.sh) pairs
    # with current_pane_id — after the final swap, picker_pane_id lands in
    # current_pane_id's slot, staying active so keystrokes reach the read loop
    # and hints render correctly when current_pane_id was zoomed.
    local current_idx=-1 picker_idx=-1 i
    for (( i=0; i<source_pane_count; i++ )); do
        [[ ${source_panes[i]} == "$current_pane_id" ]] && current_idx=$i
        [[ ${picker_panes[i]} == "$picker_pane_id" ]] && picker_idx=$i
    done
    if (( current_idx >= 0 && picker_idx >= 0 && current_idx != picker_idx )); then
        tmux swap-pane -s "$picker_pane_id" -t "${picker_panes[current_idx]}"
        local tmp=${picker_panes[picker_idx]}
        picker_panes[picker_idx]=${picker_panes[current_idx]}
        picker_panes[current_idx]=$tmp
    fi

    # Stash one row per pane in tmux env: src_pane / picker_pane / capture
    # start / capture end / picker_tty.
    local pairs="" src_pane start_capture end_capture
    for (( i=0; i<source_pane_count; i++ )); do
        src_pane=${source_panes[i]}
        if [[ ${pane_in_mode[$src_pane]} == "1" ]]; then
            start_capture=$(( -${pane_scroll[$src_pane]:-0} ))
            end_capture=$(( ${pane_height[$src_pane]} - ${pane_scroll[$src_pane]:-0} - 1 ))
        else
            start_capture=0
            end_capture="-"
        fi
        pairs+="$src_pane"$'\t'"${picker_panes[i]}"$'\t'"$start_capture"$'\t'"$end_capture"$'\t'"${picker_tty[${picker_panes[i]}]}"$'\n'
    done
    # Hand pairs to the waiting hint_mode.sh and unblock it — one tmux call.
    tmux setenv -g PICKER_PAIRS "$pairs" \; wait-for -S "$picker_session"
}

{
    read -r current_pane_id
    read -r last_pane_id
    read -r source_layout
    read -r pane_was_zoomed
    read -r source_window_name
} < <(
    tmux display -p '#{pane_id}' \
       \; display -pt':.{last}' '#{pane_id}' \
       \; display -p '#{window_layout}' \
       \; display -p '#{?window_zoomed_flag,1,0}' \
       \; display -p '#{window_name}' 2>/dev/null
)
prompt_picker_for_window "$current_pane_id" "$last_pane_id" "$source_layout" "$pane_was_zoomed" "$source_window_name" >/dev/null
