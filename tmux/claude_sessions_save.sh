#!/bin/bash
# claude_sessions_save.sh - tmux-resurrect post-save-all hook: snapshot which pane
# position (session, window, pane) holds which Claude session, for claude_resume.sh.

map="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/claude_sessions.tsv"
mkdir -p "${map%/*}"
tmux list-panes -a -F $'#{session_name}\t#{window_index}\t#{pane_index}\t#{@claude_session}' |
  awk -F'\t' '$4 != ""' > "$map.tmp" && mv "$map.tmp" "$map"
