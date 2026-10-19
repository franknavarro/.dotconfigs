#!/bin/bash
# claude_resume.sh - tmux-resurrect restore command for Claude panes: resume the session
# this pane held at the last save (see claude_sessions_save.sh), else start a new one.

map="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/claude_sessions.tsv"
pos="$(tmux display-message -t "$TMUX_PANE" -p $'#{session_name}\t#{window_index}\t#{pane_index}')"
session_id="$(awk -F'\t' -v pos="$pos" '$1 "\t" $2 "\t" $3 == pos { print $4; exit }' "$map" 2>/dev/null)"

if [[ -n "$session_id" ]] && compgen -G "$HOME/.claude/projects/*/$session_id.jsonl" >/dev/null; then
  # Re-tag now so an auto-save before SessionStart fires doesn't drop this pane
  tmux set-option -p -t "$TMUX_PANE" @claude_session "$session_id"
  exec claude --resume "$session_id"
fi
exec claude
