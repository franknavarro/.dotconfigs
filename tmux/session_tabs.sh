#!/bin/bash

is_prefix="$1"
current_session="$2"

if [[ -z "$current_session" ]]; then
  current_session="$(tmux display-message -p '#S' 2>/dev/null)"
fi

sessions="$(tmux list-sessions -F "#{session_name}" 2>/dev/null)"

# Map of highest priority status per session: question > done > bell > alert
declare -A session_status

while IFS=":" read -r s_name s_agent s_pbell s_wbell s_alerts; do
  [[ -z "$s_name" ]] && continue
  cur="${session_status[$s_name]}"

  if [[ "$s_agent" == "question" ]]; then
    session_status["$s_name"]="question"
  elif [[ ( "$s_agent" == "done" || "$s_agent" == "1" ) && "$cur" != "question" ]]; then
    session_status["$s_name"]="done"
  elif [[ ( "$s_pbell" == "1" || "$s_wbell" == "1" || "$s_alerts" =~ "!" ) && "$cur" != "question" && "$cur" != "done" ]]; then
    session_status["$s_name"]="bell"
  elif [[ -n "$s_alerts" && "$cur" != "question" && "$cur" != "done" && "$cur" != "bell" ]]; then
    session_status["$s_name"]="alert"
  fi
done < <(tmux list-panes -a -F "#{session_name}:#{@agent_waiting}:#{@pane_bell}:#{window_bell_flag}:#{window_alerts}" 2>/dev/null)

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
left_separator_sub=""

output="#[fg=$fg_header,bg=$bg_header,bold] ❒ SESSIONS #[fg=$bg_header,bg=$bg_main]$left_seperator "

prev_is_active=false
is_first=true
idx=0

for s in $sessions; do
  flags=""
  case "${session_status[$s]}" in
    question) flags="❓ " ;;
    done)     flags="🤖 " ;;
    bell)     flags="🔔 " ;;
    alert)    flags="❗ " ;;
  esac

  if [[ "$s" == "$current_session" ]]; then
    output+="#[fg=$bg_main,bg=$bg_selected]$left_seperator#[fg=$fg_selected,bg=$bg_selected,bold] ${flags}${idx} $s #[fg=$bg_selected,bg=$bg_main]$left_seperator"
    prev_is_active=true
  else
    if [[ "$is_first" == false && "$prev_is_active" == false ]]; then
      output+="#[fg=$text_main,bg=$bg_main]$left_separator_sub "
    fi
    output+="#[fg=$text_main,bg=$bg_main] ${flags}${idx} $s "
    prev_is_active=false
  fi
  is_first=false
  ((idx++))
done

echo "$output"
