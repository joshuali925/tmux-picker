#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Opt-in bench. TMUX_PICKER_BENCH=1 logs phase timestamps and makes
# hint_mode.sh exit right after rendering hints (skips read loop).
: ${TMUX_PICKER_BENCH:=0}
: ${TMUX_PICKER_BENCH_FILE:=/tmp/tmux-picker-bench.log}
export TMUX_PICKER_BENCH TMUX_PICKER_BENCH_FILE
function _bench() {
    [[ $TMUX_PICKER_BENCH == 1 ]] || return 0
    printf '%s\t%s\t%s\n' "$EPOCHREALTIME" "tmux-picker" "$*" >> "$TMUX_PICKER_BENCH_FILE"
}
_bench start

# Insertion-sort lines by (pane_top, pane_left) numerically, then strip
# those two leading tab fields. Pane counts are tiny so O(n²) is fine.
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

# RT1: 5 displays + source list-panes in one round-trip. \x1c separates
# the scalar header from the list-panes rows.
_initial_block=$(
    tmux display -p '#{pane_id}' \
       \; display -pt':.{last}' '#{pane_id}' \
       \; display -p '#{window_layout}' \
       \; display -p '#{?window_zoomed_flag,1,0}' \
       \; display -p '#{window_name}' \
       \; display -p $'\x1c' \
       \; list-panes -F '#{pane_top}	#{pane_left}	#{pane_id}	#{pane_height}	#{scroll_position}	#{?pane_in_mode,1,0}' 2>/dev/null
)
{ IFS= read -r current_pane_id
  IFS= read -r last_pane_id
  IFS= read -r source_layout
  IFS= read -r pane_was_zoomed
  IFS= read -r source_window_name
} <<< "${_initial_block%%$'\n\x1c\n'*}"

declare -a source_panes
declare -A pane_height pane_scroll pane_in_mode
while IFS=$'\t' read -r _id _h _s _m; do
    [[ -z $_id ]] && continue
    source_panes+=("$_id")
    pane_height[$_id]=$_h
    pane_scroll[$_id]=$_s
    pane_in_mode[$_id]=$_m
done < <(_sort_panes_by_top_left <<< "${_initial_block#*$'\n\x1c\n'}")
source_pane_count=${#source_panes[@]}

declare -a capture_starts capture_ends
for (( i=0; i<source_pane_count; i++ )); do
    s=${source_panes[i]}
    if [[ ${pane_in_mode[$s]} == "1" ]]; then
        capture_starts[i]=$(( -${pane_scroll[$s]:-0} ))
        capture_ends[i]=$(( ${pane_height[$s]} - ${pane_scroll[$s]:-0} - 1 ))
    else
        capture_starts[i]=0
        capture_ends[i]="-"
    fi
done

picker_session="picker-$$"
hint_cmd="TMUX_PICKER_BENCH=$TMUX_PICKER_BENCH TMUX_PICKER_BENCH_FILE='$TMUX_PICKER_BENCH_FILE' exec '$CURRENT_DIR/hint_mode.sh' '$picker_session'"

# RT2: parallel tmux clients on the same server.
#   caps  (FD3, process sub): capture-pane streams via gawk
#   setup (foreground):        new-session + layout + picker list-panes
# Process sub avoids a tmpfs file create+write+read on macOS.
cap_cmd=""
for (( i=0; i<source_pane_count; i++ )); do
    cap_cmd+="${cap_cmd:+ \\; }display-message -p $'\\x1c'"
    cap_cmd+=" \\; capture-pane -e -J -p -t ${source_panes[i]} -S ${capture_starts[i]} -E ${capture_ends[i]}"
done

setup_cmd="new-session -d -s $picker_session -n '$source_window_name' -F '#{pane_id}' -P -x 200 -y 80 \"$hint_cmd\""
setup_cmd+=" \\; set-option -wt $picker_session automatic-rename off"
for (( i=1; i<source_pane_count; i++ )); do
    setup_cmd+=" \\; split-window -d -t $picker_session 'sleep 2147483647'"
done
[[ -n $source_layout ]] && setup_cmd+=" \\; select-layout -t $picker_session '$source_layout'"
setup_cmd+=" \\; display-message -p $'\\x1c'"
setup_cmd+=" \\; list-panes -t $picker_session -F '#{pane_top}	#{pane_left}	#{pane_id}	#{pane_tty}'"

exec 3< <(eval "tmux $cap_cmd")
setup_out=$(eval "tmux $setup_cmd")

# Setup output: <picker_pane_id>\n\x1c\n<list-panes rows>
picker_pane_id=${setup_out%%$'\n\x1c\n'*}
declare -a picker_panes
declare -A picker_tty
while IFS=$'\t' read -r _pid _tty; do
    [[ -z $_pid ]] && continue
    picker_panes+=("$_pid")
    picker_tty[$_pid]=$_tty
done < <(_sort_panes_by_top_left <<< "${setup_out#*$'\n\x1c\n'}")

# Realign so picker_pane_id (where hint_mode runs) lands in current_pane_id's
# slot after the swap — keeps that pane active so keystrokes reach the read loop.
current_idx=-1
picker_idx=-1
for (( i=0; i<source_pane_count; i++ )); do
    [[ ${source_panes[i]} == "$current_pane_id" ]] && current_idx=$i
    [[ ${picker_panes[i]} == "$picker_pane_id" ]] && picker_idx=$i
done
if (( current_idx >= 0 && picker_idx >= 0 && current_idx != picker_idx )); then
    tmux swap-pane -s "$picker_pane_id" -t "${picker_panes[current_idx]}"
    tmp=${picker_panes[picker_idx]}
    picker_panes[picker_idx]=${picker_panes[current_idx]}
    picker_panes[current_idx]=$tmp
fi

# Stream captures (already running in parallel with setup) through hinter.awk.
# Output is "hint:match\n…" then \x1d sentinel then "<idx>\t<payload>\x1e" records.
gawk_out=$(gawk -f "$CURRENT_DIR/hinter.awk" <&3)
exec 3<&-
hint_table=${gawk_out%%$'\x1d'*}
payloads=${gawk_out#*$'\x1d'}

declare -A match_by_hint
while IFS=: read -r hint match; do
    [[ -z $hint ]] && continue
    match_by_hint[$hint]=$match
done <<< "$hint_table"

# Distribute each per-pane payload to its picker tty. The here-string in
# `mapfile <<<` adds a trailing \n that becomes a phantom \n-only record
# after the last \x1e — drop anything missing the idx\tbody shape.
mapfile -d $'\x1e' -t _records <<< "$payloads"
for rec in "${_records[@]}"; do
    [[ $rec == *$'\t'* ]] || continue
    idx=${rec%%$'\t'*}
    body=${rec#*$'\t'}
    tty=${picker_tty[${picker_panes[$idx]}]}
    [[ -n $tty ]] && printf '%s' "$body" > "$tty"
done

# RT3: swap source ↔ picker, zoom if needed. HINTS VISIBLE after this.
swap_cmd=""
for (( i=0; i<source_pane_count; i++ )); do
    swap_cmd+="${swap_cmd:+ \\; }swap-pane -d -s ${source_panes[i]} -t ${picker_panes[i]}"
done
final_cmd=$swap_cmd
[[ $pane_was_zoomed == "1" ]] && final_cmd+=" \\; resize-pane -Z -t $picker_pane_id"
eval "tmux $final_cmd"
_bench "after swap (HINTS VISIBLE)"

# Hand match table + context to hint_mode via one session-scoped env var, then
# wait-for -S to unblock its `tmux wait-for "$picker_session"`. show-env takes
# at most one var name, so the whole blob is packed into PICKER_PAIRS.
printf -v _pairs 'last_pane_id=%q\ncurrent_pane_id=%q\npane_was_zoomed=%q\nswap_cmd=%q\n' \
    "$last_pane_id" "$current_pane_id" "$pane_was_zoomed" "$swap_cmd"
for hint in "${!match_by_hint[@]}"; do
    printf -v _row 'match_by_hint[%q]=%q\n' "$hint" "${match_by_hint[$hint]}"
    _pairs+=$_row
done
tmux setenv -t "$picker_session" PICKER_PAIRS "$_pairs" \
        \; wait-for -S "$picker_session"
