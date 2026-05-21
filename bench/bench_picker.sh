#!/usr/bin/env bash
# Bench tmux-picker.sh end-to-end on an isolated tmux server.
# Usage: bench/bench_picker.sh [plugin_dir] [runs] [panes]
#   plugin_dir defaults to the repo root (../ from this script)
#   runs       defaults to 20
#   panes      CSV of pane counts to bench, e.g. "1,2,4". Default "4".
#
# Measures the wall-clock delta from `_bench start` (top of tmux-picker.sh)
# to `_bench "after swap (HINTS VISIBLE)"` (the moment the user sees hints).
# Each run uses a fresh tmux server (-L picker_bench_$$) so server warm
# state and picker_session-$$ collisions don't pollute results. After each
# run the server is killed.
#
# Env:
#   BENCH_KEEP_RESULTS=1 — keep the raw per-run ms file and print its path.
#   NO_COLOR=1           — disable ANSI color output.
#
# Requires bash 4.4+ (mapfile -d), gawk, tmux 3.x.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_DIR=${1:-$(cd "$SCRIPT_DIR/.." && pwd)}
RUNS=${2:-20}
PANES_SPEC=${3:-4}
SOCKET="picker_bench_$$"
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/tmux-picker-bench-XXXXXX")
LOG="$WORKDIR/run.log"
RESULT="$WORKDIR/results.txt"

# ANSI colors. Auto-disable for non-TTY stderr or when NO_COLOR is set.
if [[ -z ${NO_COLOR:-} ]] && [[ -t 2 ]]; then
    C_BOLD=$'\e[1m';  C_DIM=$'\e[2m';   C_RESET=$'\e[0m'
    C_RED=$'\e[31m';  C_GREEN=$'\e[32m';C_YELLOW=$'\e[33m'
    C_CYAN=$'\e[36m'; C_MAGENTA=$'\e[35m'
else
    C_BOLD=; C_DIM=; C_RESET=
    C_RED=;  C_GREEN=; C_YELLOW=
    C_CYAN=; C_MAGENTA=
fi

# Sample content rich in patterns the hinter matches: paths, URLs, SHAs,
# IPs, UUIDs. Realistic terminal output of ~30 lines.
SAMPLE=$(cat <<'EOF'
$ git log --oneline | head
ca3b091 refactor: inline patterns and formats
f71a8cc enable bracketed paste
4505770 fix: hint patterns on per-character SGR lines
671cdfd Revert "fix: match patterns through per-character SGR coloring"
a3cdb95 refactor: trim verbose comments
$ ls -la /Users/example/.tmux/plugins/tmux-picker/
total 48
-rwxr-xr-x   1 user staff 8123 hint_mode.sh
-rw-r--r--   1 user staff 9876 hinter.awk
-rwxr-xr-x   1 user staff 7654 tmux-picker.sh
$ curl https://github.com/morantron/tmux-fingers
HTTP/2 200
$ ssh user@10.0.0.42 'uptime'
12:35:01 up 42 days
$ docker ps
abc123def456 nginx:1.25  /docker-entrypoint  ago  80/tcp
ed5f4a1b9c2d redis:7.2   /usr/local/bin/redi  hrs  6379/tcp
$ python3 -c 'import this'
The Zen of Python, by Tim Peters
$ ip addr | grep inet
inet 192.168.1.42/24 brd 192.168.1.255
inet6 fe80::1234:5678:9abc:def0/64 scope link
$ shasum file.txt
3da541559918a808c2402bba5012f6c60b27661c  file.txt
sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
$ uuidgen
550e8400-e29b-41d4-a716-446655440000
EOF
)

cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP
    # Kill any picker child still attached to the bench socket and the
    # bench tmux server itself. `kill-server` reaps server-side panes
    # (including the sleep 2147483647 placeholders).
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    # Reap any direct children (e.g. the inner tmux client that spawned
    # tmux-picker.sh) the script may have left behind on a signal.
    local pids
    pids=$(jobs -pr 2>/dev/null || true)
    [[ -n $pids ]] && kill $pids 2>/dev/null || true
    # tmux usually unlinks its socket on server exit, but leaves it
    # behind on abnormal exits. Explicitly remove it.
    rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET" 2>/dev/null || true
    if [[ ${BENCH_KEEP_RESULTS:-0} == 1 && -s $RESULT ]]; then
        local keep="${TMPDIR:-/tmp}/tmux-picker-bench-results-$$.txt"
        cp "$RESULT" "$keep" 2>/dev/null && \
            printf '%skept results: %s%s\n' "$C_DIM" "$keep" "$C_RESET" >&2
    fi
    rm -rf "$WORKDIR"
    exit "$rc"
}
trap cleanup EXIT INT TERM HUP

run_once() {
    local n_panes=${1:-1}
    : > "$LOG"
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    tmux -L "$SOCKET" new-session -d -s bench -x 200 -y 80 'cat'
    # Add additional panes (each running cat) and paste sample into each.
    # Use even-vertical layout so pane geometry is deterministic.
    local i
    for ((i=1; i<n_panes; i++)); do
        tmux -L "$SOCKET" split-window -t bench -d 'cat'
    done
    (( n_panes > 1 )) && tmux -L "$SOCKET" select-layout -t bench even-vertical >/dev/null
    printf '%s\n' "$SAMPLE" | tmux -L "$SOCKET" load-buffer -
    # Paste sample into every pane so each has hint-worthy content.
    local pids
    mapfile -t pids < <(tmux -L "$SOCKET" list-panes -t bench -F '#{pane_id}')
    for p in "${pids[@]}"; do
        tmux -L "$SOCKET" paste-buffer -t "$p"
    done
    sleep 0.05
    local TMUX_VAR
    TMUX_VAR=$(tmux -L "$SOCKET" display -t bench -p '#{socket_path},#{session_id}')
    TMUX_PICKER_BENCH=1 \
    TMUX_PICKER_BENCH_FILE="$LOG" \
    TMUX="$TMUX_VAR" \
    "$PLUGIN_DIR/tmux-picker.sh" >/dev/null 2>&1 || true
    # Wait briefly for hint_mode.sh to flush its line.
    for ((i=0; i<10; i++)); do
        grep -q "after swap (HINTS VISIBLE)" "$LOG" && break
        sleep 0.02
    done
    awk -F$'\t' '
        $3 == "start" && !s { s = $1 }
        $3 == "after swap (HINTS VISIBLE)" && !e { e = $1 }
        END { if (s && e) printf "%.3f\n", (e - s) * 1000 }
    ' "$LOG"
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    sleep 0.05
}

IFS=',' read -r -a PANES_LIST <<< "$PANES_SPEC"

printf '%s==>%s %sbenchmarking%s %s%s%s on socket %s%s%s (%s%d%s runs/scenario, panes=%s%s%s)\n' \
    "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" \
    "$C_MAGENTA" "$PLUGIN_DIR" "$C_RESET" \
    "$C_MAGENTA" "$SOCKET" "$C_RESET" \
    "$C_BOLD" "$RUNS" "$C_RESET" \
    "$C_BOLD" "$PANES_SPEC" "$C_RESET" >&2

declare -A SUMMARY
for n_panes in "${PANES_LIST[@]}"; do
    [[ $n_panes =~ ^[0-9]+$ ]] || { printf '%sskip invalid pane count: %s%s\n' "$C_RED" "$n_panes" "$C_RESET" >&2; continue; }

    printf '\n%s--%s %s%d-pane%s scenario\n' \
        "$C_CYAN" "$C_RESET" "$C_BOLD" "$n_panes" "$C_RESET" >&2

    printf '  %swarm-up...%s ' "$C_DIM" "$C_RESET" >&2
    run_once "$n_panes" >/dev/null 2>&1 || true
    printf '%sdone%s\n' "$C_DIM" "$C_RESET" >&2

    : > "$RESULT"
    for ((i=1; i<=RUNS; i++)); do
        ms=$(run_once "$n_panes")
        if [[ -n $ms ]]; then
            echo "$ms" >> "$RESULT"
            printf '  run %s%2d%s: %s%7s%s ms\n' \
                "$C_DIM" "$i" "$C_RESET" \
                "$C_GREEN" "$ms" "$C_RESET" >&2
        else
            printf '  run %s%2d%s: %sFAILED%s\n' \
                "$C_DIM" "$i" "$C_RESET" \
                "$C_RED" "$C_RESET" >&2
        fi
    done

    SUMMARY[$n_panes]=$(C_BOLD="$C_BOLD" C_DIM="$C_DIM" C_RESET="$C_RESET" \
        C_GREEN="$C_GREEN" C_YELLOW="$C_YELLOW" C_RED="$C_RED" C_CYAN="$C_CYAN" \
        awk -v panes="$n_panes" '
            BEGIN {
                BOLD = ENVIRON["C_BOLD"];   DIM = ENVIRON["C_DIM"]
                RST  = ENVIRON["C_RESET"];  GRN = ENVIRON["C_GREEN"]
                YLW  = ENVIRON["C_YELLOW"]; RED = ENVIRON["C_RED"]
                CYN  = ENVIRON["C_CYAN"]
            }
            {
                a[NR] = $1+0; s += $1
                if (NR==1 || $1+0 < min) min = $1+0
                if (NR==1 || $1+0 > max) max = $1+0
            }
            END {
                n = NR
                if (n == 0) { printf "%sno successful runs (panes=%d)%s\n", RED, panes, RST; exit }
                asort(a)
                p50 = a[int((n+1)/2)]
                p90 = a[int(n*0.9)]
                printf "%s=== panes=%d, %d runs (ms) ===%s\n", BOLD, panes, n, RST
                printf "  %smin %s  = %s%7.1f%s\n", DIM, RST, GRN, min, RST
                printf "  %sp50 %s  = %s%7.1f%s\n", DIM, RST, GRN, p50, RST
                printf "  %sp90 %s  = %s%7.1f%s\n", DIM, RST, YLW, p90, RST
                printf "  %smax %s  = %s%7.1f%s\n", DIM, RST, RED, max, RST
                printf "  %smean%s  = %s%7.1f%s\n", DIM, RST, CYN, s/n, RST
            }' "$RESULT")
done

printf '\n' >&2
for n_panes in "${PANES_LIST[@]}"; do
    [[ -n ${SUMMARY[$n_panes]:-} ]] || continue
    printf '%s\n' "${SUMMARY[$n_panes]}" >&2
done
