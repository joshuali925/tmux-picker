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

function list_panes_sorted() {
    local target=${1:+-t $1}
    tmux list-panes $target -F "#{pane_top} #{pane_left} #{pane_id}" \
        | sort -k1,1n -k2,2n | cut -d' ' -f3
}

function prompt_picker_for_window() {
    local current_pane_id=$1
    local last_pane_id=$2

    local -a source_panes picker_panes
    mapfile -t source_panes < <(list_panes_sorted)
    local source_pane_count=${#source_panes[@]}
    local source_layout
    source_layout=$(tmux display -p '#{window_layout}')

    local picker_pane_id picker_window_id
    IFS=: read -r picker_pane_id picker_window_id < <(
        init_picker_window "$source_pane_count" "$source_layout"
    )

    mapfile -t picker_panes < <(list_panes_sorted "$picker_window_id")

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

    declare -A pane_height pane_scroll pane_in_mode
    local pane_id height scroll mode
    while IFS=$'\t' read -r pane_id height scroll mode; do
        pane_height[$pane_id]=$height
        pane_scroll[$pane_id]=$scroll
        pane_in_mode[$pane_id]=$mode
    done < <(tmux list-panes -t "$current_pane_id" -F "#{pane_id}	#{pane_height}	#{scroll_position}	#{?pane_in_mode,1,0}")

    # Stash one row per pane in tmux env: src_pane / picker_pane / capture
    # start / capture end. hint_mode.sh streams capture-pane through process
    # substitution into gawk, so no captures_dir on disk.
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
        pairs+="$src_pane"$'\t'"${picker_panes[i]}"$'\t'"$start_capture"$'\t'"$end_capture"$'\n'
    done
    tmux setenv -g PICKER_PAIRS "$pairs"

    tmux respawn-pane -k -t "$picker_pane_id" \
        "$CURRENT_DIR/hint_mode.sh \"$last_pane_id\""
}

last_pane_id=$(tmux display -pt':.{last}' '#{pane_id}' 2>/dev/null)
current_pane_id=$(tmux display -p '#{pane_id}')
prompt_picker_for_window "$current_pane_id" "$last_pane_id" >/dev/null
