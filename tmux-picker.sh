#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

function init_picker_window() {
    local source_pane_count=$1
    local source_layout=$2

    # the first picker pane runs /bin/sh because hint_mode.sh is sent to it
    # via send-keys; the others just need to stay quiet so their tty doesn't
    # show shell prompts behind the hinted content we render into them.
    local picker_ids=$(tmux new-window -F "#{pane_id}:#{window_id}" -P -d -n "[picker]" "/bin/sh")
    local picker_pane_id=$(echo "$picker_ids" | cut -f1 -d:)
    local picker_window_id=$(echo "$picker_ids" | cut -f2 -d:)

    local i
    for (( i=1; i<source_pane_count; i++ )); do
        tmux split-window -d -t "$picker_pane_id" 'sleep 2147483647' >/dev/null
    done
    if [[ -n "$source_layout" ]]; then
        tmux select-layout -t "$picker_window_id" "$source_layout" >/dev/null
    fi

    echo "$picker_pane_id:$picker_window_id"
}

function capture_pane() {
    local pane_id=$1
    local out_path=$2
    local pane_info=$(tmux list-panes -s -F "#{pane_id}:#{pane_height}:#{scroll_position}:#{?pane_in_mode,1,0}" | grep "^$pane_id")

    local pane_height=$(echo $pane_info | cut -d: -f2)
    local pane_scroll_position=$(echo $pane_info | cut -d: -f3)
    local pane_in_copy_mode=$(echo $pane_info | cut -d: -f4)

    local start_capture=""

    if [[ "$pane_in_copy_mode" == "1" ]]; then
        start_capture=$((-pane_scroll_position))
        end_capture=$((pane_height - pane_scroll_position - 1))
    else
        start_capture=0
        end_capture="-"
    fi

    tmux capture-pane -e -J -p -t $pane_id -E $end_capture -S $start_capture > $out_path
}

function pane_exec() {
    local pane_id=$1
    local pane_command=$2

    tmux send-keys -t $pane_id " $pane_command"
    tmux send-keys -t $pane_id Enter
}

function prompt_picker_for_window() {
    local current_pane_id=$1
    local last_pane_id=$2

    # collect every pane in the current window, sorted by position so the
    # mapping into the cloned layout is stable. each entry is "pane_id top left"
    local source_panes_raw
    source_panes_raw=$(tmux list-panes -F "#{pane_id} #{pane_top} #{pane_left}" \
        | sort -k2,2n -k3,3n)

    local source_pane_count
    source_pane_count=$(printf '%s\n' "$source_panes_raw" | wc -l)
    local source_layout
    source_layout=$(tmux display -p '#{window_layout}')

    local picker_init_data
    picker_init_data=$(init_picker_window "$source_pane_count" "$source_layout")
    local picker_pane_id=$(echo "$picker_init_data" | cut -f1 -d':')
    local picker_window_id=$(echo "$picker_init_data" | cut -f2 -d':')

    # gather picker panes in the same positional order so they pair up with
    # source panes one-to-one
    local picker_panes_raw
    picker_panes_raw=$(tmux list-panes -t "$picker_window_id" -F "#{pane_id} #{pane_top} #{pane_left}" \
        | sort -k2,2n -k3,3n)

    # write the source <-> picker pane pairings, one per line, for hint_mode.sh
    local pairs_file=$(mktemp)
    paste <(printf '%s\n' "$source_panes_raw" | awk '{print $1}') \
          <(printf '%s\n' "$picker_panes_raw" | awk '{print $1}') \
        > "$pairs_file"

    # capture every source pane up front; hint_mode.sh will process and render
    local captures_dir=$(mktemp -d)
    while IFS=$'\t' read -r src_pane picker_pane; do
        capture_pane "$src_pane" "$captures_dir/$src_pane"
    done < "$pairs_file"

    pane_exec "$picker_pane_id" "$CURRENT_DIR/hint_mode.sh \"$current_pane_id\" \"$picker_pane_id\" \"$last_pane_id\" \"$picker_window_id\" \"$pairs_file\" \"$captures_dir\""

    echo "$picker_pane_id"
}

last_pane_id=$(tmux display -pt':.{last}' '#{pane_id}' 2>/dev/null)
current_pane_id=$(tmux list-panes -F "#{pane_id}:#{?pane_active,active,nope}" | grep active | cut -d: -f1)
prompt_picker_for_window "$current_pane_id" "$last_pane_id"
