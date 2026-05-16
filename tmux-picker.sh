#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

function init_picker_window() {
    local source_pane_count=$1
    local source_layout=$2

    # picker_pane_id is later respawned with hint_mode.sh; the rest sleep so
    # their tty stays blank under the hints.
    local picker_ids=$(tmux new-window -F "#{pane_id}:#{window_id}" -P -d -n "[picker]" 'sleep 2147483647')
    local picker_pane_id=${picker_ids%%:*}
    local picker_window_id=${picker_ids#*:}

    local i cmd=""
    for (( i=1; i<source_pane_count; i++ )); do
        cmd+="${cmd:+ \\; }split-window -d -t $picker_pane_id 'sleep 2147483647'"
    done
    if [[ -n "$source_layout" ]]; then
        cmd+="${cmd:+ \\; }select-layout -t $picker_window_id ${source_layout@Q}"
    fi
    if [[ -n "$cmd" ]]; then
        eval "tmux $cmd >/dev/null"
    fi

    echo "$picker_ids"
}

# Sort tmux list-panes output by (pane_top, pane_left) numerically and strip
# those two leading columns. Input must be tab-separated with top, left as
# the first two fields. Numeric sort matters because pane_top "10" and "9"
# would compare wrong as strings. Done in gawk (one fork) instead of sort+cut
# (two forks) — pane counts are small so insertion sort is fine.
function _sort_panes_by_top_left() {
    gawk -F'\t' '
        { top[NR]=$1+0; left[NR]=$2+0; sub(/^[^\t]*\t[^\t]*\t/, ""); line[NR]=$0 }
        END {
            n = NR
            for (i=2; i<=n; i++) {
                j = i
                while (j>1 && (top[j]<top[j-1] || (top[j]==top[j-1] && left[j]<left[j-1]))) {
                    t=top[j]; top[j]=top[j-1]; top[j-1]=t
                    t=left[j]; left[j]=left[j-1]; left[j-1]=t
                    t=line[j]; line[j]=line[j-1]; line[j-1]=t
                    j--
                }
            }
            for (i=1; i<=n; i++) print line[i]
        }'
}

function prompt_picker_for_window() {
    local current_pane_id=$1
    local last_pane_id=$2
    local source_layout=$3
    local pane_was_zoomed=$4

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

    local picker_pane_id picker_window_id
    IFS=: read -r picker_pane_id picker_window_id < <(
        init_picker_window "$source_pane_count" "$source_layout"
    )

    # Picker window: collect ordered ids and ttys here. Stashing ttys upstream
    # spares hint_mode.sh a tmux list-panes fork after respawn. The own pane's
    # tty changes on respawn — hint_mode.sh substitutes /dev/tty for that one.
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
    # start / capture end / picker_tty. hint_mode.sh writes hint output to
    # picker_tty (own pane via /dev/tty since respawn changes its tty).
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
    tmux setenv -g PICKER_PAIRS "$pairs" \
        \; respawn-pane -k -t "$picker_pane_id" \
            "$CURRENT_DIR/hint_mode.sh \"$last_pane_id\" \"$pane_was_zoomed\""
}

{
    read -r current_pane_id
    read -r last_pane_id
    read -r source_layout
    read -r pane_was_zoomed
} < <(
    tmux display -p '#{pane_id}' \
       \; display -pt':.{last}' '#{pane_id}' \
       \; display -p '#{window_layout}' \
       \; display -p '#{?window_zoomed_flag,1,0}' 2>/dev/null
)
prompt_picker_for_window "$current_pane_id" "$last_pane_id" "$source_layout" "$pane_was_zoomed" >/dev/null
