#!/bin/bash
# session_hook.sh - Antigravity CLI SessionStart/PreInvocation hook: tag the tmux
# pane with the conversation ID (@antigravity_session) so sessions_save.sh can
# record it for resurrect. PreInvocation keeps the tag current after /resume or /fork.

payload="$(cat)"
echo '{}' # Hook protocol: always reply with valid JSON so the hook never counts as failed

[[ -z "${TMUX_PANE:-}" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

IFS=$'\x1f' read -r conversation_id artifact_dir transcript_path < <(
  jq -r '[
    (.conversationId // ""),
    (.artifactDirectoryPath // ""),
    (.transcriptPath // "")
  ] | join("\u001f")' <<<"$payload" 2>/dev/null
)
[[ -z "$conversation_id" ]] && exit 0

# Fast path: PreInvocation fires on every model call, and the tag rarely changes
current_tag="$(tmux show-options -pqv -t "$TMUX_PANE" @antigravity_session 2>/dev/null)"
[[ "$current_tag" == "$conversation_id" ]] && exit 0

# Subagent hooks share the parent CLI process tree; check parent_conversation_id in
# conversation_summaries.db (plus in-flight steps / active pane markers during the 1s
# summary flush window) so child turns never overwrite the pane's root tag.
data_dir=""
if [[ "$artifact_dir" == */brain/* ]]; then
  data_dir="${artifact_dir%/brain/*}"
elif [[ "$transcript_path" == */brain/* ]]; then
  data_dir="${transcript_path%/brain/*}"
elif [[ "$conversation_id" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
  for candidate_db in "$HOME/.gemini/"*/conversations/"${conversation_id}.db"; do
    if [[ -f "$candidate_db" ]]; then
      data_dir="${candidate_db%/conversations/*}"
      break
    fi
  done
fi

base_state_root="${XDG_RUNTIME_DIR:-/tmp}/tmux_agent_${USER:-$(id -u)}"
tmux_sock_path="${TMUX:-}"
tmux_sock_path="${tmux_sock_path%%,*}"
tmux_sock_name="${tmux_sock_path##*/}"
if [[ -n "$tmux_sock_name" && "$tmux_sock_name" != "default" ]]; then
  state_root="${base_state_root}_${tmux_sock_name//[^A-Za-z0-9_-]/_}"
else
  state_root="$base_state_root"
fi
pane_dir="${state_root}/${TMUX_PANE//%/}"

target_id="$conversation_id"
if [[ -n "$data_dir" || -n "$current_tag" ]]; then
  py_bin=""
  if [[ -x /usr/bin/python3 ]]; then
    py_bin="/usr/bin/python3"
  else
    for candidate_py in /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 2>/dev/null)"; do
      if [[ -n "$candidate_py" && -x "$candidate_py" ]] && "$candidate_py" -c "import sqlite3" >/dev/null 2>&1; then
        py_bin="$candidate_py"
        break
      fi
    done
  fi
  if [[ -n "$py_bin" ]]; then
    target_id="$(
      "$py_bin" - "$data_dir" "$conversation_id" "$current_tag" "$pane_dir" <<'PY' 2>/dev/null
import os
import re
import sqlite3
import sys
import time

data_dir, cid, cur_tag, pane_dir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
summary_db = os.path.join(data_dir, "conversation_summaries.db") if data_dir else ""
has_proc = os.path.isdir("/proc")

def pid_alive(pid_s):
  if not pid_s or not pid_s.isdigit():
    return True
  pid = int(pid_s)
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

def cur_tag_inflight():
  if not cur_tag:
    return False
  if data_dir and re.match(r"^[A-Za-z0-9_-]{1,128}$", cur_tag):
    cur_db = os.path.join(data_dir, "conversations", f"{cur_tag}.db")
    if os.path.isfile(cur_db):
      try:
        c_conn = sqlite3.connect(f"file:{cur_db}?mode=ro", uri=True, timeout=0.3)
        max_u = c_conn.execute(
            "SELECT COALESCE(MAX(idx), -1) FROM steps WHERE step_type = 14"
        ).fetchone()[0]
        inflight = c_conn.execute(
            "SELECT 1 FROM steps WHERE status IN (1, 2, 8, 9, 11) AND idx > ? LIMIT 1",
            (max_u,),
        ).fetchone()
        c_conn.close()
        if inflight is not None:
          return True
      except Exception:
        pass
  if pane_dir and os.path.isdir(pane_dir):
    safe_cur = re.sub(r"[^A-Za-z0-9_-]", "_", cur_tag)
    now = time.time()
    for m_path in (
        os.path.join(pane_dir, "active", safe_cur),
        os.path.join(pane_dir, "awaiting_idle"),
    ):
      try:
        st = os.stat(m_path)
        with open(m_path, "r", encoding="utf-8") as fh:
          parts = fh.read().strip().split("|")
        m_cid = parts[0] if parts else ""
        m_pid = parts[2] if len(parts) > 2 else ""
        if m_cid == cur_tag and pid_alive(m_pid) and (now - st.st_mtime) <= 5.0:
          return True
      except OSError:
        pass
  return False

try:
  row = None
  conn = None
  if summary_db and os.path.isfile(summary_db):
    conn = sqlite3.connect(f"file:{summary_db}?mode=ro", uri=True, timeout=0.3)
    row = conn.execute(
        "SELECT parent_conversation_id FROM conversation_summaries WHERE conversation_id = ? LIMIT 1",
        (cid,),
    ).fetchone()
  if row is not None:
    parent_id = row[0] or ""
    if not parent_id:
      print(cid)
    elif not cur_tag and conn is not None:
      anc = parent_id
      for _ in range(8):
        p_row = conn.execute(
            "SELECT parent_conversation_id FROM conversation_summaries WHERE conversation_id = ? LIMIT 1",
            (anc,),
        ).fetchone()
        if p_row is None:
          anc = ""
          break
        if not p_row[0]:
          break
        anc = p_row[0]
      if anc:
        print(anc)
  else:
    keep_cur = False
    if cur_tag:
      if conn is not None:
        c_row = conn.execute(
            "SELECT status, not_fully_idle, killed FROM conversation_summaries WHERE conversation_id = ? LIMIT 1",
            (cur_tag,),
        ).fetchone()
        c_desc = conn.execute(
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
            (cur_tag,),
        ).fetchone()
        if c_row is not None:
          status, not_fully_idle, killed = c_row
          if not killed and (
              str(status or "").endswith("_RUNNING")
              or bool(not_fully_idle)
              or c_desc is not None
          ):
            keep_cur = True
        elif c_desc is not None:
          keep_cur = True
      if not keep_cur and cur_tag_inflight():
        keep_cur = True
    if not keep_cur:
      print(cid)
  if conn is not None:
    conn.close()
except Exception:
  if not cur_tag:
    print(cid)
PY
    )"
    [[ -z "$target_id" || "$target_id" == "$current_tag" ]] && exit 0
  fi
fi

# Only tag the pane's own agent, not a nested one started from inside it: the nearest
# non-shell ancestor (the CLI that ran this hook) must be the pane process or its direct child.
pane_pid="$(tmux display-message -t "$TMUX_PANE" -p '#{pane_pid}' 2>/dev/null)"
pid=$PPID
while [[ -n "$pid" && "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]]; do
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
    sh | bash | dash | zsh | fish) pid="$ppid" ;;
    *)
      [[ "$pid" == "$pane_pid" || "$ppid" == "$pane_pid" ]] &&
        tmux set-option -p -t "$TMUX_PANE" @antigravity_session "$target_id"
      exit 0
      ;;
  esac
done
exit 0
