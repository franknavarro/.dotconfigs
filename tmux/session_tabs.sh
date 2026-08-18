#!/bin/bash

current_session="$(tmux display-message -p '#S' 2>/dev/null)"
sessions="$(tmux list-sessions -F "#{session_name}" 2>/dev/null)"

is_prefix="$1"

bg_main="#44475a"
fg_active="#000000"
if [ "$is_prefix" = "1" ]; then
  bg_active="#00ff22"
else
  bg_active="#ffff00"
fi
fg_inactive="#f8f8f2"
delim_color="#6272a4"

output=""
prev_active=false
first=true

for s in $sessions; do
  if [[ "$s" == "$current_session" ]]; then
    if [ "$first" = true ]; then
      output+="#[fg=$fg_active,bg=$bg_active,bold] ❒ $s #[fg=$bg_active,bg=$bg_main]"
    else
      output+="#[fg=$bg_main,bg=$bg_active]#[fg=$fg_active,bg=$bg_active,bold] ❒ $s #[fg=$bg_active,bg=$bg_main]"
    fi
    prev_active=true
  else
    if [ "$first" = true ]; then
      output+="#[fg=$fg_inactive,bg=$bg_main] $s "
    elif [ "$prev_active" = true ]; then
      output+="#[fg=$fg_inactive,bg=$bg_main] $s "
    else
      output+="#[fg=$delim_color]#[fg=$fg_inactive,bg=$bg_main] $s "
    fi
    prev_active=false
  fi
  first=false
done

echo "$output"
