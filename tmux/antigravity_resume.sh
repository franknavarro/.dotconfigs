#!/bin/bash
# antigravity_resume.sh - tmux-resurrect restore command for Antigravity CLI panes: resume the
# conversation this pane held at the last save (see antigravity_sessions_save.sh), else start
# a new one.
#
# Usage: antigravity_resume.sh [command [app_data_dir]]
#   command       CLI to launch (default: agy)
#   app_data_dir  where the CLI keeps conversations (<app_data_dir>/brain/<id>), used to skip
#                 conversations that were deleted (default: ~/.gemini/antigravity-cli; the
#                 check is skipped if <app_data_dir>/brain doesn't exist)

cmd="${1:-agy}"
data_dir="${2:-$HOME/.gemini/antigravity-cli}"
map="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/antigravity_sessions.tsv"
pos="$(tmux display-message -t "$TMUX_PANE" -p $'#{session_name}\t#{window_index}\t#{pane_index}')"
conversation_id="$(awk -F'\t' -v pos="$pos" '$1 "\t" $2 "\t" $3 == pos { print $4; exit }' "$map" 2>/dev/null)"

if [[ -n "$conversation_id" ]] && [[ ! -d "$data_dir/brain" || -d "$data_dir/brain/$conversation_id" ]]; then
  # Re-tag now so an auto-save before the first hook fires doesn't drop this pane
  tmux set-option -p -t "$TMUX_PANE" @antigravity_session "$conversation_id"
  exec "$cmd" --conversation "$conversation_id"
fi
exec "$cmd"
