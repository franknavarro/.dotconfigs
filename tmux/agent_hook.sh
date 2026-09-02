#!/bin/bash
# agent_hook.sh - Tmux status hook handler for agent CLI tools

event="${1:-}"
pane_id="${2:-${TMUX_PANE:-}}"

# Read target tmux pane if available
target=()
if [[ -n "$pane_id" ]]; then
  target=(-t "$pane_id")
fi

sync_window() {
  local w_id
  w_id="$(tmux display-message "${target[@]}" -p '#{window_id}' 2>/dev/null)"
  [[ -z "$w_id" ]] && return

  local w_status="0"
  local w_bell="0"
  while IFS=":" read -r p_agent p_bell; do
    if [[ "$p_agent" == "question" ]]; then
      w_status="question"
    elif [[ ( "$p_agent" == "done" || "$p_agent" == "1" ) && "$w_status" != "question" ]]; then
      w_status="done"
    fi
    if [[ "$p_bell" == "1" ]]; then
      w_bell="1"
    fi
  done < <(tmux list-panes -t "$w_id" -F '#{@agent_waiting}:#{@pane_bell}' 2>/dev/null)

  tmux set-option -w -t "$w_id" @agent_waiting "$w_status" 2>/dev/null
  tmux set-option -w -t "$w_id" @window_bell "$w_bell" 2>/dev/null
}

if [[ -n "${TMUX:-}" ]]; then
  case "$event" in
    question|PreToolUse)
      tmux set-option -p "${target[@]}" @agent_waiting question 2>/dev/null
      sync_window
      ;;
    tool_done|PostToolUse)
      tmux set-option -p "${target[@]}" @agent_waiting 0 2>/dev/null
      sync_window
      ;;
    done|Stop)
      is_active="$(tmux display-message "${target[@]}" -p '#{?#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}},1,0}' 2>/dev/null)"
      if [[ "$is_active" == "0" ]]; then
        tmux set-option -p "${target[@]}" @agent_waiting done 2>/dev/null
      else
        tmux set-option -p "${target[@]}" @agent_waiting 0 2>/dev/null
      fi
      sync_window
      ;;
    clear|PreInvocation)
      tmux set-option -p "${target[@]}" @agent_waiting 0 2>/dev/null
      sync_window
      ;;
    focus_pane)
      tmux set-option -p "${target[@]}" @pane_bell 0 2>/dev/null
      cur_agent="$(tmux display-message "${target[@]}" -p '#{@agent_waiting}' 2>/dev/null)"
      if [[ "$cur_agent" == "done" || "$cur_agent" == "1" ]]; then
        tmux set-option -p "${target[@]}" @agent_waiting 0 2>/dev/null
      fi
      sync_window
      ;;
    bell)
      is_active="$(tmux display-message "${target[@]}" -p '#{?#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}},1,0}' 2>/dev/null)"
      if [[ "$is_active" == "0" ]]; then
        tmux set-option -p "${target[@]}" @pane_bell 1 2>/dev/null
        sync_window
      fi
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
