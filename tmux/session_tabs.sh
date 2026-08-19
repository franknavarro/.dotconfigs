#!/bin/bash

is_prefix="$1"
current_session="$2"

if [[ -z "$current_session" ]]; then
  current_session="$(tmux display-message -p '#S' 2>/dev/null)"
fi

sessions="$(tmux list-sessions -F "#{session_name}" 2>/dev/null)"

bg_main="#44475a"

# Header badge responds to prefix/leader
fg_header="#000000"
if [ "$is_prefix" = "1" ]; then
  bg_header="#00ff22"
else
  bg_header="#ffff00"
fi

# Selected session: constant distinct accent color (purple)
bg_selected="#bd93f9"
fg_selected="#000000"

text_main="#ffffff"
left_seperator=""

output="#[fg=$fg_header,bg=$bg_header,bold] ❒ SESSIONS #[fg=$bg_header,bg=$bg_main]$left_seperator "

for s in $sessions; do
  if [[ "$s" == "$current_session" ]]; then
    output+="#[fg=$bg_main,bg=$bg_selected]$left_seperator#[fg=$fg_selected,bg=$bg_selected,bold] $s #[fg=$bg_selected,bg=$bg_main]$left_seperator"
  else
    output+="#[fg=$text_main,bg=$bg_main] $s "
  fi
done

echo "$output"
