#!/bin/bash
# antigravity_sessions_save.sh - tmux-resurrect post-save-all hook: snapshot which pane
# position (session, window, pane) holds which Antigravity CLI conversation, for
# antigravity_resume.sh.

map="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/antigravity_sessions.tsv"
mkdir -p "${map%/*}"
tmux list-panes -a -F $'#{session_name}\t#{window_index}\t#{pane_index}\t#{@antigravity_session}' |
  awk -F'\t' '$4 != ""' > "$map.tmp" && mv "$map.tmp" "$map"
