#!/bin/bash
# agent_hook.sh - Tmux status hook handler for agent CLI tools
#
# Propagates per-pane agent lifecycle state (@p_agent) to window (@w_agent) and
# session status bars with strict precedence:
#   question > done > running > 0
#
# Concurrent conversations in one pane (a coordinator agent plus the subagents
# and background tasks it spawns) are tracked independently without flickering:
#
#   - Thinking / Running (`running`): Active from PreInvocation / UserPromptSubmit
#     through Stop across the root agent and any spawned subagents. When a root
#     turn pauses with `fullyIdle: false` while subagents or background tasks
#     continue working, `awaiting_idle` keeps the pane in `running` instead of
#     prematurely flashing `done` or dropping to idle.
#   - Interactive Prompts (`question`): For CLIs backed by a conversation SQLite
#     store (Antigravity CLI), `PreToolUse` watches the conversation `steps` table
#     for `WAITING` status (`status = 9`) rather than using an elapsed-time
#     heuristic, so slow auto-approved main or subagent tool calls never flash
#     false question indicators. Falls back to `@agent_question_delay` only for
#     CLIs without a conversation SQLite store (e.g. generic hooks).
#   - Turn Complete (`done`): Recorded only when the root conversation stops
#     with `fullyIdle: true` (and was not canceled by the user) while the pane
#     is unfocused. Clears automatically on pane focus.
#
# Tunables (tmux global options, read lazily):
#   @agent_question_delay        fallback delay (s) for non-SQLite CLIs (default 1.5)
#   @agent_no_prompt_tools       extended regex of tool names to skip watching
#   @agent_subagent_question_ttl seconds before a subagent question expires (default 120)
#   @agent_running_stale_ttl     seconds before idle-checking an active marker (default 90)
#
# Debugging: touch "$state_root/debug" to log events to "$state_root/debug.log".
# Manual reset for a stuck pane: agent_hook.sh reset [pane_id]

readonly SELF_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

event="${1:-}"
explicit_target="${2:-}"
pane_id="${2:-${TMUX_PANE:-}}"

readonly DEFAULT_DELAY="1.5"
readonly DEFAULT_NO_PROMPT_TOOLS='^(invoke_subagent|send_message|manage_task|manage_subagents|define_subagent|schedule|search_web|run_workflow|ask_.*)$'
readonly DEFAULT_SUBAGENT_TTL="120"
readonly DEFAULT_RUNNING_STALE_TTL="90"

base_state_root="${XDG_RUNTIME_DIR:-/tmp}/tmux_agent_${USER:-$(id -u)}"
tmux_sock_path="${TMUX:-}"
tmux_sock_path="${tmux_sock_path%%,*}"
tmux_sock_name="${tmux_sock_path##*/}"
if [[ -n "$tmux_sock_name" && "$tmux_sock_name" != "default" ]]; then
  state_root="${base_state_root}_${tmux_sock_name//[^A-Za-z0-9_-]/_}"
else
  state_root="$base_state_root"
fi

# Normalize lifecycle event names across Antigravity CLI and Claude Code
case "$event" in
  PreToolUse) event="tool_pre" ;;
  PostToolUse) event="tool_done" ;;
  PermissionRequest) event="question" ;;
  Stop) event="done" ;;
  PreInvocation | UserPromptSubmit | start) event="running" ;;
  PostInvocation) event="post_invocation" ;;
  SessionStart) event="session_start" ;;
esac

# Read JSON hook payload from stdin for agent lifecycle events
payload=""
case "$event" in
  question | tool_pre | tool_done | done | running | clear | post_invocation | session_start)
    if [[ ! -t 0 ]]; then
      payload="$(cat)"
    fi
    ;;
esac

# Extract identifiers from JSON payload before emitting output so `clear` hooks
# wired to `PreInvocation` in older configs transparently map to `running`.
raw_conv="default"
parent=""
step="na"
tool=""
artifact_dir=""
transcript_path=""
fully_idle="true"
term_reason=""
has_inv="0"
has_active_turn="0"

if [[ -n "$payload" ]] && command -v jq >/dev/null 2>&1; then
  IFS=$'\x1f' read -r raw_conv parent step tool artifact_dir transcript_path fully_idle term_reason has_inv has_active_turn < <(
    jq -r '[
      (.conversationId // .session_id // "default"),
      (.agent_id // .parent_session_id // ""),
      (.stepIdx // .tool_use_id // "na"),
      (.toolCall.name // .tool_name // ""),
      (.artifactDirectoryPath // ""),
      (.transcriptPath // ""),
      (if has("fullyIdle") then (.fullyIdle | tostring) else "true" end),
      (.terminationReason // ""),
      (if has("invocationNum") then "1" else "0" end),
      (if has("conversationId") or has("lastUserInput") or (.artifactDirectoryPath // "") != "" or (.transcriptPath // "") != "" then "1" else "0" end)
    ] | map(tostring | gsub("[\r\n\u001f]"; "")) | join("\u001f")' <<<"$payload" 2>/dev/null
  )
  raw_conv="${raw_conv:-default}"
  step="${step:-na}"
  fully_idle="${fully_idle:-true}"
fi

if [[ "$event" == "clear" && "$has_inv" == "1" ]]; then
  event="running"
fi

# Output valid hook JSON response protocol first (only for agent lifecycle events)
case "$event" in
  question | tool_pre) echo '{"decision": "allow"}' ;;
  done) echo '{"decision": "stop"}' ;;
  tool_done | running | clear | post_invocation | session_start) echo '{}' ;;
esac

[[ -z "${TMUX:-}" ]] && exit 0

# Synchronizes @p_agent, @p_bell, @w_agent, @w_bell, and @session_tabs_fmt in a
# single `;`-batched `tmux` command packet serialized under `${state_root}/sync.lock`
# so Pane Borders, Line 1 Window Tabs, and Line 0 Session Tabs update atomically
# in the exact same client frame without cross-pane snapshot races.
sync_all_surfaces_atomic() {
  local override_pane="${1:-}"
  local override_agent="${2:-__KEEP__}"
  local clear_pane_bell="${3:-0}"
  local reconcile_orphans="${4:-0}"
  local no_refresh="${5:-0}"

  mkdir -p "$state_root" 2>/dev/null

  (
    if command -v flock >/dev/null 2>&1; then
      flock -w 2 7 || exit 0
    fi

    declare -A seen_sess=()
    declare -A session_status=()
    declare -A status_rank=(
      ["none"]=0
      ["alert"]=1
      ["bell"]=2
      ["running"]=3
      ["done"]=4
      ["question"]=5
    )
    declare -A alive_panes=()
    declare -A win_status=()
    declare -A win_bell=()
    declare -A cur_win_status=()
    declare -A cur_win_bell=()
    local -a sess_ids=()
    local -a sess_names=()

    local orig_p_agent="0"
    local orig_p_bell="0"
    local found_override_pane=0
    local s_id s_name w_id cur_wa cur_wb p_id p_agent p_bell s_wbell s_alerts s_wactive s_attached
    local cur_w cand cur_s d d_name

    while IFS=$'\x1f' read -r s_id s_name w_id cur_wa cur_wb p_id p_agent p_bell s_wbell s_alerts s_wactive s_attached; do
      [[ -z "$s_id" || -z "$w_id" ]] && continue
      if [[ -z "${seen_sess[$s_id]:-}" ]]; then
        seen_sess["$s_id"]=1
        sess_ids+=("$s_id")
        sess_names+=("$s_name")
      fi
      [[ -n "$p_id" ]] && alive_panes["${p_id//%/}"]=1

      if [[ -n "$override_pane" && "$p_id" == "$override_pane" ]]; then
        found_override_pane=1
        orig_p_agent="${p_agent:-0}"
        orig_p_bell="${p_bell:-0}"
        if [[ "$override_agent" != "__KEEP__" ]]; then
          p_agent="$override_agent"
        fi
        if ((clear_pane_bell == 1)); then
          p_bell="0"
        fi
      fi

      cur_win_status["$w_id"]="${cur_wa:-0}"
      cur_win_bell["$w_id"]="${cur_wb:-0}"

      cur_w="${win_status[$w_id]:-0}"
      if [[ "$p_agent" == "question" ]]; then
        cur_w="question"
      elif [[ ("$p_agent" == "done" || "$p_agent" == "1") && "$cur_w" != "question" ]]; then
        cur_w="done"
      elif [[ "$p_agent" == "running" && "$cur_w" != "question" && "$cur_w" != "done" ]]; then
        cur_w="running"
      fi
      win_status["$w_id"]="$cur_w"
      if [[ "$p_bell" == "1" ]]; then
        win_bell["$w_id"]="1"
      else
        win_bell["$w_id"]="${win_bell[$w_id]:-0}"
      fi

      if [[ "$s_wactive" == "1" && "$s_attached" == "1" ]]; then
        s_wbell="0"
        s_alerts="${s_alerts//!}"
      fi
      cand="none"
      if [[ "$p_agent" == "question" ]]; then
        cand="question"
      elif [[ "$p_agent" == "done" || "$p_agent" == "1" ]]; then
        cand="done"
      elif [[ "$p_agent" == "running" ]]; then
        cand="running"
      elif [[ "$p_bell" == "1" || "$s_wbell" == "1" || "$s_alerts" == *"!"* ]]; then
        cand="bell"
      elif [[ -n "$s_alerts" ]]; then
        cand="alert"
      fi

      cur_s="${session_status[$s_name]:-none}"
      if ((${status_rank[$cand]:-0} > ${status_rank[$cur_s]:-0})); then
        session_status["$s_name"]="$cand"
      fi
    done < <(tmux list-panes -a -F $'#{session_id}\x1f#{session_name}\x1f#{window_id}\x1f#{@w_agent}\x1f#{@w_bell}\x1f#{pane_id}\x1f#{@p_agent}\x1f#{@p_bell}\x1f#{window_bell_flag}\x1f#{window_alerts}\x1f#{window_active}\x1f#{session_attached}' 2>/dev/null)

    local bg_main="#44475a"
    local bg_selected="#bd93f9"
    local fg_selected="#000000"
    local text_main="#ffffff"
    local left_seperator=""
    local left_separator_sub=""
    local rbrace='}'
    local fmt="" prev_id="" idx=0 count="${#sess_ids[@]}"
    local i esc_name act_flags inact_flags active_pill inactive_pill sub_sep

    for ((i = 0; i < count; i++)); do
      s_id="${sess_ids[$i]}"
      s_name="${sess_names[$i]}"
      esc_name="${s_name//#/##}"
      esc_name="${esc_name//,/#,}"
      esc_name="${esc_name//$rbrace/#$rbrace}"

      act_flags=""
      inact_flags=""
      case "${session_status[$s_name]:-none}" in
        question)
          act_flags="#[fg=#8b2500]#[bg=$bg_selected]#[bold] #[fg=$fg_selected]#[bg=$bg_selected]#[bold]"
          inact_flags="#[fg=#ffb86c]#[bg=$bg_main] #[fg=$text_main]#[bg=$bg_main]"
          ;;
        done)
          act_flags="#[fg=#004d22]#[bg=$bg_selected]#[bold] #[fg=$fg_selected]#[bg=$bg_selected]#[bold]"
          inact_flags="#[fg=#50fa7b]#[bg=$bg_main] #[fg=$text_main]#[bg=$bg_main]"
          ;;
        running)
          act_flags="#[fg=#004488]#[bg=$bg_selected]#[bold] #[fg=$fg_selected]#[bg=$bg_selected]#[bold]"
          inact_flags="#[fg=#8be9fd]#[bg=$bg_main] #[fg=$text_main]#[bg=$bg_main]"
          ;;
        bell)
          act_flags="#[fg=#6b3a00]#[bg=$bg_selected]#[bold] #[fg=$fg_selected]#[bg=$bg_selected]#[bold]"
          inact_flags="#[fg=#f1fa8c]#[bg=$bg_main] #[fg=$text_main]#[bg=$bg_main]"
          ;;
        alert)
          act_flags="#[fg=#990000]#[bg=$bg_selected]#[bold] #[fg=$fg_selected]#[bg=$bg_selected]#[bold]"
          inact_flags="#[fg=#ff5555]#[bg=$bg_main] #[fg=$text_main]#[bg=$bg_main]"
          ;;
      esac

      active_pill="#[fg=$bg_main]#[bg=$bg_selected]$left_seperator#[fg=$fg_selected]#[bg=$bg_selected]#[bold] ${act_flags}${idx} ${esc_name} #[fg=$bg_selected]#[bg=$bg_main]#[nobold]$left_seperator"
      inactive_pill="#[fg=$text_main]#[bg=$bg_main]#[nobold] ${inact_flags}${idx} ${esc_name} "

      if ((idx == 0)); then
        fmt+="#{?#{==:#{session_id},${s_id}},${active_pill},${inactive_pill}}"
      else
        sub_sep="#[fg=$text_main]#[bg=$bg_main]#[nobold]$left_separator_sub "
        fmt+="#{?#{==:#{session_id},${s_id}},${active_pill},#{?#{==:#{session_id},${prev_id}},,${sub_sep}}${inactive_pill}}"
      fi
      prev_id="$s_id"
      ((idx++))
    done

    local cur_sfmt
    cur_sfmt="$(tmux show-options -gqv @session_tabs_fmt 2>/dev/null)"

    local -a tmux_cmds=()
    append_tmux_cmd() {
      ((${#tmux_cmds[@]} > 0)) && tmux_cmds+=(";")
      tmux_cmds+=("$@")
    }

    if ((found_override_pane == 1)); then
      if ((clear_pane_bell == 1)) && [[ "$orig_p_bell" == "1" ]]; then
        append_tmux_cmd set-option -p -t "$override_pane" @p_bell 0
      fi
      if [[ "$override_agent" != "__KEEP__" && "$orig_p_agent" != "$override_agent" ]]; then
        append_tmux_cmd set-option -p -t "$override_pane" @p_agent "$override_agent"
      fi
    fi

    for w_id in "${!win_status[@]}"; do
      if [[ "${cur_win_status[$w_id]:-0}" != "${win_status[$w_id]}" ]]; then
        append_tmux_cmd set-option -w -t "$w_id" @w_agent "${win_status[$w_id]}"
      fi
      if [[ "${cur_win_bell[$w_id]:-0}" != "${win_bell[$w_id]:-0}" ]]; then
        append_tmux_cmd set-option -w -t "$w_id" @w_bell "${win_bell[$w_id]:-0}"
      fi
    done

    if [[ "$cur_sfmt" != "$fmt" ]]; then
      append_tmux_cmd set-option -g @session_tabs_fmt "$fmt"
    fi

    if ((${#tmux_cmds[@]} > 0)); then
      if ((no_refresh == 0)); then
        append_tmux_cmd refresh-client -S
      fi
      tmux "${tmux_cmds[@]}" 2>/dev/null
      ((no_refresh == 1)) && echo "1"
    elif ((no_refresh == 1)); then
      echo "0"
    fi

    local srv_tail="${TMUX#*,}"
    local srv_pid="${srv_tail%%,*}"
    if [[ -n "$srv_pid" && -n "$fmt" ]]; then
      local cur_srv=""
      [[ -r "${state_root}/.server_pid" ]] && cur_srv="$(<"${state_root}/.server_pid")"
      if [[ "$cur_srv" != "$srv_pid" ]]; then
        printf '%s\n' "$srv_pid" >"${state_root}/.server_pid.tmp.$$" 2>/dev/null &&
          mv -f "${state_root}/.server_pid.tmp.$$" "${state_root}/.server_pid" 2>/dev/null
      fi
    fi

    if ((reconcile_orphans == 1 && ${#alive_panes[@]} > 0)) && [[ -d "$state_root" ]]; then
      for d in "${state_root}"/*; do
        [[ -d "$d" ]] || continue
        d_name="${d##*/}"
        if [[ "$d_name" =~ ^[0-9]+$ ]] && [[ -z "${alive_panes[$d_name]:-}" ]]; then
          rm -rf "$d" 2>/dev/null
        fi
      done
    fi
  ) 7>"${state_root}/sync.lock"
}

if [[ "$event" == "sync_window" ]]; then
  if [[ "$explicit_target" == "--no-refresh" ]]; then
    sync_all_surfaces_atomic "" "__KEEP__" 0 1 1
  else
    sync_all_surfaces_atomic "" "__KEEP__" 0 1 0
  fi
  exit 0
fi

if [[ "$event" == "pane_exited" ]]; then
  if [[ -n "$explicit_target" && "$explicit_target" == %* ]]; then
    rm -rf "${state_root}/${explicit_target//%/}" 2>/dev/null
  fi
  sync_all_surfaces_atomic "" "__KEEP__" 0 1 0
  exit 0
fi

[[ -z "$pane_id" ]] && exit 0

pane_dir="${state_root}/${pane_id//%/}"
target=(-t "$pane_id")

file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo "${2:-0}"
}

pid_is_alive() {
  local p="$1"
  [[ -z "$p" || ! "$p" =~ ^[0-9]+$ || "$p" -le 0 ]] && return 0
  if [[ -d /proc ]]; then
    [[ -d "/proc/${p}" ]]
    return $?
  fi
  kill -0 "$p" 2>/dev/null || ps -p "$p" >/dev/null 2>&1
}

_OWNER_PID=""
_IS_NESTED_CLI=0
_OWNER_PID_RESOLVED=0
ensure_owner_pid() {
  ((_OWNER_PID_RESOLVED == 1)) && return
  _OWNER_PID_RESOLVED=1
  local pane_pid pid comm ppid stat_line stat_rest first_cli="" saw_shell_above_cli=0 nested_cli=0 hops=0
  local -a ancestor_cli_pids=()
  local mf m_pid anc_p
  pane_pid="$(tmux display-message "${target[@]}" -p '#{pane_pid}' 2>/dev/null)"
  [[ -z "$pane_pid" || ! "$pane_pid" =~ ^[0-9]+$ ]] && return
  pid="$PPID"
  while [[ -n "$pid" && "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 && "$hops" -lt 16 ]]; do
    hops=$((hops + 1))
    if [[ -r "/proc/${pid}/comm" && -r "/proc/${pid}/stat" ]]; then
      comm="$(<"/proc/${pid}/comm")"
      stat_line="$(<"/proc/${pid}/stat")"
      stat_rest="${stat_line##*) }"
      read -r _ ppid _ <<<"$stat_rest"
    else
      comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')"
      ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    fi
    [[ -z "$comm" ]] && break
    case "${comm#-}" in
      sh | bash | dash | zsh | fish)
        if [[ -n "$first_cli" && "$pid" != "$pane_pid" ]]; then
          saw_shell_above_cli=1
        fi
        ;;
      *)
        if [[ -z "$first_cli" ]]; then
          first_cli="$pid"
        else
          ancestor_cli_pids+=("$pid")
          if ((saw_shell_above_cli == 1)); then
            nested_cli=1
          fi
        fi
        ;;
    esac
    if [[ "$pid" == "$pane_pid" ]]; then
      _OWNER_PID="$first_cli"
      if ((nested_cli == 0 && ${#ancestor_cli_pids[@]} > 0)) && [[ -d "$pane_dir" ]]; then
        # GNU bash -c execve()s single-command tool invocations in place without
        # leaving a shell PID; distinguish nested sub-CLIs from launcher wrappers
        # (e.g. npx -> claude) by checking if an ancestor PID already owns a marker.
        for mf in "${pane_dir}"/active/* "${pane_dir}/awaiting_idle"; do
          [[ -e "$mf" ]] || continue
          m_pid=""
          IFS='|' read -r _ _ m_pid <"$mf" 2>/dev/null || true
          [[ -z "$m_pid" ]] && continue
          for anc_p in "${ancestor_cli_pids[@]}"; do
            if [[ "$m_pid" == "$anc_p" ]]; then
              nested_cli=1
              break 2
            fi
          done
        done
      fi
      _IS_NESTED_CLI="$nested_cli"
      return
    fi
    pid="$ppid"
  done
}

query_pane_active() {
  tmux display-message "${target[@]}" -p '#{?#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}},1,0}' 2>/dev/null
}

acquire_pane_lock() {
  if command -v flock >/dev/null 2>&1; then
    flock -w 2 9 || return 1
  fi
  return 0
}

resolve_sqlite_python() {
  if [[ -x "/usr/bin/python3" ]]; then
    echo "/usr/bin/python3"
    return 0
  fi
  local candidate
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 2>/dev/null)"; do
    if [[ -n "$candidate" && -x "$candidate" ]] && "$candidate" -c "import sqlite3" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

is_conv_still_busy_in_db() {
  local check_conv="$1"
  local check_data_dir="$2"
  [[ -z "$check_conv" || -z "$check_data_dir" ]] && return 1
  local summary_db="${check_data_dir}/conversation_summaries.db"
  local check_conv_db="${check_data_dir}/conversations/${check_conv}.db"
  [[ ! -f "$summary_db" && ! -f "$check_conv_db" ]] && return 1

  local py_bin
  py_bin="$(resolve_sqlite_python)" || return 1
  "$py_bin" - "$summary_db" "$check_conv_db" "$check_conv" <<'PY' >/dev/null 2>&1
import os
import sqlite3
import sys

summary_db, conv_db, cid = sys.argv[1], sys.argv[2], sys.argv[3]

if conv_db and os.path.isfile(conv_db):
  try:
    c_conn = sqlite3.connect(f"file:{conv_db}?mode=ro", uri=True, timeout=0.5)
    max_u = c_conn.execute(
        "SELECT COALESCE(MAX(idx), -1) FROM steps WHERE step_type = 14"
    ).fetchone()[0]
    inflight = c_conn.execute(
        "SELECT 1 FROM steps WHERE status IN (1, 2, 8, 9, 11) AND idx > ? LIMIT 1",
        (max_u,),
    ).fetchone()
    c_conn.close()
    if inflight is not None:
      sys.exit(0)
  except Exception:
    pass

if not summary_db or not os.path.isfile(summary_db):
  sys.exit(1)

try:
  conn = sqlite3.connect(f"file:{summary_db}?mode=ro", uri=True, timeout=0.5)
  row = conn.execute(
      "SELECT status, not_fully_idle, killed FROM conversation_summaries WHERE conversation_id = ?",
      (cid,),
  ).fetchone()
  desc_busy = (
      conn.execute(
          "WITH RECURSIVE tree(id, depth) AS ("
          "  SELECT conversation_id, 0 FROM conversation_summaries WHERE parent_conversation_id = ?"
          "  UNION ALL"
          "  SELECT cs.conversation_id, tree.depth + 1"
          "  FROM conversation_summaries cs JOIN tree ON cs.parent_conversation_id = tree.id"
          "  WHERE tree.depth < 8"
          ") SELECT 1 FROM conversation_summaries"
          " WHERE conversation_id IN (SELECT id FROM tree)"
          " AND COALESCE(killed, 0) = 0"
          " AND (status LIKE '%_RUNNING' OR COALESCE(not_fully_idle, 0) != 0)"
          " LIMIT 1",
          (cid,),
      ).fetchone()
      is not None
  )
  conn.close()
except Exception:
  sys.exit(1)

if row is not None:
  status, not_fully_idle, killed = row
  if killed:
    sys.exit(1)
  if str(status or "").endswith("_RUNNING") or bool(not_fully_idle) or desc_busy:
    sys.exit(0)
elif desc_busy:
  sys.exit(0)
sys.exit(1)
PY
}

has_waiting_step_in_db() {
  local db_file="$1"
  [[ -f "$db_file" ]] || return 1
  local py_bin
  py_bin="$(resolve_sqlite_python)" || return 1
  "$py_bin" - "$db_file" <<'PY' >/dev/null 2>&1
import sqlite3
import sys

try:
  conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=0.5)
  max_u = conn.execute(
      "SELECT COALESCE(MAX(idx), -1) FROM steps WHERE step_type = 14"
  ).fetchone()[0]
  waiting = conn.execute(
      "SELECT 1 FROM steps WHERE status = 9 AND idx > ? LIMIT 1",
      (max_u,),
  ).fetchone()
  conn.close()
  sys.exit(0 if waiting is not None else 1)
except Exception:
  sys.exit(1)
PY
}

# Reap markers from exited CLI processes, expired subagent questions, and stale
# active/awaiting_idle state. Must be called while holding `${pane_dir}/lock`.
expire_stale_state() {
  local q_ttl run_ttl now f mtime saved_conv saved_dir saved_pid safe_c sub_db
  q_ttl="$(tmux show-options -gqv @agent_subagent_question_ttl 2>/dev/null)"
  q_ttl="${q_ttl:-$DEFAULT_SUBAGENT_TTL}"
  run_ttl="$(tmux show-options -gqv @agent_running_stale_ttl 2>/dev/null)"
  run_ttl="${run_ttl:-$DEFAULT_RUNNING_STALE_TTL}"
  now="$(date +%s)"

  for f in "${pane_dir}"/.tmp.*; do
    [[ -e "$f" ]] || continue
    mtime="$(file_mtime "$f" "$now")"
    ((now - mtime > 60)) && rm -f "$f" 2>/dev/null
  done

  for f in "${pane_dir}"/question/*; do
    [[ -e "$f" ]] || continue
    saved_conv=""
    saved_dir=""
    saved_pid=""
    IFS='|' read -r saved_conv saved_dir saved_pid <"$f" 2>/dev/null || true
    if [[ -n "$saved_pid" ]] && ! pid_is_alive "$saved_pid"; then
      rm -f "$f"
      continue
    fi
    if [[ "$f" == *.sub ]]; then
      mtime="$(file_mtime "$f" "$now")"
      if ((now - mtime > q_ttl)); then
        sub_db=""
        if [[ -n "$saved_dir" && -n "$saved_conv" && -f "${saved_dir}/conversations/${saved_conv}.db" ]]; then
          sub_db="${saved_dir}/conversations/${saved_conv}.db"
        fi
        if [[ -n "$sub_db" ]] && has_waiting_step_in_db "$sub_db"; then
          touch "$f" 2>/dev/null
        else
          rm -f "$f"
        fi
      fi
    fi
  done

  for f in "${pane_dir}"/active/* "${pane_dir}/awaiting_idle"; do
    [[ -e "$f" ]] || continue
    saved_conv=""
    saved_dir=""
    saved_pid=""
    IFS='|' read -r saved_conv saved_dir saved_pid <"$f" 2>/dev/null || true
    if [[ -n "$saved_pid" ]] && ! pid_is_alive "$saved_pid"; then
      rm -f "$f"
      if [[ -n "$saved_conv" ]]; then
        safe_c="${saved_conv//[^A-Za-z0-9_-]/_}"
        rm -f "${pane_dir}/pending/${safe_c}__"* "${pane_dir}/question/${safe_c}" "${pane_dir}/question/${safe_c}.sub" "${pane_dir}/question/${safe_c}__"* 2>/dev/null
      fi
      continue
    fi
    mtime="$(file_mtime "$f" "$now")"
    if ((now - mtime <= run_ttl)); then
      continue
    fi
    if [[ -n "$saved_dir" ]] && [[ -f "${saved_dir}/conversation_summaries.db" || -f "${saved_dir}/conversations/${saved_conv}.db" ]]; then
      if is_conv_still_busy_in_db "$saved_conv" "$saved_dir"; then
        touch "$f" 2>/dev/null
      else
        rm -f "$f"
      fi
    elif ((now - mtime > 600)); then
      rm -f "$f"
    fi
  done

  if ! compgen -G "${pane_dir}/active/*" >/dev/null && [[ ! -f "${pane_dir}/awaiting_idle" ]]; then
    for f in "${pane_dir}"/watchers/*; do
      [[ -e "$f" ]] || continue
      mtime="$(file_mtime "$f" "$now")"
      if ((now - mtime > 600)); then
        rm -f "$f"
      fi
    done
  fi
}

# Recompute @p_agent from state files within a single pane (caller holds `${pane_dir}/lock`):
#   question > running > done > 0
# (Across distinct panes in a window/session, sync_all_surfaces_atomic and session_tabs.sh
# aggregate with question > done > running > bell > alert.)
recompute_locked() {
  expire_stale_state
  local want="0"
  if compgen -G "${pane_dir}/question/*" >/dev/null; then
    want="question"
  elif compgen -G "${pane_dir}/active/*" >/dev/null || [[ -f "${pane_dir}/awaiting_idle" ]]; then
    rm -f "${pane_dir}/done" 2>/dev/null
    want="running"
  elif [[ -f "${pane_dir}/done" ]]; then
    want="done"
  fi
  local cur_p_agent="" cur_w_agent="" need_sync=0
  IFS=$'\x1f' read -r cur_p_agent cur_w_agent < <(tmux display-message "${target[@]}" -p $'#{@p_agent}\x1f#{@w_agent}' 2>/dev/null)
  if [[ "${cur_p_agent:-0}" != "$want" ]]; then
    need_sync=1
  elif [[ "$want" == "question" && "${cur_w_agent:-0}" != "question" ]]; then
    need_sync=1
  elif [[ "$want" == "done" && "${cur_w_agent:-0}" != "done" && "${cur_w_agent:-0}" != "question" ]]; then
    need_sync=1
  elif [[ "$want" == "running" && "${cur_w_agent:-0}" != "running" && "${cur_w_agent:-0}" != "done" && "${cur_w_agent:-0}" != "question" ]]; then
    need_sync=1
  fi
  if ((need_sync == 1)); then
    sync_all_surfaces_atomic "$pane_id" "$want" 0 0 0
  fi
}

recompute() {
  if [[ ! -d "$pane_dir" ]]; then
    local cur_p_agent
    cur_p_agent="$(tmux show-options -pqv "${target[@]}" @p_agent 2>/dev/null)"
    if [[ -n "$cur_p_agent" && "$cur_p_agent" != "0" ]]; then
      sync_all_surfaces_atomic "$pane_id" "0" 0 0
    fi
    return
  fi

  (
    acquire_pane_lock || exit 0
    recompute_locked
  ) 9>"${pane_dir}/lock"
}

if [[ "$event" == "_recompute" ]]; then
  recompute
  exit 0
fi

if [[ "$event" == "_finish_idle" ]]; then
  if [[ -d "$pane_dir" ]]; then
    is_active="$(query_pane_active)"
    (
      acquire_pane_lock || exit 0
      if [[ -f "${pane_dir}/awaiting_idle" ]] && ! compgen -G "${pane_dir}/active/*" >/dev/null; then
        now_s="$(date +%s)"
        poke_m="0"
        [[ -f "${pane_dir}/watchers/_awaiting_idle.poke" ]] && poke_m="$(file_mtime "${pane_dir}/watchers/_awaiting_idle.poke" "0")"
        if ((now_s - poke_m >= 3)); then
          if [[ "$is_active" == "0" ]]; then
            touch "${pane_dir}/done"
          else
            rm -f "${pane_dir}/done"
          fi
          rm -f "${pane_dir}/awaiting_idle"
        fi
      fi
      recompute_locked
    ) 9>"${pane_dir}/lock"
  else
    recompute
  fi
  exit 0
fi

if [[ "$event" == "reset" ]]; then
  rm -rf "$pane_dir"
  sync_all_surfaces_atomic "$pane_id" "0" 1 0
  exit 0
fi

if [[ "$event" == "focus_pane" ]]; then
  if [[ ! -d "$pane_dir" ]]; then
    sync_all_surfaces_atomic "$pane_id" "0" 1 0
    exit 0
  fi

  (
    acquire_pane_lock || exit 0
    [[ -f "${pane_dir}/done" ]] && rm -f "${pane_dir}/done" 2>/dev/null
    expire_stale_state
    want="0"
    if compgen -G "${pane_dir}/question/*" >/dev/null; then
      want="question"
    elif compgen -G "${pane_dir}/active/*" >/dev/null || [[ -f "${pane_dir}/awaiting_idle" ]]; then
      want="running"
    fi
    sync_all_surfaces_atomic "$pane_id" "$want" 1 0
  ) 9>"${pane_dir}/lock"
  exit 0
fi

mkdir -p "${pane_dir}/pending" "${pane_dir}/question" "${pane_dir}/active" "${pane_dir}/watchers" 2>/dev/null

# Sanitize file keys
conv="${raw_conv//[^A-Za-z0-9_-]/_}"
step="${step//[^A-Za-z0-9_-]/_}"
key="${conv}__${step}"

write_text_atomic() {
  local dest="$1"
  local content="$2"
  local tmp="${pane_dir}/.tmp.$$.${RANDOM}"
  if printf '%s\n' "$content" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$dest" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

# Resolve data_dir and per-conversation SQLite store when present
data_dir=""
conv_db=""
if [[ "$artifact_dir" == */brain/* ]]; then
  data_dir="${artifact_dir%/brain/*}"
elif [[ "$transcript_path" == */brain/* ]]; then
  data_dir="${transcript_path%/brain/*}"
fi

if [[ "$raw_conv" != "default" && "$raw_conv" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
  if [[ -n "$data_dir" ]] && [[ -f "${data_dir}/conversations/${raw_conv}.db" || -d "${data_dir}/conversations" ]]; then
    conv_db="${data_dir}/conversations/${raw_conv}.db"
  else
    for candidate_db in "$HOME/.gemini/"*/conversations/"${raw_conv}.db"; do
      if [[ -f "$candidate_db" ]]; then
        conv_db="$candidate_db"
        data_dir="${candidate_db%/conversations/*}"
        break
      fi
    done
  fi
fi

is_sub=0
resolve_is_sub() {
  if [[ -n "$parent" ]]; then
    is_sub=1
    return
  fi
  [[ "$raw_conv" == "default" ]] && return

  local role_file="${pane_dir}/watchers/${conv}.role"
  local cached_role=""
  if [[ -r "$role_file" ]]; then
    cached_role="$(<"$role_file")"
    if [[ "$cached_role" == "sub" ]]; then
      is_sub=1
      return
    elif [[ "$cached_role" == "root" ]]; then
      is_sub=0
      return
    fi
  fi

  local summary_db="${data_dir:+${data_dir}/conversation_summaries.db}"
  local py_bin db_role=""
  if [[ -n "$summary_db" && -f "$summary_db" ]] && py_bin="$(resolve_sqlite_python)"; then
    db_role="$(
      "$py_bin" - "$summary_db" "$raw_conv" <<'PY' 2>/dev/null
import sqlite3
import sys

try:
  conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=0.3)
  row = conn.execute(
      "SELECT parent_conversation_id FROM conversation_summaries WHERE conversation_id = ? LIMIT 1",
      (sys.argv[2],),
  ).fetchone()
  conn.close()
  if row is None:
    print("missing")
  elif row[0]:
    print("sub")
  else:
    print("root")
except Exception:
  print("missing")
PY
    )"
    if [[ "$db_role" == "sub" ]]; then
      is_sub=1
      write_text_atomic "$role_file" "sub"
      return
    elif [[ "$db_role" == "root" ]]; then
      is_sub=0
      write_text_atomic "$role_file" "root"
      return
    fi
  fi

  # Pre-flush fallback (within the 1s batch flush window before conversation_summaries.db
  # syncs a new row): if another root conversation owned by the same CLI process is
  # actively mid-turn, treat this un-flushed conversation transiently as a child
  # without caching `.role`.
  ensure_owner_pid
  [[ -z "$_OWNER_PID" ]] && return
  local mf m_conv m_dir m_pid now_s mf_mtime
  now_s="$(date +%s)"
  for mf in "${pane_dir}"/active/* "${pane_dir}/awaiting_idle"; do
    [[ -e "$mf" && "$mf" != *.sub ]] || continue
    m_conv=""
    m_dir=""
    m_pid=""
    IFS='|' read -r m_conv m_dir m_pid <"$mf" 2>/dev/null || true
    [[ -n "$m_conv" && "$m_conv" != "$raw_conv" && "$m_pid" == "$_OWNER_PID" ]] || continue
    mf_mtime="$(file_mtime "$mf" "0")"
    if ((now_s - mf_mtime <= 5)) || is_conv_still_busy_in_db "$m_conv" "${m_dir:-$data_dir}"; then
      is_sub=1
      return
    fi
  done
}
resolve_is_sub

if [[ -f "${state_root}/debug" ]]; then
  echo "$(date +%T.%N) ${event} pane=${pane_id} conv=${conv} sub=${is_sub} step=${step} tool=${tool} idle=${fully_idle} term=${term_reason} db=${conv_db:+yes}" \
    >>"${state_root}/debug.log"
fi

active_marker() {
  if ((is_sub == 1 || _IS_NESTED_CLI == 1)); then
    echo "${pane_dir}/active/${conv}.sub"
  else
    echo "${pane_dir}/active/${conv}"
  fi
}

question_conv_marker() {
  if ((is_sub == 1 || _IS_NESTED_CLI == 1)); then
    echo "${pane_dir}/question/${conv}.sub"
  else
    echo "${pane_dir}/question/${conv}"
  fi
}

question_step_marker() {
  if ((is_sub == 1 || _IS_NESTED_CLI == 1)); then
    echo "${pane_dir}/question/${key}.sub"
  else
    echo "${pane_dir}/question/${key}"
  fi
}

write_marker() {
  local dest="$1"
  write_text_atomic "$dest" "${raw_conv}|${data_dir}|${_OWNER_PID}"
}

drop_conversation() {
  local c="$1"
  rm -f \
    "${pane_dir}/pending/${c}__"* \
    "${pane_dir}/question/${c}" \
    "${pane_dir}/question/${c}.sub" \
    "${pane_dir}/question/${c}__"* \
    "${pane_dir}/active/${c}" \
    "${pane_dir}/active/${c}.sub" 2>/dev/null
}

# Single per-conversation SQLite watcher (guarded by non-blocking fcntl.flock)
# that reflects sustained `WAITING` (`status = 9`) step transitions while
# filtering out transient client auto-approval spikes.
start_sqlite_waiting_watcher() {
  local initial_grace="${1:-0.04}"
  [[ -z "$conv_db" ]] && return

  local py_bin
  py_bin="$(resolve_sqlite_python)" || return

  ensure_owner_pid
  local a_file q_file w_lock poke_file marker_meta
  a_file="$(active_marker)"
  q_file="$(question_conv_marker)"
  w_lock="${pane_dir}/watchers/${conv}.lock"
  poke_file="${pane_dir}/watchers/${conv}.poke"
  marker_meta="${raw_conv}|${data_dir}|${_OWNER_PID}"

  # Touch poke_file BEFORE acquiring watcher lock so an already-running watcher
  # cannot exit on `not inflight` right as a new PreToolUse arrives.
  touch "$poke_file" 2>/dev/null

  "$py_bin" - "$conv_db" "$pane_dir" "$a_file" "$q_file" "$w_lock" "$poke_file" "$SELF_SCRIPT" "$pane_id" "$initial_grace" "$_OWNER_PID" "$marker_meta" >/dev/null 2>&1 <<'PY' &
import fcntl
import os
import sqlite3
import subprocess
import sys
import time

(
    conv_db,
    pane_dir,
    active_file,
    q_marker,
    lock_path,
    poke_path,
    hook_script,
    pane_id,
    initial_grace_s,
    owner_pid_s,
    marker_meta,
) = sys.argv[1:12]
initial_grace = float(initial_grace_s)
owner_pid = int(owner_pid_s) if owner_pid_s.isdigit() else 0
has_proc = os.path.isdir("/proc")

try:
  lock_fh = open(lock_path, "a+", encoding="utf-8")
  fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
  sys.exit(0)

def owner_alive():
  if owner_pid <= 0:
    return True
  if has_proc:
    return os.path.exists(f"/proc/{owner_pid}")
  try:
    os.kill(owner_pid, 0)
    return True
  except ProcessLookupError:
    return False
  except PermissionError:
    return True

def trigger_recompute():
  try:
    subprocess.run(
        [hook_script, "_recompute", pane_id],
        close_fds=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=3,
        check=False,
    )
  except Exception:
    pass

def clear_marker_if_present():
  if os.path.exists(q_marker):
    try:
      os.unlink(q_marker)
    except OSError:
      pass
    trigger_recompute()

def write_q_marker_atomic():
  if not os.path.exists(active_file) or not owner_alive():
    return False
  tmp_path = os.path.join(pane_dir, f".tmp.q.{os.getpid()}")
  try:
    with open(tmp_path, "w", encoding="utf-8") as fh:
      fh.write(marker_meta + "\n")
    if not os.path.exists(active_file) or not owner_alive():
      try:
        os.unlink(tmp_path)
      except OSError:
        pass
      return False
    os.replace(tmp_path, q_marker)
    if not os.path.exists(active_file):
      try:
        os.unlink(q_marker)
      except OSError:
        pass
      return False
    return True
  except OSError:
    try:
      os.unlink(tmp_path)
    except OSError:
      pass
    return False

def recent_poke_age():
  try:
    return max(0.0, time.time() - os.path.getmtime(poke_path))
  except OSError:
    return 9999.0

if initial_grace > 0:
  time.sleep(initial_grace)
if not os.path.exists(active_file) or not owner_alive():
  clear_marker_if_present()
  sys.exit(0)

conn = None
start_ts = time.monotonic()
waiting_idx = None
waiting_since = 0.0
DEBOUNCE_SECS = 0.45
MAX_SINGLE_WAIT_SECS = 3600.0

try:
  while True:
    now = time.monotonic()
    if not os.path.exists(active_file) or not owner_alive():
      clear_marker_if_present()
      break

    if conn is None:
      if not os.path.exists(conv_db):
        if recent_poke_age() >= 1.5 and (now - start_ts) >= 1.5:
          break
        time.sleep(0.15)
        continue
      try:
        conn = sqlite3.connect(f"file:{conv_db}?mode=ro", uri=True, timeout=1.0)
      except Exception:
        time.sleep(0.20)
        continue

    poke_age = recent_poke_age()
    try:
      row_u = conn.execute(
          "SELECT COALESCE(MAX(idx), -1) FROM steps WHERE step_type = 14"
      ).fetchone()
      min_idx = row_u[0] if row_u else -1
      row_w = conn.execute(
          "SELECT idx FROM steps WHERE status = 9 AND idx > ? ORDER BY idx DESC LIMIT 1",
          (min_idx,),
      ).fetchone()
      cur_w_idx = row_w[0] if row_w is not None else None
      inflight = (
          conn.execute(
              "SELECT 1 FROM steps WHERE status IN (1, 2, 8, 9, 11) AND idx > ? LIMIT 1",
              (min_idx,),
          ).fetchone()
          is not None
      )
    except Exception:
      time.sleep(0.25)
      continue

    now = time.monotonic()
    has_marker = os.path.exists(q_marker)

    if cur_w_idx is not None:
      if waiting_idx != cur_w_idx:
        waiting_idx = cur_w_idx
        waiting_since = now
      wait_age = now - waiting_since
      if wait_age > MAX_SINGLE_WAIT_SECS:
        clear_marker_if_present()
        break
      if wait_age >= DEBOUNCE_SECS and not has_marker:
        if write_q_marker_atomic():
          has_marker = True
          trigger_recompute()
    else:
      waiting_idx = None
      waiting_since = 0.0
      if has_marker:
        clear_marker_if_present()
        has_marker = False

    if (
        (not inflight)
        and (cur_w_idx is None)
        and poke_age >= 1.5
        and recent_poke_age() >= 1.5
        and (now - start_ts) >= 1.0
    ):
      break

    if has_marker or cur_w_idx is not None or poke_age < 3.0:
      time.sleep(0.10)
    else:
      time.sleep(0.15)
finally:
  if conn is not None:
    conn.close()
  lock_fh.close()
PY
  disown 2>/dev/null
}

# Watches `conversation_summaries.db` when a root turn ends with `fullyIdle: false`
# so background tasks or subagents that finish without waking the root model
# still transition cleanly from `running` to `done` / idle without inter-stage dips.
start_awaiting_idle_watcher() {
  [[ -z "$data_dir" || ! -f "${data_dir}/conversation_summaries.db" ]] && return

  local py_bin
  py_bin="$(resolve_sqlite_python)" || return

  local awaiting_file="${pane_dir}/awaiting_idle"
  local active_dir="${pane_dir}/active"
  local w_lock="${pane_dir}/watchers/_awaiting_idle.lock"
  local poke_file="${pane_dir}/watchers/_awaiting_idle.poke"

  "$py_bin" - "${data_dir}/conversation_summaries.db" "$awaiting_file" "$active_dir" "$w_lock" "$poke_file" "$SELF_SCRIPT" "$pane_id" >/dev/null 2>&1 <<'PY' &
import fcntl
import os
import sqlite3
import subprocess
import sys
import time

summary_db, awaiting_file, active_dir, lock_path, poke_path, hook_script, pane_id = sys.argv[1:8]
has_proc = os.path.isdir("/proc")

try:
  lock_fh = open(lock_path, "a+", encoding="utf-8")
  fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
  sys.exit(0)

def call_hook(subcmd):
  try:
    subprocess.run(
        [hook_script, subcmd, pane_id],
        close_fds=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=3,
        check=False,
    )
  except Exception:
    pass

def pid_alive(pid_str):
  if not pid_str or not pid_str.isdigit():
    return True
  pid = int(pid_str)
  if pid <= 0:
    return True
  if has_proc:
    return os.path.exists(f"/proc/{pid}")
  try:
    os.kill(pid, 0)
    return True
  except ProcessLookupError:
    return False
  except PermissionError:
    return True

def recent_poke_age():
  try:
    return max(0.0, time.time() - os.path.getmtime(poke_path))
  except OSError:
    return 9999.0

def has_active_markers():
  try:
    if not os.path.isdir(active_dir):
      return False
    return any(not name.startswith(".") for name in os.listdir(active_dir))
  except OSError:
    return False

time.sleep(0.4)
if not os.path.exists(awaiting_file):
  lock_fh.close()
  sys.exit(0)

try:
  conn = sqlite3.connect(f"file:{summary_db}?mode=ro", uri=True, timeout=1.0)
except Exception:
  lock_fh.close()
  sys.exit(0)

IDLE_HOLD_SECS = 4.0
idle_since = None
start_ts = time.monotonic()

try:
  while time.monotonic() - start_ts < 3600:
    if not os.path.exists(awaiting_file):
      break
    try:
      with open(awaiting_file, "r", encoding="utf-8") as fh:
        meta = fh.read().strip()
    except OSError:
      break

    if not meta:
      time.sleep(0.3)
      continue

    parts = meta.split("|")
    root_cid = parts[0] if parts else ""
    owner_pid_s = parts[2] if len(parts) > 2 else ""

    if not pid_alive(owner_pid_s):
      call_hook("_recompute")
      break

    if has_active_markers():
      idle_since = None
      time.sleep(0.6)
      continue

    if not root_cid:
      break

    try:
      row = conn.execute(
          "SELECT status, not_fully_idle, killed FROM conversation_summaries WHERE conversation_id = ?",
          (root_cid,),
      ).fetchone()
      desc_busy = (
          conn.execute(
              "WITH RECURSIVE tree(id, depth) AS ("
              "  SELECT conversation_id, 0 FROM conversation_summaries WHERE parent_conversation_id = ?"
              "  UNION ALL"
              "  SELECT cs.conversation_id, tree.depth + 1"
              "  FROM conversation_summaries cs JOIN tree ON cs.parent_conversation_id = tree.id"
              "  WHERE tree.depth < 8"
              ") SELECT 1 FROM conversation_summaries"
              " WHERE conversation_id IN (SELECT id FROM tree)"
              " AND COALESCE(killed, 0) = 0"
              " AND (status LIKE '%_RUNNING' OR COALESCE(not_fully_idle, 0) != 0)"
              " LIMIT 1",
              (root_cid,),
          ).fetchone()
          is not None
      )
    except Exception:
      time.sleep(0.8)
      continue

    if row is not None:
      status, not_fully_idle, killed = row
      if killed:
        try:
          os.unlink(awaiting_file)
        except OSError:
          pass
        call_hook("_recompute")
        break
      is_busy = (
          str(status or "").endswith("_RUNNING")
          or bool(not_fully_idle)
          or desc_busy
      )
      if not is_busy:
        now = time.monotonic()
        if idle_since is None:
          idle_since = now
        elif (
            (now - idle_since) >= IDLE_HOLD_SECS
            and recent_poke_age() >= IDLE_HOLD_SECS
            and not has_active_markers()
        ):
          call_hook("_finish_idle")
          if not os.path.exists(awaiting_file):
            break
      else:
        idle_since = None
    elif desc_busy:
      idle_since = None
    time.sleep(0.6)
finally:
  conn.close()
  lock_fh.close()
PY
  disown 2>/dev/null
}

case "$event" in
  session_start)
    ensure_owner_pid
    if ((_IS_NESTED_CLI == 1)); then
      if [[ "$has_active_turn" == "1" ]]; then
        (
          acquire_pane_lock || exit 0
          write_marker "$(active_marker)"
          recompute_locked
        ) 9>"${pane_dir}/lock"
      fi
    elif ((is_sub == 0)); then
      (
        acquire_pane_lock || exit 0
        target_active="$(active_marker)"
        if [[ "$has_active_turn" == "1" ]]; then
          write_marker "$target_active"
        fi
        rm -f "${pane_dir}/done" 2>/dev/null
        now_s="$(date +%s)"
        for mf in "${pane_dir}"/active/* "${pane_dir}/awaiting_idle"; do
          [[ -e "$mf" ]] || continue
          [[ "$has_active_turn" == "1" && "$mf" == "$target_active" ]] && continue
          m_conv=""
          m_dir=""
          m_pid=""
          IFS='|' read -r m_conv m_dir m_pid <"$mf" 2>/dev/null || true
          if [[ -n "$m_pid" ]] && ! pid_is_alive "$m_pid"; then
            rm -f "$mf"
            [[ -n "$m_conv" ]] && drop_conversation "${m_conv//[^A-Za-z0-9_-]/_}"
          elif [[ "$has_active_turn" == "1" ]]; then
            mf_mtime="$(file_mtime "$mf" "0")"
            if { [[ -n "$_OWNER_PID" && "$m_pid" == "$_OWNER_PID" ]] && ((now_s - mf_mtime <= 5)); } ||
              { [[ -n "$m_conv" && -n "$m_dir" ]] && is_conv_still_busy_in_db "$m_conv" "$m_dir"; }; then
              continue
            fi
            rm -f "$mf"
            [[ -n "$m_conv" ]] && drop_conversation "${m_conv//[^A-Za-z0-9_-]/_}"
          fi
        done
        if [[ "$has_active_turn" == "1" ]]; then
          for qf in "${pane_dir}"/question/*; do
            [[ -e "$qf" ]] || continue
            q_conv=""
            IFS='|' read -r q_conv _ _ <"$qf" 2>/dev/null || true
            q_safe="${q_conv//[^A-Za-z0-9_-]/_}"
            if [[ -z "$q_safe" ]] || { [[ ! -e "${pane_dir}/active/${q_safe}" ]] && [[ ! -e "${pane_dir}/active/${q_safe}.sub" ]]; }; then
              rm -f "$qf" 2>/dev/null
            fi
          done
        fi
        recompute_locked
      ) 9>"${pane_dir}/lock"
    fi
    ;;
  running)
    ensure_owner_pid
    (
      acquire_pane_lock || exit 0
      write_marker "$(active_marker)"
      if ((is_sub == 1 || _IS_NESTED_CLI == 1)); then
        rm -f "${pane_dir}/active/${conv}" 2>/dev/null
      else
        rm -f "${pane_dir}/awaiting_idle" 2>/dev/null
      fi
      rm -f "${pane_dir}/pending/${conv}__"* "${pane_dir}/question/${conv}" "${pane_dir}/question/${conv}.sub" "${pane_dir}/question/${conv}__"* "${pane_dir}/done" 2>/dev/null
      recompute_locked
    ) 9>"${pane_dir}/lock"
    ;;
  question)
    ensure_owner_pid
    (
      acquire_pane_lock || exit 0
      if [[ "$raw_conv" != "default" ]]; then
        write_marker "$(active_marker)"
        if ((is_sub == 1 || _IS_NESTED_CLI == 1)); then
          rm -f "${pane_dir}/active/${conv}" 2>/dev/null
        fi
      fi
      rm -f "${pane_dir}/done" 2>/dev/null
      if [[ -n "$conv_db" ]]; then
        touch "${pane_dir}/watchers/${conv}.poke" 2>/dev/null
      else
        write_marker "$(question_step_marker)"
      fi
      recompute_locked
    ) 9>"${pane_dir}/lock"
    if [[ -n "$conv_db" ]]; then
      start_sqlite_waiting_watcher "0.0"
    fi
    ;;
  tool_pre)
    ensure_owner_pid
    need_fallback_timer=0
    delay=""
    marker=""
    pending=""
    token=""
    if [[ -z "$conv_db" && -z "$data_dir" ]]; then
      no_prompt="$(tmux show-options -gqv @agent_no_prompt_tools 2>/dev/null)"
      no_prompt="${no_prompt:-$DEFAULT_NO_PROMPT_TOOLS}"
      if [[ -z "$tool" || ! "$tool" =~ $no_prompt ]]; then
        need_fallback_timer=1
        delay="$(tmux show-options -gqv @agent_question_delay 2>/dev/null)"
        delay="${delay:-$DEFAULT_DELAY}"
        marker="$(question_step_marker)"
        pending="${pane_dir}/pending/${key}"
        token="$$.${RANDOM}"
      fi
    fi

    (
      acquire_pane_lock || exit 0
      write_marker "$(active_marker)"
      if ((is_sub == 1 || _IS_NESTED_CLI == 1)); then
        rm -f "${pane_dir}/active/${conv}" 2>/dev/null
      fi
      rm -f "${pane_dir}/done" 2>/dev/null
      if [[ -n "$conv_db" ]]; then
        touch "${pane_dir}/watchers/${conv}.poke" 2>/dev/null
      elif ((need_fallback_timer == 1)); then
        write_text_atomic "$pending" "$token"
      fi
      recompute_locked
    ) 9>"${pane_dir}/lock"

    if [[ -n "$conv_db" ]]; then
      start_sqlite_waiting_watcher "0.0"
    elif ((need_fallback_timer == 1)); then
      (
        sleep "$delay"
        (
          acquire_pane_lock || exit 0
          if [[ "$(cat "$pending" 2>/dev/null)" == "$token" ]]; then
            write_marker "$marker"
            recompute_locked
          fi
        ) 9>"${pane_dir}/lock"
      ) </dev/null >/dev/null 2>&1 &
      disown 2>/dev/null
    fi
    ;;
  tool_done)
    ensure_owner_pid
    clear_conv_q=1
    if [[ -n "$conv_db" && -f "$conv_db" ]]; then
      q_c="$(question_conv_marker)"
      if [[ -e "$q_c" ]] && has_waiting_step_in_db "$conv_db"; then
        clear_conv_q=0
      fi
    fi
    (
      acquire_pane_lock || exit 0
      [[ -f "$(active_marker)" ]] && write_marker "$(active_marker)"
      rm -f "${pane_dir}/pending/${key}" "${pane_dir}/question/${key}" "${pane_dir}/question/${key}.sub" 2>/dev/null
      if ((clear_conv_q == 1)); then
        rm -f "${pane_dir}/question/${conv}" "${pane_dir}/question/${conv}.sub" 2>/dev/null
      fi
      recompute_locked
    ) 9>"${pane_dir}/lock"
    ;;
  post_invocation)
    ensure_owner_pid
    (
      acquire_pane_lock || exit 0
      [[ -f "$(active_marker)" ]] && write_marker "$(active_marker)"
      recompute_locked
    ) 9>"${pane_dir}/lock"
    ;;
  done)
    ensure_owner_pid
    effective_sub=0
    ((is_sub == 1 || _IS_NESTED_CLI == 1)) && effective_sub=1
    is_active=""
    if [[ "$term_reason" != "USER_CANCELED" ]] && ((effective_sub == 0)) && [[ "$fully_idle" != "false" ]]; then
      is_active="$(query_pane_active)"
    fi

    (
      acquire_pane_lock || exit 0
      if [[ "$term_reason" == "USER_CANCELED" ]]; then
        drop_conversation "$conv"
        if ((effective_sub == 0)); then
          rm -f "${pane_dir}/awaiting_idle" "${pane_dir}/done" "${pane_dir}"/active/*.sub "${pane_dir}"/question/*.sub "${pane_dir}"/pending/* 2>/dev/null
        elif ! compgen -G "${pane_dir}/active/*" >/dev/null; then
          rm -f "${pane_dir}/awaiting_idle" "${pane_dir}/done" 2>/dev/null
        fi
      elif ((effective_sub == 0)); then
        if [[ "$fully_idle" == "false" ]]; then
          # Write awaiting_idle BEFORE dropping active/<root> so concurrent readers
          # never observe a zero-state gap during coordinator -> subagent handoff.
          write_marker "${pane_dir}/awaiting_idle"
          touch "${pane_dir}/watchers/_awaiting_idle.poke" 2>/dev/null
          drop_conversation "$conv"
          rm -f "${pane_dir}/done" 2>/dev/null
        else
          drop_conversation "$conv"
          rm -f "${pane_dir}/awaiting_idle" "${pane_dir}"/active/*.sub "${pane_dir}"/question/*.sub "${pane_dir}"/pending/* 2>/dev/null
          if ! compgen -G "${pane_dir}/active/*" >/dev/null; then
            if [[ "$is_active" == "0" ]]; then
              touch "${pane_dir}/done"
            else
              rm -f "${pane_dir}/done"
            fi
          fi
        fi
      else
        drop_conversation "$conv"
        if [[ -f "${pane_dir}/awaiting_idle" ]]; then
          touch "${pane_dir}/watchers/_awaiting_idle.poke" 2>/dev/null
        fi
      fi
      recompute_locked
    ) 9>"${pane_dir}/lock"

    if [[ -f "${pane_dir}/awaiting_idle" ]]; then
      start_awaiting_idle_watcher
    fi
    ;;
  clear)
    ensure_owner_pid
    (
      acquire_pane_lock || exit 0
      drop_conversation "$conv"
      if ((is_sub == 0 && _IS_NESTED_CLI == 0)); then
        rm -f "${pane_dir}/done" "${pane_dir}/awaiting_idle" 2>/dev/null
      fi
      recompute_locked
    ) 9>"${pane_dir}/lock"
    ;;
esac

exit 0
