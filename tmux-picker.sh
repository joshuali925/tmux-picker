#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

function init_picker_window() {
    local source_pane_count=$1
    local source_layout=$2

    # picker_pane_id is later respawned with hint_mode.sh; the rest sleep so
    # their tty stays blank under the hints.
    local picker_ids=$(tmux new-window -F "#{pane_id}:#{window_id}" -P -d -n "[picker]" 'sleep 2147483647')

    local i
    for (( i=1; i<source_pane_count; i++ )); do
        tmux split-window -d -t "${picker_ids%%:*}" 'sleep 2147483647' >/dev/null
    done
    if [[ -n "$source_layout" ]]; then
        tmux select-layout -t "${picker_ids#*:}" "$source_layout" >/dev/null
    fi

    echo "$picker_ids"
}

function list_panes_sorted() {
    local target=${1:+-t $1}
    tmux list-panes $target -F "#{pane_id} #{pane_top} #{pane_left}" \
        | sort -k2,2n -k3,3n | awk '{print $1}'
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
    # with current_pane_id. After the final swap_all_panes, picker_pane_id
    # lands in current_pane_id's old slot — keeping it active so keystrokes
    # reach the read loop, and rendering hints in the right place when
    # current_pane_id was zoomed.
    local current_idx=-1 picker_idx=-1 i
    for (( i=0; i<source_pane_count; i++ )); do
        [[ ${source_panes[i]} == "$current_pane_id" ]] && current_idx=$i
        [[ ${picker_panes[i]} == "$picker_pane_id" ]] && picker_idx=$i
    done
    if (( current_idx >= 0 && picker_idx >= 0 && current_idx != picker_idx )); then
        tmux swap-pane -s "$picker_pane_id" -t "${picker_panes[current_idx]}"
        mapfile -t picker_panes < <(list_panes_sorted "$picker_window_id")
    fi

    local pairs_file
    pairs_file=$(mktemp)
    for (( i=0; i<source_pane_count; i++ )); do
        printf '%s\t%s\n' "${source_panes[i]}" "${picker_panes[i]}"
    done > "$pairs_file"

    local captures_dir
    captures_dir=$(mktemp -d)

    # One tmux call to fetch capture metadata for every source pane, instead
    # of N round-trips. Filtered to the source window via #{pane_id} match.
    declare -A pane_height pane_scroll pane_in_mode
    local pane_id height scroll mode
    while IFS=$'\t' read -r pane_id height scroll mode; do
        pane_height[$pane_id]=$height
        pane_scroll[$pane_id]=$scroll
        pane_in_mode[$pane_id]=$mode
    done < <(tmux list-panes -t "$current_pane_id" -F "#{pane_id}	#{pane_height}	#{scroll_position}	#{?pane_in_mode,1,0}")

    local src_pane picker_pane start_capture end_capture
    while IFS=$'\t' read -r src_pane picker_pane; do
        if [[ ${pane_in_mode[$src_pane]} == "1" ]]; then
            start_capture=$(( -${pane_scroll[$src_pane]:-0} ))
            end_capture=$(( ${pane_height[$src_pane]} - ${pane_scroll[$src_pane]:-0} - 1 ))
        else
            start_capture=0
            end_capture="-"
        fi
        tmux capture-pane -e -J -p -t "$src_pane" -E "$end_capture" -S "$start_capture" > "$captures_dir/$src_pane"
    done < "$pairs_file"

    # respawn-pane is synchronous and skips the shell startup + send-keys
    # round-trip that send-keys-to-/bin/sh requires.
    tmux respawn-pane -k -t "$picker_pane_id" \
        "$CURRENT_DIR/hint_mode.sh \"$last_pane_id\" \"$pairs_file\" \"$captures_dir\""
}

last_pane_id=$(tmux display -pt':.{last}' '#{pane_id}' 2>/dev/null)
current_pane_id=$(tmux display -p '#{pane_id}')
prompt_picker_for_window "$current_pane_id" "$last_pane_id" >/dev/null
