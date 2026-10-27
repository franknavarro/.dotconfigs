#!/bin/bash

# Modular top-right status information for tmux status line.
# Formats sections with distinct solid background colors and powerline chevrons ().
# Order: [Extensions] [Uptime] [RAM] [CPU] [Disk]

bg_main="#44475a"
right_sep=""
right_sub_sep=""

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
  while IFS= read -r ext_line; do
    [[ -z "$ext_line" ]] && continue
    if [[ "$ext_line" =~ ^(#[0-9a-fA-F]{6}):(#[0-9a-fA-F]{6}):(.*)$ ]]; then
      blocks+=("$ext_line")
    else
      blocks+=("#50fa7b:#000000:$ext_line")
    fi
  done <<< "$ext_out"
fi

# 2. Uptime (Dracula Cyan background)
if command -v uptime >/dev/null 2>&1; then
  up_str="$(uptime -p 2>/dev/null | sed -E 's/^up //; s/ weeks?/w/g; s/ days?/d/g; s/ hours?/h/g; s/ minutes?/m/g; s/,//g' | awk '{print $1 $2}')"
  [[ -n "$up_str" ]] && blocks+=("#8be9fd:#000000:⏱ $up_str")
fi

# 3. RAM usage (Dracula Purple background)
if command -v free >/dev/null 2>&1; then
  ram_used=$(free -h 2>/dev/null | awk '/Mem:/ {print $3}' | sed 's/Gi//')
  ram_tot=$(free -h 2>/dev/null | awk '/Mem:/ {print $2}')
  ram_pct=$(free -m 2>/dev/null | awk '/Mem:/ {if ($2 > 0) printf "%.0f", ($3 / $2) * 100}')
  if [[ -n "$ram_used" && -n "$ram_tot" ]]; then
    blocks+=("#bd93f9:#000000:󰍛 ${ram_used}/${ram_tot} (${ram_pct}%)")
  fi
fi

# 4. CPU Load (Dracula Yellow background)
if [[ -r /proc/loadavg ]]; then
  load1=$(awk '{printf "%.1f", $1}' /proc/loadavg 2>/dev/null)
  ncpus=$(nproc 2>/dev/null || echo 1)
  cpu_pct=$(awk "BEGIN {printf \"%.0f\", ($load1 / $ncpus) * 100}")
  blocks+=("#f1fa8c:#000000: ${load1}/${ncpus}C (${cpu_pct}%)")
fi

# 5. Disk usage (Dracula Orange background)
if command -v df >/dev/null 2>&1; then
  disk_used=$(df -h "$HOME" 2>/dev/null | awk 'NR==2 {print $3}' | sed 's/G$//')
  disk_tot=$(df -h "$HOME" 2>/dev/null | awk 'NR==2 {print $2}')
  disk_pct=$(df -h "$HOME" 2>/dev/null | awk 'NR==2 {print $5}')
  if [[ -n "$disk_used" && -n "$disk_tot" ]]; then
    blocks+=("#ffb86c:#000000:󰋊 ${disk_used}/${disk_tot} (${disk_pct})")
  fi
fi

# Construct chained powerline blocks matching bottom status line
output=""
prev_bg="$bg_main"

for b in "${blocks[@]}"; do
  IFS=":" read -r bg fg text <<< "$b"
  if [[ "$bg" == "$prev_bg" ]]; then
    output+="#[fg=$fg,bg=$bg]$right_sub_sep $text "
  else
    output+="#[fg=$bg,bg=$prev_bg]$right_sep#[fg=$fg,bg=$bg] $text "
  fi
  prev_bg="$bg"
done

echo "$output"
