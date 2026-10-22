#!/bin/bash
# session_hook.sh - Claude Code SessionStart hook: tag the tmux pane with the
# session ID (@claude_session) so sessions_save.sh can record it for resurrect.

[[ -z "${TMUX_PANE:-}" ]] && exit 0
session_id="$(jq -r '.session_id // empty')"
[[ -z "$session_id" ]] && exit 0

# Only tag the pane's own claude, not a nested `claude -p` started from inside it:
# the nearest claude ancestor must be the pane process or its direct child.
pane_pid="$(tmux display-message -t "$TMUX_PANE" -p '#{pane_pid}' 2>/dev/null)"
pid=$PPID
while [[ -n "$pid" && "$pid" -gt 1 ]]; do
  args="$(ps -o args= -p "$pid")"
  cmd="${args%% *}"
  ppid="$(ps -o ppid= -p "$pid" | tr -d ' ')"
  if [[ "${cmd##*/}" == "claude" ]]; then
    [[ "$pid" == "$pane_pid" || "$ppid" == "$pane_pid" ]] || exit 0
    tmux set-option -p -t "$TMUX_PANE" @claude_session "$session_id"
    exit 0
  fi
  pid="$ppid"
done
