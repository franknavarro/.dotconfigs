#!/bin/bash
# session_tabs.sh - Multi-session status aggregator and powerline renderer (Line 0)
#
# Modes:
#   session_tabs.sh --sync [--no-refresh]
#     Compiles client-session-aware powerline pills into the global `@session_tabs_fmt`
#     tmux option (updating only when changed) so Line 0 renders in the exact same
#     frame as Line 1 and pane borders with zero `#(...)` blanking or lag.
#   session_tabs.sh --reap
#     Silently reaps markers from exited CLI processes, refreshes `@session_tabs_fmt`
#     if needed, and outputs nothing so tmux's periodic `#(...)` check never blanks.
#   session_tabs.sh [is_prefix] [current_session]
#     Emits the full standalone Line 0 powerline string directly to stdout.

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook_script="${SCRIPT_DIR}/agents/agent_hook.sh"
[[ ! -x "$hook_script" ]] && hook_script="$HOME/.dotconfigs/tmux/agents/agent_hook.sh"

base_state_root="${XDG_RUNTIME_DIR:-/tmp}/tmux_agent_${USER:-$(id -u)}"
tmux_sock_path="${TMUX:-}"
tmux_sock_path="${tmux_sock_path%%,*}"
tmux_sock_name="${tmux_sock_path##*/}"
if [[ -n "$tmux_sock_name" && "$tmux_sock_name" != "default" ]]; then
  state_root="${base_state_root}_${tmux_sock_name//[^A-Za-z0-9_-]/_}"
else
  state_root="$base_state_root"
fi

if [[ "${1:-}" == "--sync" ]]; then
  if [[ -x "$hook_script" ]]; then
    if [[ "${2:-}" == "--no-refresh" ]]; then
      exec "$hook_script" sync_window --no-refresh
    else
      exec "$hook_script" sync_window
    fi
  fi
  exit 0
fi

pid_is_alive() {
  local p="$1"
  [[ -z "$p" || ! "$p" =~ ^[0-9]+$ || "$p" -le 0 ]] && return 0
  if [[ -d /proc ]]; then
    [[ -d "/proc/${p}" ]]
    return $?
  fi
  kill -0 "$p" 2>/dev/null || ps -p "$p" >/dev/null 2>&1
}

file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo "${2:-0}"
}

if [[ "${1:-}" == "--reap" ]]; then
  [[ -z "${TMUX:-}" || ! -x "$hook_script" ]] && exit 0

  srv_tail="${TMUX#*,}"
  srv_pid="${srv_tail%%,*}"
  cur_srv=""
  [[ -r "${state_root}/.server_pid" ]] && cur_srv="$(<"${state_root}/.server_pid")"
  if [[ "$cur_srv" != "$srv_pid" ]] || [[ -z "$(tmux show-options -gqv @session_tabs_fmt 2>/dev/null)" ]]; then
    "$hook_script" sync_window >/dev/null 2>&1
  fi

  if [[ -d "$state_root" ]]; then
    now=""
    for p_dir in "${state_root}"/*; do
      [[ -d "$p_dir" ]] || continue
      p_num="${p_dir##*/}"
      [[ "$p_num" =~ ^[0-9]+$ ]] || continue
      needs_reap=0
      for mf in "${p_dir}"/active/* "${p_dir}/awaiting_idle" "${p_dir}"/question/*; do
        [[ -e "$mf" ]] || continue
        m_pid=""
        IFS='|' read -r _ _ m_pid <"$mf" 2>/dev/null || true
        if [[ -n "$m_pid" ]] && ! pid_is_alive "$m_pid"; then
          needs_reap=1
          break
        fi
        if [[ "$mf" == "${p_dir}/question/"*.sub ]]; then
          [[ -z "$now" ]] && now="$(date +%s)"
          mtime="$(file_mtime "$mf" "$now")"
          if ((now - mtime > 125)); then
            needs_reap=1
            break
          fi
        fi
      done
      if ((needs_reap == 1)); then
        "$hook_script" _recompute "%${p_num}" >/dev/null 2>&1
      fi
    done
  fi
  exit 0
fi

# Standalone render mode: aggregate session statuses (`question > done > running > bell > alert`)
declare -A session_status=()
declare -A status_rank=(
  ["none"]=0
  ["alert"]=1
  ["bell"]=2
  ["running"]=3
  ["done"]=4
  ["question"]=5
)

while IFS=$'\x1f' read -r s_name s_pane s_agent s_pbell s_wbell s_alerts s_wactive s_attached; do
  [[ -z "$s_name" ]] && continue
  if [[ "$s_agent" == "running" || "$s_agent" == "question" ]]; then
    p_dir="${state_root}/${s_pane//%/}"
    if [[ -d "$p_dir" ]]; then
      for mf in "${p_dir}"/active/* "${p_dir}/awaiting_idle" "${p_dir}"/question/*; do
        [[ -e "$mf" ]] || continue
        m_pid=""
        IFS='|' read -r _ _ m_pid <"$mf" 2>/dev/null || true
        if [[ -n "$m_pid" ]] && ! pid_is_alive "$m_pid"; then
          [[ -x "$hook_script" ]] && "$hook_script" _recompute "$s_pane" >/dev/null 2>&1 &
          break
        fi
      done
    fi
  fi

  # Ignore sticky window_bell_flag / window_alerts on the currently focused window
  # of an attached session (unless a pane explicitly holds @p_bell == 1).
  if [[ "$s_wactive" == "1" && "$s_attached" == "1" ]]; then
    s_wbell="0"
    s_alerts="${s_alerts//!}"
  fi

  cand="none"
  if [[ "$s_agent" == "question" ]]; then
    cand="question"
  elif [[ "$s_agent" == "done" || "$s_agent" == "1" ]]; then
    cand="done"
  elif [[ "$s_agent" == "running" ]]; then
    cand="running"
  elif [[ "$s_pbell" == "1" || "$s_wbell" == "1" || "$s_alerts" == *"!"* ]]; then
    cand="bell"
  elif [[ -n "$s_alerts" ]]; then
    cand="alert"
  fi

  cur="${session_status[$s_name]:-none}"
  if ((${status_rank[$cand]:-0} > ${status_rank[$cur]:-0})); then
    session_status["$s_name"]="$cand"
  fi
done < <(tmux list-panes -a -F $'#{session_name}\x1f#{pane_id}\x1f#{@p_agent}\x1f#{@p_bell}\x1f#{window_bell_flag}\x1f#{window_alerts}\x1f#{window_active}\x1f#{session_attached}' 2>/dev/null)

bg_main="#44475a"
bg_selected="#bd93f9"
fg_selected="#000000"
text_main="#ffffff"
left_seperator=""
left_separator_sub=""

is_prefix="${1:-0}"
current_session="${2:-}"
if [[ -z "$current_session" ]]; then
  current_session="$(tmux display-message -p '#S' 2>/dev/null)"
fi

sessions="$(tmux list-sessions -F "#{session_name}" 2>/dev/null)"

fg_header="#000000"
if [[ "$is_prefix" == "1" ]]; then
  bg_header="#00ff22"
else
  bg_header="#ffff00"
fi

output="#[fg=$fg_header,bg=$bg_header,bold] ❒ SESSIONS #[nobold,fg=$bg_header,bg=$bg_main]$left_seperator "

prev_is_active=false
is_first=true
idx=0

while IFS= read -r s; do
  [[ -z "$s" ]] && continue
  flags=""
  if [[ "$s" == "$current_session" ]]; then
    case "${session_status[$s]:-}" in
      question) flags="#[fg=#8b2500,bg=$bg_selected,bold] #[fg=$fg_selected,bg=$bg_selected,bold]" ;;
      done)     flags="#[fg=#004d22,bg=$bg_selected,bold] #[fg=$fg_selected,bg=$bg_selected,bold]" ;;
      running)  flags="#[fg=#004488,bg=$bg_selected,bold] #[fg=$fg_selected,bg=$bg_selected,bold]" ;;
      bell)     flags="#[fg=#6b3a00,bg=$bg_selected,bold] #[fg=$fg_selected,bg=$bg_selected,bold]" ;;
      alert)    flags="#[fg=#990000,bg=$bg_selected,bold] #[fg=$fg_selected,bg=$bg_selected,bold]" ;;
    esac
    output+="#[fg=$bg_main,bg=$bg_selected]$left_seperator#[fg=$fg_selected,bg=$bg_selected,bold] ${flags}${idx} $s #[nobold,fg=$bg_selected,bg=$bg_main]$left_seperator"
    prev_is_active=true
  else
    case "${session_status[$s]:-}" in
      question) flags="#[fg=#ffb86c,bg=$bg_main] #[fg=$text_main,bg=$bg_main]" ;;
      done)     flags="#[fg=#50fa7b,bg=$bg_main] #[fg=$text_main,bg=$bg_main]" ;;
      running)  flags="#[fg=#8be9fd,bg=$bg_main] #[fg=$text_main,bg=$bg_main]" ;;
      bell)     flags="#[fg=#f1fa8c,bg=$bg_main] #[fg=$text_main,bg=$bg_main]" ;;
      alert)    flags="#[fg=#ff5555,bg=$bg_main] #[fg=$text_main,bg=$bg_main]" ;;
    esac
    if [[ "$is_first" == false && "$prev_is_active" == false ]]; then
      output+="#[fg=$text_main,bg=$bg_main]$left_separator_sub "
    fi
    output+="#[fg=$text_main,bg=$bg_main] ${flags}${idx} $s "
    prev_is_active=false
  fi
  is_first=false
  ((idx++))
done <<<"$sessions"

echo "$output"
