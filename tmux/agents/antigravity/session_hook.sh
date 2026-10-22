#!/bin/bash
# session_hook.sh - Antigravity CLI SessionStart/PreInvocation hook: tag the tmux
# pane with the conversation ID (@antigravity_session) so sessions_save.sh can
# record it for resurrect. PreInvocation keeps the tag current after /resume or /fork.

payload="$(cat)"
echo '{}' # Hook protocol: always reply with valid JSON so the hook never counts as failed

[[ -z "${TMUX_PANE:-}" ]] && exit 0
conversation_id="$(jq -r '.conversationId // empty' <<<"$payload" 2>/dev/null)"
[[ -z "$conversation_id" ]] && exit 0

# Fast path: PreInvocation fires on every model call, and the tag rarely changes
[[ "$(tmux show-options -pqv -t "$TMUX_PANE" @antigravity_session 2>/dev/null)" == "$conversation_id" ]] && exit 0

# Only tag the pane's own agent, not a nested one started from inside it: the nearest
# non-shell ancestor (the CLI that ran this hook) must be the pane process or its direct child.
pane_pid="$(tmux display-message -t "$TMUX_PANE" -p '#{pane_pid}' 2>/dev/null)"
pid=$PPID
while [[ -n "$pid" && "$pid" -gt 1 ]]; do
  comm="$(ps -o comm= -p "$pid")"
  ppid="$(ps -o ppid= -p "$pid" | tr -d ' ')"
  case "${comm#-}" in
    sh | bash | dash | zsh) pid="$ppid" ;;
    *)
      [[ "$pid" == "$pane_pid" || "$ppid" == "$pane_pid" ]] &&
        tmux set-option -p -t "$TMUX_PANE" @antigravity_session "$conversation_id"
      exit 0
      ;;
  esac
done
exit 0
