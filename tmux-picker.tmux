#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# "-n M-/" for Alt-/ without prefix; "f" for prefix-F.
: ${PICKER_KEY:="-n M-/"}

tmux bind $PICKER_KEY run-shell "$CURRENT_DIR/tmux-picker.sh"
