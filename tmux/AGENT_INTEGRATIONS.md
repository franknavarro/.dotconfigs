# Agent CLI Tmux Status & Notification System

A unified, real-time visual notification system for Tmux that tracks the execution lifecycle of autonomous AI agents, CLI pair programmers, and background tasks across multi-session environments.

---

## 1. Visual Indicators & Multi-Level Hierarchy

The system displays a single visual indicator with strict precedence across all three structural levels (**Session Tabs Line 0**, **Window Tabs Line 1**, and **Pane Borders**):

| Precedence | Icon | State | Meaning | Clearing Behavior |
| :---: | :---: | :--- | :--- | :--- |
| **1 (Highest)** | **`❓`** | `question` | **Interactive Prompt / Approval**: Agent is waiting for user confirmation, permission grant, or clarification answer. | **Persistent**: Does **not** clear when navigating between panes or windows. Only clears when the user actually responds and tool execution completes. |
| **2** | **`🤖`** | `done` | **Turn Complete**: Agent finished processing the prompt/turn and is waiting at the standard user prompt. | **Pane-Focus Clearing**: Clears automatically as soon as the user focuses/navigates specifically into that **pane**. |
| **3** | **`🔔`** | `bell` | **Application Bell**: Standard terminal BEL character (`\a` / `0x07`). | **Pane-Focus Clearing**: Clears as soon as that **pane** becomes active. |
| **4 (Lowest)** | **`❗`** | `alert` | **Background Alerts / Silence**: Window alerts / silence monitoring triggers. | Clears upon window focus. |

### Visual Layout Hierarchy

- **Line 0 (Sessions Bar)**: Displays the highest-precedence indicator among all windows and panes in that session:
  ```
  ❒ SESSIONS  dev  reviewer  ❓ api-refactor  🤖 workspace 
  ```
- **Line 1 (Windows Bar)**: Displays the highest-precedence indicator among all panes within that window:
  ```
  ❐ WINDOWS  1 editor  ❓ 2 agent  🤖 3 build 
  ```
- **Pane Borders (`top`)**: Displays the specific status icon of each inactive pane in its top border:
  ```
  ┌── 🤖 2: python [~/projects/my-app/src] ──────────────────────────────┐
  ```

---

## 2. Architecture & Components

```
~/.dotconfigs/
├── tmux/
│   ├── tmux.conf             # Window format (Line 1), pane border formats, and focus hooks
│   ├── session_tabs.sh       # Multi-session aggregator and renderer (Line 0)
│   ├── agent_hook.sh         # Pane-aware lifecycle hook event handler & window synchronizer
│   └── AGENT_INTEGRATIONS.md # This documentation
└── ~/.gemini/config/
    └── hooks.json            # Agent lifecycle hook configuration
```

### Component Roles

1. **Tmux Options**:
   - Pane Option (`@p_agent`, `@p_bell`): Tracked per-pane. Evaluated in `pane-border-format`.
   - Window Option (`@w_agent`, `@w_bell`): Computed automatically by `sync_window` aggregating all panes in that window. Evaluated in `window-status-current-format` and `window-status-format` (Line 1).
   - Session Level: Aggregated across all panes in all windows by `session_tabs.sh` (Line 0).

2. **`agent_hook.sh`**:
   - Receives lifecycle event triggers from CLI tools targeting the pane identified by `$TMUX_PANE` or explicit argument `#{pane_id}`.
   - Automatically synchronizes pane states to the parent window via `sync_window`.
   - Outputs valid JSON conforming to agent hook protocols (e.g. `{"decision": "allow"}` for `PreToolUse`, `{}` for `PostToolUse`).

3. **Pane-Level Focus & Alert Hooks (`tmux.conf`)**:
   - `pane-focus-in`, `after-select-pane`, `after-select-window`:
     ```tmux
     set-hook -g pane-focus-in 'run-shell -b "~/.dotconfigs/tmux/agent_hook.sh focus_pane #{pane_id}"'
     set-hook -g after-select-pane 'run-shell -b "~/.dotconfigs/tmux/agent_hook.sh focus_pane #{pane_id}"'
     set-hook -g after-select-window 'run-shell -b "~/.dotconfigs/tmux/agent_hook.sh focus_pane #{pane_id}"'
     set-hook -g alert-bell 'run-shell -b "~/.dotconfigs/tmux/agent_hook.sh bell #{pane_id}"'
     ```
   - When a specific pane receives focus, only that pane's `done` (`🤖`) and bell (`🔔`) are cleared, preserving active states on other panes and keeping `question` (`❓`) active until tool completion.

---

## 3. Integrating Other Agent CLI Tools

You can integrate any AI agent CLI, runner script, or terminal workflow using one of the following methods.

### Method A: JSON / Lifecycle Hook Configuration (Recommended for Supported CLIs)

For agents with built-in lifecycle hook support (such as the Antigravity CLI or Claude Code):

Configure your hook manifest (e.g. `~/.gemini/config/hooks.json` or agent config):

```json
{
  "agent-tmux-status": {
    "PreToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "~/.dotconfigs/tmux/agent_hook.sh question"
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
            "command": "~/.dotconfigs/tmux/agent_hook.sh tool_done"
          }
        ]
      }
    ],
    "Stop": [
      {
        "type": "command",
        "command": "~/.dotconfigs/tmux/agent_hook.sh done"
      }
    ],
    "PreInvocation": [
      {
        "type": "command",
        "command": "~/.dotconfigs/tmux/agent_hook.sh clear"
      }
    ]
  }
}
```

---

### Method B: Shell Wrapper / Function (For Any Generic CLI Tool)

For CLI tools without native lifecycle hooks (e.g., Aider, Codex CLI, custom LLM scripts, or long-running builds), create a shell wrapper in your shell configuration or scripts directory:

```bash
# General wrapper for CLI agents
run_agent() {
  # 1. Clear previous status when starting
  ~/.dotconfigs/tmux/agent_hook.sh clear

  # 2. Run the actual agent CLI
  "$@"
  local exit_code=$?

  # 3. Mark as done when the agent process exits
  ~/.dotconfigs/tmux/agent_hook.sh done

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
# Mark window as waiting for interactive user response (shows ❓)
~/.dotconfigs/tmux/agent_hook.sh question

# Clear question state once user response / tool execution finishes
~/.dotconfigs/tmux/agent_hook.sh tool_done

# Mark window as finished / turn complete (shows 🤖)
~/.dotconfigs/tmux/agent_hook.sh done

# Clear all status indicators
~/.dotconfigs/tmux/agent_hook.sh clear
```

Alternatively, direct `tmux` commands:

```bash
# Set directly via tmux CLI targeting the current pane's window:
target_opt=(-t "$TMUX_PANE")

# Set question (❓)
tmux set-option "${target_opt[@]}" -w @agent_waiting question

# Set done (🤖)
tmux set-option "${target_opt[@]}" -w @agent_waiting done

# Clear
tmux set-option "${target_opt[@]}" -w @agent_waiting 0
```

---

### Method D: Python / Node.js Script Integration

To instrument Python or Node.js agent scripts directly:

#### Python
```python
import os
import subprocess


def notify_agent_state(state: str):
  """Update tmux window agent status.

  Args:
      state: "question", "tool_done", "done", or "clear"
  """
  script = os.path.expanduser("~/.dotconfigs/tmux/agent_hook.sh")
  if os.path.exists(script) and os.environ.get("TMUX"):
    try:
      subprocess.run([script, state], timeout=2, capture_output=True)
    except Exception:
      pass


# Usage in agent execution loop:
notify_agent_state("clear")  # User sent prompt
notify_agent_state("question")  # Agent asking for approval/input
# ... await user input ...
notify_agent_state("tool_done")  # Tool completed
notify_agent_state("done")  # Turn finished
```

#### Node.js / TypeScript
```typescript
import { execFile } from 'child_process';
import * as path from 'path';
import * as os from 'os';

function notifyAgentState(state: 'question' | 'tool_done' | 'done' | 'clear'): void {
  if (!process.env.TMUX) return;
  const scriptPath = path.join(os.homedir(), '.dotconfigs/tmux/agent_hook.sh');
  execFile(scriptPath, [state], { timeout: 2000 }, () => {});
}
```

---

## 4. Verification & Testing

To test and verify the notification indicators:

1. **Test `❓` (Question / Interactive Prompt)**:
   ```bash
   bash ~/.dotconfigs/tmux/agent_hook.sh question <<< '{}'
   # Observe '❓' in Line 0 and Line 1. Switch windows back and forth; '❓' will persist.
   ```

2. **Test `tool_done` (Clearing Question)**:
   ```bash
   bash ~/.dotconfigs/tmux/agent_hook.sh tool_done <<< '{}'
   # Observe '❓' disappears.
   ```

3. **Test `🤖` (Turn Complete)**:
   ```bash
   # Switch to another window, then in the background run:
   bash ~/.dotconfigs/tmux/agent_hook.sh done <<< '{}'
   # Observe '🤖' on the inactive window. Switch to that window; '🤖' automatically clears.
   ```
