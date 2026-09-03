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
  done < <(tmux list-panes -t "$w_id" -F '#{@p_agent}:#{@p_bell}' 2>/dev/null)

  tmux set-option -w -t "$w_id" @w_agent "$w_status" 2>/dev/null
  tmux set-option -w -t "$w_id" @w_bell "$w_bell" 2>/dev/null
}

cancel_timer() {
  local p="${pane_id:-${TMUX_PANE:-}}"
  [[ -z "$p" ]] && return
  local pid_file="/tmp/tmux_agent_q_${p//%/}.pid"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file" 2>/dev/null)"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    rm -f "$pid_file"
  fi
}

start_timer() {
  local p="${pane_id:-${TMUX_PANE:-}}"
  [[ -z "$p" ]] && return
  cancel_timer
  local pid_file="/tmp/tmux_agent_q_${p//%/}.pid"
  (
    sleep 0.25
    tmux set-option -p -t "$p" @p_agent question 2>/dev/null
    w_id="$(tmux display-message -t "$p" -p '#{window_id}' 2>/dev/null)"
    if [[ -n "$w_id" ]]; then
      w_status="0"
      w_bell="0"
      while IFS=":" read -r p_agent p_bell; do
        if [[ "$p_agent" == "question" ]]; then
          w_status="question"
        elif [[ ( "$p_agent" == "done" || "$p_agent" == "1" ) && "$w_status" != "question" ]]; then
          w_status="done"
        fi
        if [[ "$p_bell" == "1" ]]; then
          w_bell="1"
        fi
      done < <(tmux list-panes -t "$w_id" -F '#{@p_agent}:#{@p_bell}' 2>/dev/null)
      tmux set-option -w -t "$w_id" @w_agent "$w_status" 2>/dev/null
      tmux set-option -w -t "$w_id" @w_bell "$w_bell" 2>/dev/null
    fi
    rm -f "$pid_file"
  ) &
  echo $! > "$pid_file"
}

if [[ -n "${TMUX:-}" ]]; then
  case "$event" in
    question)
      cancel_timer
      tmux set-option -p "${target[@]}" @p_agent question 2>/dev/null
      sync_window
      ;;
    tool_pre)
      start_timer
      ;;
    tool_done|PostToolUse)
      cancel_timer
      tmux set-option -p "${target[@]}" @p_agent 0 2>/dev/null
      sync_window
      ;;
    done|Stop)
      cancel_timer
      is_active="$(tmux display-message "${target[@]}" -p '#{?#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}},1,0}' 2>/dev/null)"
      if [[ "$is_active" == "0" ]]; then
        tmux set-option -p "${target[@]}" @p_agent done 2>/dev/null
      else
        tmux set-option -p "${target[@]}" @p_agent 0 2>/dev/null
      fi
      sync_window
      ;;
    clear|PreInvocation)
      cancel_timer
      tmux set-option -p "${target[@]}" @p_agent 0 2>/dev/null
      sync_window
      ;;
    focus_pane)
      tmux set-option -p "${target[@]}" @p_bell 0 2>/dev/null
      cur_agent="$(tmux display-message "${target[@]}" -p '#{@p_agent}' 2>/dev/null)"
      if [[ "$cur_agent" == "done" || "$cur_agent" == "1" ]]; then
        tmux set-option -p "${target[@]}" @p_agent 0 2>/dev/null
      fi
      sync_window
      ;;
  esac
fi

# Output valid hook JSON response protocol (only for agent lifecycle events)
case "$event" in
  question|tool_pre|PreToolUse)
    echo '{"decision": "allow"}'
    ;;
  done|Stop)
    echo '{"decision": "stop"}'
    ;;
  tool_done|PostToolUse|clear|PreInvocation)
    echo '{}'
    ;;
  *)
    # Internal tmux events (focus_pane, etc.) - silent
    ;;
esac
