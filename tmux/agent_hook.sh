#!/bin/bash
# agent_hook.sh - Tmux status hook handler for agent CLI tools

event="${1:-}"

# Read target tmux pane if available
target=()
if [[ -n "${TMUX_PANE:-}" ]]; then
  target=(-t "$TMUX_PANE")
fi

if [[ -n "${TMUX:-}" ]]; then
  case "$event" in
    question|PreToolUse)
      # Always mark as question; persists across window navigation until tool completion
      tmux set-option "${target[@]}" -w @agent_waiting question 2>/dev/null
      ;;
    tool_done|PostToolUse)
      # Clear question state when user response / tool execution finishes
      tmux set-option "${target[@]}" -w @agent_waiting 0 2>/dev/null
      ;;
    done|Stop)
      # Check if window is currently active in an attached session
      is_active="$(tmux display-message "${target[@]}" -p '#{?#{&&:#{window_active},#{session_attached}},1,0}' 2>/dev/null)"
      if [[ "$is_active" == "0" ]]; then
        tmux set-option "${target[@]}" -w @agent_waiting done 2>/dev/null
      else
        tmux set-option "${target[@]}" -w @agent_waiting 0 2>/dev/null
      fi
      ;;
    clear|PreInvocation)
      # Reset status when starting a new prompt / turn
      tmux set-option "${target[@]}" -w @agent_waiting 0 2>/dev/null
      ;;
  esac
fi

# Output valid hook JSON response protocol
case "$event" in
  question|PreToolUse)
    echo '{"decision": "allow"}'
    ;;
  done|Stop)
    echo '{"decision": "stop"}'
    ;;
  *)
    echo '{}'
    ;;
esac
