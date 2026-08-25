#!/bin/bash

# Modular top-right status information for tmux status line.
# Formats sections with distinct solid background colors and powerline chevrons ().
# Order: [Extensions] [Uptime] [RAM] [CPU] [Disk]

bg_main="#44475a"
right_sep=""

blocks=()

# 1. Modular extension hook (custom extension scripts)
ext_out=""
if [[ -n "$TMUX_STATUS_EXTENSION" && -x "$TMUX_STATUS_EXTENSION" ]]; then
  ext_out="$("$TMUX_STATUS_EXTENSION" 2>/dev/null)"
elif [[ -x "$HOME/.dotconfigs/tmux/extension.sh" ]]; then
  ext_out="$("$HOME/.dotconfigs/tmux/extension.sh" 2>/dev/null)"
elif [[ -x "$HOME/.tmux_extension.sh" ]]; then
  ext_out="$("$HOME/.tmux_extension.sh" 2>/dev/null)"
fi

if [[ -n "$ext_out" ]]; then
  if [[ "$ext_out" =~ ^(#[0-9a-fA-F]{6}):(#[0-9a-fA-F]{6}):(.*)$ ]]; then
    blocks+=("$ext_out")
  else
    blocks+=("#50fa7b:#000000:$ext_out")
  fi
fi

# 2. Uptime (Dracula Cyan background)
if command -v uptime >/dev/null 2>&1; then
  up_str="$(uptime -p 2>/dev/null | sed -E 's/^up //; s/ weeks?/w/g; s/ days?/d/g; s/ hours?/h/g; s/ minutes?/m/g; s/,//g')"
  [[ -n "$up_str" ]] && blocks+=("#8be9fd:#000000:⏱ $up_str")
fi

# 3. RAM usage (Dracula Purple background)
if command -v free >/dev/null 2>&1; then
  ram_str="$(free -h 2>/dev/null | awk '/Mem:/ {print $3 "/" $2}')"
  [[ -n "$ram_str" ]] && blocks+=("#bd93f9:#000000: $ram_str")
fi

# 4. CPU Load (Dracula Yellow background)
if [[ -r /proc/loadavg ]]; then
  cpu_str="$(awk '{print $1, $2}' /proc/loadavg 2>/dev/null)"
  [[ -n "$cpu_str" ]] && blocks+=("#f1fa8c:#000000:⚙ $cpu_str")
fi

# 5. Disk usage (Dracula Orange background)
if command -v df >/dev/null 2>&1; then
  disk_str="$(df -h "$HOME" 2>/dev/null | awk 'NR==2 {print $5}')"
  [[ -n "$disk_str" ]] && blocks+=("#ffb86c:#000000: $disk_str")
fi

# Construct chained powerline blocks matching bottom status line
output=""
prev_bg="$bg_main"

for b in "${blocks[@]}"; do
  IFS=":" read -r bg fg text <<< "$b"
  output+="#[fg=$bg,bg=$prev_bg]$right_sep#[fg=$fg,bg=$bg] $text "
  prev_bg="$bg"
done

echo "$output"
