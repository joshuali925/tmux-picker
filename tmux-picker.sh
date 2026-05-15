#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

function init_picker_window() {
    local source_pane_count=$1
    local source_layout=$2

    # picker_pane_id runs /bin/sh because hint_mode.sh is sent to it via
    # send-keys; the rest sleep so their tty stays blank under the hints.
    local picker_ids=$(tmux new-window -F "#{pane_id}:#{window_id}" -P -d -n "[picker]" "/bin/sh")

    local i
    for (( i=1; i<source_pane_count; i++ )); do
        tmux split-window -d -t "${picker_ids%%:*}" 'sleep 2147483647' >/dev/null
    done
    if [[ -n "$source_layout" ]]; then
        tmux select-layout -t "${picker_ids#*:}" "$source_layout" >/dev/null
    fi

    echo "$picker_ids"
}

function capture_pane() {
    local pane_id=$1
    local out_path=$2
    local pane_height pane_scroll_position pane_in_copy_mode
    IFS=: read -r pane_height pane_scroll_position pane_in_copy_mode < <(
        tmux display -pt "$pane_id" '#{pane_height}:#{scroll_position}:#{?pane_in_mode,1,0}'
    )

    local start_capture end_capture
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

function list_panes_sorted() {
    local target=${1:+-t $1}
    tmux list-panes $target -F "#{pane_id} #{pane_top} #{pane_left}" \
        | sort -k2,2n -k3,3n | awk '{print $1}'
}

function prompt_picker_for_window() {
    local current_pane_id=$1
    local last_pane_id=$2

    local source_panes
    source_panes=$(list_panes_sorted)
    local source_pane_count
    source_pane_count=$(printf '%s\n' "$source_panes" | wc -l)
    local source_layout
    source_layout=$(tmux display -p '#{window_layout}')

    local picker_pane_id picker_window_id
    IFS=: read -r picker_pane_id picker_window_id < <(
        init_picker_window "$source_pane_count" "$source_layout"
    )

    local picker_panes
    picker_panes=$(list_panes_sorted "$picker_window_id")

    # Realign picker panes so picker_pane_id (which runs hint_mode.sh) pairs
    # with current_pane_id. After the final swap_all_panes, picker_pane_id
    # lands in current_pane_id's old slot — keeping it active so keystrokes
    # reach the read loop, and rendering hints in the right place when
    # current_pane_id was zoomed.
    local current_idx picker_idx
    current_idx=$(awk -v id="$current_pane_id" '$1==id{print NR; exit}' <<<"$source_panes")
    picker_idx=$(awk -v id="$picker_pane_id" '$1==id{print NR; exit}' <<<"$picker_panes")
    if [[ -n "$current_idx" && -n "$picker_idx" && "$current_idx" != "$picker_idx" ]]; then
        local target_picker
        target_picker=$(sed -n "${current_idx}p" <<<"$picker_panes")
        tmux swap-pane -s "$picker_pane_id" -t "$target_picker"
        picker_panes=$(list_panes_sorted "$picker_window_id")
    fi

    local pairs_file=$(mktemp)
    paste <(printf '%s\n' "$source_panes") <(printf '%s\n' "$picker_panes") > "$pairs_file"

    local captures_dir=$(mktemp -d)
    while IFS=$'\t' read -r src_pane picker_pane; do
        capture_pane "$src_pane" "$captures_dir/$src_pane"
    done < "$pairs_file"

    pane_exec "$picker_pane_id" "$CURRENT_DIR/hint_mode.sh \"$last_pane_id\" \"$pairs_file\" \"$captures_dir\""
}

last_pane_id=$(tmux display -pt':.{last}' '#{pane_id}' 2>/dev/null)
current_pane_id=$(tmux display -p '#{pane_id}')
prompt_picker_for_window "$current_pane_id" "$last_pane_id" >/dev/null
