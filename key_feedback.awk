BEGIN {
    RS = "\x1e"

    HINT_STYLE = "\x1b[38;2;0;0;0;48;2;255;140;0;1m"
    PRESSED_HINT_STYLE = "\x1b[38;2;255;255;255;48;2;145;70;0;1m"
    SUBDUED_HINT_STYLE = "\x1b[38;2;220;220;220;48;2;55;55;55;1m"
    SUBDUED_MATCH_STYLE = "\x1b[38;2;130;130;130;48;2;55;55;55;1m"
    HIGHLIGHT_STYLE = "\x1b[38;2;255;255;255;48;2;0;102;204;1m"
    RESET_STYLE = "\x1b[0m"
    COMPOUND_SEPARATOR = RESET_STYLE HIGHLIGHT_STYLE
    frames_loaded = 0
}

function recolor(text,    output, rest, start, split_at, hint, match_tail,
                 match_end, visible_match, matches_prefix, i, style) {
    output = ""
    rest = text

    while ((start = index(rest, HINT_STYLE)) > 0) {
        output = output substr(rest, 1, start - 1)
        rest = substr(rest, start + length(HINT_STYLE))
        split_at = index(rest, COMPOUND_SEPARATOR)

        # Preserve unrelated text that happens to use the base hint style.
        if (split_at == 0) {
            return output HINT_STYLE rest
        }
        hint = substr(rest, 1, split_at - 1)
        if (hint !~ /^[a-z]+$/) {
            output = output HINT_STYLE
            continue
        }

        match_tail = substr(rest, split_at + length(COMPOUND_SEPARATOR))
        match_end = index(match_tail, RESET_STYLE)
        if (match_end == 0) {
            return output HINT_STYLE rest
        }
        visible_match = substr(match_tail, 1, match_end - 1)
        rest = substr(match_tail, match_end + length(RESET_STYLE))
        matches_prefix = (prefix == "" ||
                          substr(hint, 1, length(prefix)) == prefix)

        if (prefix == "") {
            output = output HINT_STYLE hint COMPOUND_SEPARATOR \
                     visible_match RESET_STYLE
            continue
        }
        if (!matches_prefix) {
            output = output SUBDUED_HINT_STYLE hint RESET_STYLE \
                     SUBDUED_MATCH_STYLE visible_match RESET_STYLE
            continue
        }

        for (i = 1; i <= length(hint); i++) {
            style = (i <= length(prefix)) ? PRESSED_HINT_STYLE : HINT_STYLE
            output = output style substr(hint, i, 1) RESET_STYLE
        }
        output = output HIGHLIGHT_STYLE visible_match RESET_STYLE
    }

    return output rest
}

{
    if (!frames_loaded) {
        if ($0 == "\x1d") {
            frames_loaded = 1
            RS = "\n"
            print "ready"
            fflush()
            next
        }

        separator = index($0, "\x1f")
        if (separator == 0)
            next
        n_frames++
        tty_by_idx[n_frames] = substr($0, 1, separator - 1)
        frame_by_idx[n_frames] = substr($0, separator + 1)
        next
    }

    prefix = tolower($0)
    for (i = 1; i <= n_frames; i++) {
        printf "%s", recolor(frame_by_idx[i]) > tty_by_idx[i]
        close(tty_by_idx[i])
    }
    print "done"
    fflush()
}
