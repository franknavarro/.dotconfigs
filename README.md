# Dotfiles (.dotconfigs)

A modular, cross-platform collection of dotfiles, shell configurations, and developer environment tooling.

---

## Repository Structure

```
~/.dotconfigs/
├── bash/                      # Bash configurations and aliases
├── brew/                      # Homebrew package bundles and installation manifests
├── git/                       # Global Git configurations and ignore rules
├── ls_colors/                 # Terminal color configurations
├── neovim/                    # Symlink / bootstrap helper for Neovim config
├── packages/                  # System package lists
├── ripgrep/                   # Global ripgrep search configuration (.ripgreprc)
├── tmux/                      # Modular tmux configuration and statusline scripts
│   ├── tmux.conf              # Master tmux configuration (2-line status bar)
│   ├── session_tabs.sh        # Dynamic session tab renderer
│   ├── top_right_info.sh      # Modular powerline statusbar widget engine
│   └── extension.sh           # (Untracked) Machine-specific statusbar bridge
└── install.sh                 # Dotfiles installer and symlink orchestrator
```

---

## Core Components

### 1. Tmux (`tmux/`)
- **Two-Line Status Bar**:
  - **Line 0 (Top)**: Active and background Tmux sessions with powerline styling (`session_tabs.sh`).
  - **Line 1 (Bottom)**: Active session windows and pane tabs.
- **Top-Right Statusline Widgets (`top_right_info.sh`)**:
  - Modular, high-contrast Powerline status pills: `[custom extension]  [uptime]  [ram]  [cpu]  [disk]`.
  - Machine-specific indicators dynamically loaded via an untracked `extension.sh`.
- **Modern Pane Indicators**:
  - Distinct active pane borders with `pane-border-lines heavy` and `pane-border-indicators both`.

### 2. Neovim (`~/.config/nvim/`)
- Managed in a standalone repository with pure Lua modularity.
- **Focus Dimming**: Smooth, focus-aware syntax dimming that preserves distinct colors while subduing inactive panes.
- **Declarative Extension Model**: Untracked `local-config.lua` dynamically bridges machine-specific plugins and LSP configs.

---

## Machine-Specific Extensions

Both Tmux and Neovim support local, untracked extension hooks so you can keep company or workstation-specific tools out of public repositories:

- **Tmux**: Create `~/.dotconfigs/tmux/extension.sh` (already gitignored) to output local status widgets.
- **Neovim**: Create `~/.config/nvim/lua/local-config.lua` (already gitignored) to register local plugins and lifecycle hooks.

---

## Installation

```bash
git clone <repo-url> ~/.dotconfigs
cd ~/.dotconfigs
./install.sh
```
