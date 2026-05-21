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

# Start the gawk coprocess as early as possible so its BEGIN block (regex
# compile, hint table init) is finished by the time bash has captured pane
# data to feed it.
coproc HINT { gawk -f "$CURRENT_DIR/hinter.awk"; }

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
_bench "after RT1 (display+list-panes)"
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

# Pre-compute current_idx (position of the user's pane in source_panes).
# We use it to land the picker session's hint_mode pane at the same slot,
# so after the final swap-pane chain the user's pane focus stays on the
# pane running hint_mode (where keystrokes are expected).
current_idx=0
for (( i=0; i<source_pane_count; i++ )); do
    [[ ${source_panes[i]} == "$current_pane_id" ]] && { current_idx=$i; break; }
done

# RT2: chain picker-session setup and captures onto a single tmux client.
# tmux serializes commands per client AND switching clients costs another
# ~10ms round-trip, so chaining is strictly better than two parallel
# clients on the same socket.
#
# Setup goes FIRST (so picker_pane_id and list-panes are ready early to
# parse for tty assignment), then \x1f marker, then captures.
combined=" new-session -d -s $picker_session -n '$source_window_name' -F '#{pane_id}' -P -x 200 -y 80 \"$hint_cmd\""
for (( i=1; i<source_pane_count; i++ )); do
    combined+=" \\; split-window -d -t $picker_session 'sleep 2147483647'"
done
[[ -n $source_layout ]] && combined+=" \\; select-layout -t $picker_session '$source_layout'"
# Realign: move the new-session pane (currently at picker_session.0) to
# index $current_idx so hint_mode runs in the slot the user is focused on.
# `swap-pane -s ... -t ...` is a no-op if the indices are the same.
(( current_idx != 0 )) && combined+=" \\; swap-pane -t $picker_session.0 -s $picker_session.$current_idx"
combined+=" \\; display-message -p $'\\x1c'"
combined+=" \\; list-panes -t $picker_session -F '#{pane_top}	#{pane_left}	#{pane_id}	#{pane_tty}'"
combined+=" \\; display-message -p $'\\x1f'"
for (( i=0; i<source_pane_count; i++ )); do
    combined+=" \\; display-message -p $'\\x1c'"
    combined+=" \\; capture-pane -e -J -p -t ${source_panes[i]} -S ${capture_starts[i]} -E ${capture_ends[i]}"
done

combined_out=$(eval "tmux $combined")
_bench "after merged tmux (setup+capture)"
setup_out=${combined_out%%$'\n\x1f\n'*}
cap_out=${combined_out#*$'\n\x1f\n'}

# Setup output: <picker_pane_id>\n\x1c\n<list-panes rows>.
# After select-layout, list-panes returns rows in pane_index order, which
# matches (top, left) order. Skipping the bash sort saves a coproc-style
# subshell + per-line printf.
picker_pane_id=${setup_out%%$'\n\x1c\n'*}
declare -a picker_panes
declare -A picker_tty
while IFS=$'\t' read -r _t _l _pid _tty; do
    [[ -z $_pid ]] && continue
    picker_panes+=("$_pid")
    picker_tty[$_pid]=$_tty
done <<< "${setup_out#*$'\n\x1c\n'}"

# picker_pane_id already lands at current_idx because the merged tmux call
# included a swap-pane to that effect (see "Realign" comment above).

# Feed gawk: tty list (one per line, blank-line terminator), then captures,
# then close stdin to signal EOF. gawk's END block writes per-pane payloads
# straight to the picker ptys — no bash distribution loop, no extra forks.
{
    for (( i=0; i<source_pane_count; i++ )); do
        printf '%s\n' "${picker_tty[${picker_panes[i]}]}"
    done
    printf '\n'
    printf '%s' "$cap_out"
} >&"${HINT[1]}"
exec {HINT[1]}>&-

# Read the hint table (terminated by \x1d). gawk fflushes after the table
# so this returns ~as soon as gawk's main loop finishes — well before the
# per-pane payloads land on the picker ttys.
declare -A match_by_hint
while IFS= read -r line <&"${HINT[0]}"; do
    [[ ${line:0:1} == $'\x1d' ]] && break
    hint=${line%%:*}
    match=${line#*:}
    [[ -n $hint ]] && match_by_hint[$hint]=$match
done
_bench "after read hint_table"

# RT3 prep: build swap_cmd and PICKER_PAIRS while gawk is still writing
# per-pane payloads to the picker ttys. By the time we wait on gawk's sync
# sentinel, the heavy shell work is done and only the swap-pane server work
# remains on the critical path.
swap_cmd=""
for (( i=0; i<source_pane_count; i++ )); do
    swap_cmd+="${swap_cmd:+ \\; }swap-pane -d -s ${source_panes[i]} -t ${picker_panes[i]}"
done
final_cmd="${swap_cmd}"
[[ $pane_was_zoomed == "1" ]] && final_cmd+=" \\; resize-pane -Z -t $picker_pane_id"

# Hand match table + context to hint_mode via one session-scoped env var.
printf -v _pairs 'last_pane_id=%q\ncurrent_pane_id=%q\npane_was_zoomed=%q\nswap_cmd=%q\n' \
    "$last_pane_id" "$current_pane_id" "$pane_was_zoomed" "$swap_cmd"
for hint in "${!match_by_hint[@]}"; do
    printf -v _row 'match_by_hint[%q]=%q\n' "$hint" "${match_by_hint[$hint]}"
    _pairs+=$_row
done

# Wait for gawk to finish TTY writes — its trailing \x1e marks completion.
IFS= read -r -N 1 -d '' _sync <&"${HINT[0]}" 2>/dev/null || true
exec {HINT[0]}<&-
wait "$HINT_PID" 2>/dev/null

eval "tmux $final_cmd"
_bench "after swap (HINTS VISIBLE)"

# Unblock hint_mode's `tmux wait-for "$picker_session"` (it will then read
# PICKER_PAIRS from the session env). show-env takes at most one var, so
# we pack everything into a single PICKER_PAIRS blob.
tmux setenv -t "$picker_session" PICKER_PAIRS "$_pairs" \
        \; wait-for -S "$picker_session"
