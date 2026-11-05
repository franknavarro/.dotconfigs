# Agent CLI Tmux Status & Notification System

A unified, real-time visual notification system for Tmux that tracks the execution lifecycle of autonomous AI agents, spawned subagents, CLI pair programmers, and background tasks across multi-session environments.

---

## 1. Visual Indicators & Multi-Level Hierarchy

The system displays a single colorized NerdFont indicator (`nf-fa-*`) with strict precedence across all three structural levels (**Session Tabs Line 0**, **Window Tabs Line 1**, and **Pane Borders**):

| Precedence | Icon | Glyph | State | Dark BG (`#44475a`) | Active BG (`#bd93f9` / `#00ffff` / `#00ff22`) | Meaning | Clearing Behavior |
| :---: | :---: | :--- | :--- | :--- | :--- | :--- | :--- |
| **1 (Highest)** | **``** | `U+F059` (`nf-fa-question_circle`) | `question` | `#ffb86c` (Orange) | `#8b2500` | **Interactive Prompt / Approval**: Agent or subagent is waiting for user confirmation, permission grant, or clarification answer. | **Persistent**: Does **not** clear when navigating between panes or windows. Clears as soon as the user responds or the waiting step finishes. |
| **2** | **``** | `U+F058` (`nf-fa-check_circle`) | `done` | `#50fa7b` (Green) | `#004d22` | **Turn Complete**: Root agent and all spawned subagents/background work finished (`fullyIdle`) while the pane was unfocused. | **Pane-Focus Clearing**: Clears automatically as soon as the user focuses that **pane**. |
| **3** | **``** | `U+F085` (`nf-fa-cogs`) | `running` | `#8be9fd` (Cyan) | `#004488` | **Thinking / Running**: Agent or spawned subagent is actively thinking, executing tools, or awaiting background subagent completion. | **Lifecycle Clearing**: Stays visible on both focused and unfocused panes while active; transitions to `done` (unfocused) or clears (focused) once `fullyIdle`. |
| **4** | **``** | `U+F0F3` (`nf-fa-bell`) | `bell` | `#f1fa8c` (Yellow) | `#6b3a00` | **Application Bell**: Standard terminal BEL character (`\a` / `0x07`). | **Pane-Focus Clearing**: Clears as soon as that **pane** becomes active. |
| **5 (Lowest)** | **``** | `U+F06A` (`nf-fa-exclamation_circle`) | `alert` | `#ff5555` (Red) | `#990000` | **Background Alerts / Silence**: Window alerts / silence monitoring triggers. | Clears upon window focus. |

*(Zoomed windows also display **``** `U+F00E` `nf-fa-search_plus` in `#bd93f9` / `#4a0072`.)*

### Visual Layout Hierarchy

- **Line 0 (Sessions Bar)**: Displays the highest-precedence indicator among all windows and panes in that session:
  ```
  ❒ SESSIONS  0 dev   1 reviewer   2 api-refactor   3 workspace 
  ```
- **Line 1 (Windows Bar)**: Displays the highest-precedence indicator among all panes within that window:
  ```
  ❐ WINDOWS  1 editor   2 agent   3 subagent-run   4 build 
  ```
- **Pane Borders (`top`)**: Displays the specific status icon of each pane (active or inactive) in its top border:
  ```
  ┌──  2: agy [my-app] ──────────────────────────────────────────────────┐
  ```

---

## 2. Architecture & Subagent-Safe Lifecycle Tracking

```
~/.dotconfigs/
├── tmux/
│   ├── tmux.conf             # Window format (Line 1), pane border formats, and focus/sync hooks
│   ├── session_tabs.sh       # Multi-session aggregator and renderer (Line 0)
│   └── agents/
│       ├── agent_hook.sh         # Pane-aware lifecycle hook event handler & SQLite WAITING watcher
│       ├── AGENT_INTEGRATIONS.md # This documentation
│       └── <cli>/                # Per-CLI session persistence (claude/, antigravity/), see section 5
└── ~/.gemini/config/
    └── hooks.json            # Agent lifecycle hook configuration
```

### Component Roles

1. **Tmux Options**:
   - Pane Option (`@p_agent`, `@p_bell`): Tracked per-pane (`question`, `done`, `running`, or `0`). Evaluated in `pane-border-format`.
   - Window Option (`@w_agent`, `@w_bell`): Computed diff-driven by `sync_all_surfaces_atomic` aggregating all panes in that window (`question > done > running > 0`). Evaluated in `window-status-current-format` and `window-status-format` (Line 1).
   - Session Option (`@session_tabs_fmt`): Compiled atomically alongside `@p_agent` and `@w_agent` inside a single `sync.lock`-serialized `tmux` command packet (`agent_hook.sh` / `session_tabs.sh --sync`) before `refresh-client -S`, so Line 0, Line 1, and pane borders update simultaneously in a single frame with zero `#(...)` blanking on prefix or session switches.

2. **`agent_hook.sh` — Flicker-Free Multi-Agent & Subagent Tracking**:
   - **Locked Atomic State Transitions**: Every hook step (`SessionStart`, `PreInvocation`, `PreToolUse`, `PostToolUse`, `PostInvocation`, `Stop`, and `focus_pane`) mutates marker files via atomic `rename` inside `${pane_dir}/lock`, writing incoming markers (`active/*` or `awaiting_idle`) before removing outgoing ones so concurrent readers never observe zero-state gaps.
   - **Exact SQLite `WAITING` Detection with Auto-Approval Debouncing**: For CLIs backed by a per-conversation SQLite store (`conversations/<id>.db`), `PreToolUse` watches the indexed `steps` table for sustained `WAITING` (`status = 9`, `>= 450ms` on the same step) via a single `flock`-guarded watcher per conversation. Slow auto-approved main/subagent tool calls (`status = 2` `RUNNING`) and sub-400ms client auto-approvals never trigger false `` flashes, while genuine permission prompts and `ask_question` steps surface in ~0.5s and clear immediately (`0ms` debounce) once approved.
   - **Continuous `running` Across Subagent Turns (`fullyIdle`) & Crash-Safe Reaping**: Tracks active conversations independently in `${XDG_RUNTIME_DIR:-/tmp}/tmux_agent_$USER/<pane>/active/`. When a root orchestrator pauses its turn with `"fullyIdle": false` while spawned subagents or background tasks continue running, `awaiting_idle` holds the pane steady in `running` (``) across inter-stage wakeup gaps until the conversation tree (`conversation_summaries.db` root + child rows) is continuously idle or the root turn finishes with `"fullyIdle": true`. Each marker also records its owning CLI ancestor PID so abrupt CLI exits (`Ctrl-C` / `/exit` / `SIGKILL`) are reaped automatically within 1 second via `/proc/<pid>`.
   - **Root Conversation Preservation (`antigravity/session_hook.sh`)**: Subagent hooks and nested sub-CLIs firing inside the same CLI process tree never overwrite the pane's top-level `@antigravity_session` tag or wipe primary coordinator state.

3. **Pane-Level Focus, Window & Session Sync Hooks (`tmux.conf`)**:
   - `pane-focus-in`, `after-select-pane`, `after-select-window`, `client-session-changed`, `client-attached`, `pane-exited`, `after-kill-pane`, plus session/alert hooks (`session-created`, `session-closed`, `session-renamed`, `window-linked`, `window-unlinked`, `alert-bell`, `alert-activity`, `alert-silence`):
     ```tmux
     set-hook -g pane-focus-in 'run-shell -b "~/.dotconfigs/tmux/agents/agent_hook.sh focus_pane #{pane_id} >/dev/null 2>&1"'
     set-hook -g after-select-pane 'run-shell -b "~/.dotconfigs/tmux/agents/agent_hook.sh focus_pane #{pane_id} >/dev/null 2>&1"'
     set-hook -g after-select-window 'run-shell -b "~/.dotconfigs/tmux/agents/agent_hook.sh focus_pane #{pane_id} >/dev/null 2>&1"'
     set-hook -g client-session-changed 'run-shell -b "~/.dotconfigs/tmux/agents/agent_hook.sh focus_pane #{pane_id} >/dev/null 2>&1"'
     set-hook -g client-attached 'run-shell -b "~/.dotconfigs/tmux/agents/agent_hook.sh focus_pane #{pane_id} >/dev/null 2>&1"'
     set-hook -g pane-exited 'run-shell -b "~/.dotconfigs/tmux/agents/agent_hook.sh pane_exited #{hook_pane} >/dev/null 2>&1"'
     set-hook -g after-kill-pane 'run-shell -b "~/.dotconfigs/tmux/agents/agent_hook.sh pane_exited >/dev/null 2>&1"'
     ```
   - Focusing a pane clears only `done` (``) and `bell` (``), preserving `running` (``) while an active chat is thinking/executing and keeping `question` (``) visible until answered. All tmux option writes and `refresh-client -S` calls are diff-driven to prevent redundant border/status redraws.

---

## 3. Integrating Agent CLI Tools

### Method A: JSON / Lifecycle Hook Configuration (Recommended for Supported CLIs)

Configure `~/.gemini/config/hooks.json` (installed automatically by `tmux/install.sh`):

```json
{
  "agent-tmux-status": {
    "SessionStart": [
      {
        "type": "command",
        "command": "~/.dotconfigs/tmux/agents/agent_hook.sh session_start",
        "timeout": 5
      }
    ],
    "PreInvocation": [
      {
        "type": "command",
        "command": "~/.dotconfigs/tmux/agents/agent_hook.sh running",
        "timeout": 5
      }
    ],
    "PreToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "~/.dotconfigs/tmux/agents/agent_hook.sh tool_pre",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "~/.dotconfigs/tmux/agents/agent_hook.sh tool_done",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "type": "command",
        "command": "~/.dotconfigs/tmux/agents/agent_hook.sh done",
        "timeout": 5
      }
    ]
  }
}
```

---

### Method B: Shell Wrapper / Function (For Any Generic CLI Tool)

For CLI tools without native lifecycle hooks (e.g., Aider, Codex CLI, custom LLM scripts, or long-running builds):

```bash
# General wrapper for CLI agents
run_agent() {
  # 1. Mark pane as actively running when starting
  ~/.dotconfigs/tmux/agents/agent_hook.sh running

  # 2. Run the actual agent CLI
  "$@"
  local exit_code=$?

  # 3. Mark as done when the agent process exits
  ~/.dotconfigs/tmux/agents/agent_hook.sh done

  return $exit_code
}

# Example aliases:
alias aider='run_agent aider'
alias myagent='run_agent myagent --interactive'
```

---

### Method C: Direct Shell / CLI Invocations

You can invoke `agent_hook.sh` directly from bash scripts, Makefile targets, or background tasks:

```bash
# Mark pane as actively thinking / running (shows )
~/.dotconfigs/tmux/agents/agent_hook.sh running

# Mark pane as waiting for interactive user response (shows )
~/.dotconfigs/tmux/agents/agent_hook.sh question

# Clear question state once user response / tool execution finishes (returns to  if active)
~/.dotconfigs/tmux/agents/agent_hook.sh tool_done

# Mark pane as finished / turn complete (shows  when unfocused, clears when focused)
~/.dotconfigs/tmux/agents/agent_hook.sh done

# Clear active/done/question status indicators for the current conversation
~/.dotconfigs/tmux/agents/agent_hook.sh clear

# Full manual reset for a stuck pane
~/.dotconfigs/tmux/agents/agent_hook.sh reset
```

---

### Method D: Python / Node.js Script Integration

#### Python
```python
import os
import subprocess


def notify_agent_state(state: str):
  """Update tmux pane/window agent status.

  Args:
      state: "running", "question", "tool_done", "done", or "clear"
  """
  script = os.path.expanduser("~/.dotconfigs/tmux/agents/agent_hook.sh")
  if os.path.exists(script) and os.environ.get("TMUX"):
    try:
      subprocess.run([script, state], timeout=2, capture_output=True)
    except Exception:
      pass


# Usage in agent execution loop:
notify_agent_state("running")  # Agent started thinking/running
notify_agent_state("question")  # Agent asking for approval/input
# ... await user input ...
notify_agent_state("tool_done")  # Tool completed (returns to running)
notify_agent_state("done")  # Turn finished
```

#### Node.js / TypeScript
```typescript
import { execFile } from 'child_process';
import * as path from 'path';
import * as os from 'os';

function notifyAgentState(state: 'running' | 'question' | 'tool_done' | 'done' | 'clear'): void {
  if (!process.env.TMUX) return;
  const scriptPath = path.join(os.homedir(), '.dotconfigs/tmux/agents/agent_hook.sh');
  execFile(scriptPath, [state], { timeout: 2000 }, () => {});
}
```

---

## 4. Verification & Testing

1. **Test `` (Thinking / Running)**:
   ```bash
   bash ~/.dotconfigs/tmux/agents/agent_hook.sh running <<< '{}'
   # Observe cyan/blue '' in Line 0, Line 1, and the pane border (persists even while focused).
   ```

2. **Test `` (Question / Interactive Prompt)**:
   ```bash
   bash ~/.dotconfigs/tmux/agents/agent_hook.sh question <<< '{}'
   # Observe orange '' in Line 0, Line 1, and the pane border. Switch windows; '' persists.
   ```

3. **Test `tool_done` (Clearing Question Back to Running)**:
   ```bash
   bash ~/.dotconfigs/tmux/agents/agent_hook.sh tool_done <<< '{}'
   # Observe '' clears back to '' while the turn remains active.
   ```

4. **Test `` (Turn Complete)**:
   ```bash
   # Switch to another window/pane, then in the background run:
   bash ~/.dotconfigs/tmux/agents/agent_hook.sh done <<< '{}'
   # Observe green '' on the inactive pane/window/session. Focus that pane; '' clears.
   ```

---

## 5. Session Persistence (tmux-resurrect)

tmux-resurrect + tmux-continuum save the tmux layout every 15 minutes and restore it when the tmux server starts. For agent CLIs, each `agents/<cli>/` directory makes restored panes resume the same conversation instead of coming back as plain shells:

| Script | Role | Wired up in |
| :--- | :--- | :--- |
| `session_hook.sh` | Agent lifecycle hook: tags the pane with its root session ID (`@claude_session` / `@antigravity_session`). Ignores nested agents and subagents started from inside the pane. | Claude Code `SessionStart` (`~/.claude/settings.json`); Antigravity CLI `SessionStart` + `PreInvocation` (`~/.gemini/config/hooks.json`, group `tmux-resurrect`) |
| `sessions_save.sh` | resurrect post-save hook: snapshots the pane position → session ID map to `~/.local/share/tmux/<cli>_sessions.tsv`. | `@resurrect-hook-post-save-all` in `tmux.conf` |
| `resume.sh` | resurrect restore command: relaunches the CLI resuming the pane's session (`claude --resume <id>` / `agy --conversation <id>`), or a fresh session if none was saved or it no longer exists. | `@resurrect-processes` in `tmux.conf` |

`install.sh` registers the hooks (requires `jq`).

`agents/antigravity/resume.sh [command [data_dir]]` also accepts a custom wrapper command and non-default data directory. Add overrides in the gitignored `tmux/local.conf`, matching how the process appears in `ps`:

```tmux
set -ga @resurrect-processes ' "~agy-wrapper->~/.dotconfigs/tmux/agents/antigravity/resume.sh /path/to/agy-wrapper ~/.gemini/custom-data"'
```

To check: `tmux list-panes -a -F '#{pane_id} #{@antigravity_session}'` should show an ID for each agent pane after its first prompt, and `prefix + C-s` should write it to `~/.local/share/tmux/antigravity_sessions.tsv`.
