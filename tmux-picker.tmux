#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$CURRENT_DIR/picker-config.sh"

# tmux global env is inherited by the picker session's child (hint_mode.sh +
# gawk), so set once here at config-load. No per-trigger fork or source.
tmux setenv -g PICKER_PATTERNS "$PICKER_PATTERNS" \
    \; setenv -g PICKER_HINT_FORMAT "$PICKER_HINT_FORMAT" \
    \; setenv -g PICKER_HIGHLIGHT_FORMAT "$PICKER_HIGHLIGHT_FORMAT"

tmux bind $PICKER_KEY run-shell "$CURRENT_DIR/tmux-picker.sh"
