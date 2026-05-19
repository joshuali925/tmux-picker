#!/usr/bin/env bash
# Defaults — users override by setting the var before tmux-picker.tmux runs.

# "-n M-/" for Alt-/ without prefix; "f" for prefix-F.
: ${PICKER_KEY:="-n M-/"}

# Each pattern is ((prefix)body); hinter.awk strips the prefix from the hint
# text. SP anchors matches outside ANSI escapes (capture-pane -e leaves them
# in the stream); FCS allows escapes inside the body so a path can span color
# resets between segments. SP-prefixed arms share one ((SP)(body|...)) wrapper
# so the regex engine has fewer top-level alternations to track per match.
# CS bound is `+` (no upper) — terminated by `m`. Earlier `{1,9}` silently
# stopped matching 24-bit SGR (\x1b[38;2;R;G;Bm = 16 inner chars), and `{1,32}`
# is measurably slower in gawk's regex engine than `+`.
if [[ -z ${PICKER_PATTERNS:-} ]]; then
    _CS=$'\x1b'"\[[0-9;]+m"
    _START_DELIM="[[:space:]:<>)(&#'\"]"
    _SP="($_CS|^|$_START_DELIM)"
    _FCS="([[:alnum:]_.%/~-]|$_CS)"
    _SP_BODIES=(
    "${_FCS}*[./]${_FCS}+"                                                                              # filename or path
    "(ds|i)-[[:alnum:]_]+"
    "[0-9]+:[[:alnum:]_-]+"
    "(https?://|git@|git://|ssh://|ftp://|file://)[^[:space:]]+"
    "#[0-9a-fA-F]{6}"
    "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"                                      # uuid
    "Qm[[:alnum:]]{44}"                                                                                 # ipfs
    "[0-9a-f]{7,40}"                                                                                    # sha
    "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"                                                    # ipv4
    "[A-Fa-f0-9:]+:+[A-Fa-f0-9:]+[%[:alnum:]_]+"                                                        # ipv6
    "0x[0-9a-fA-F]+"
    "[0-9]{4,}"
    )
    _PATTERNS_LIST=(
    "(${_SP}($(IFS='|'; echo "${_SP_BODIES[*]}")))"
    "((\[[^]]*\]\()[^)]+)"                                                                              # markdown_url
    "((--- a/)[^[:space:]]+)"
    "((\+\+\+ b/)[^[:space:]]+)"
    "((sha256:)[0-9a-f]{64})"
    )
    PICKER_PATTERNS=$(IFS='|'; echo "${_PATTERNS_LIST[*]}")
    unset _CS _START_DELIM _SP _FCS _SP_BODIES _PATTERNS_LIST
fi

# Direct ANSI escapes — tput emits SI/^O bytes that tmux 3.4+ mangles.
: ${PICKER_HINT_FORMAT:=$'\x1b[38;2;0;0;0;48;2;255;140;0;1m%s\x1b[0m'}
: ${PICKER_HIGHLIGHT_FORMAT:=$'\x1b[38;2;255;255;255;48;2;0;102;204;1m%s\x1b[0m'}
