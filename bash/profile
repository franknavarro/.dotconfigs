#!/bin/bash
# Custom bash profile

export NAME="Frank Navarro"
export TERM=xterm-256color
export LANG=en_US.UTF-8
export VISUAL=nvim
export EDITOR="$VISUAL"

function echo_nonempty() {
  if [[ ! -z "$1" ]]; then
    echo "$1"
  fi
}

alias dd="docker-compose down"
alias du="docker-compose up -d"
alias dls="docker container ls"
alias dlsa="docker container ls -a"
alias dl="docker logs -f"
alias di="docker images"
alias drm="docker"
function dfi() {
  docker image ls | grep $1
}
function dfc() {
  # fuzzy search without namespace in the name
  # e.g. wiretest_ibanking_1 will not search wiretest
  # this case will be covered in full_name_search

  NO_HEADERS=0
  SHOW_ALL=0
  for arg in "$@"; do
    case $arg in
      --no-headers)
        NO_HEADERS=1
        shift
      ;;
      -a|--all)
        SHOW_ALL=1
        shift
      ;;
    esac
  done

  containers=""
  if [[ "$SHOW_ALL" -eq 1 ]]; then
    containers=$(docker container ls -a)
  else
    containers=$(docker container ls)
  fi

  headers=""
  if [[ "$NO_HEADERS" -eq 0 ]]; then
    headers=$(echo "$containers" | awk 'NR==1 {print}')
  fi

  fuzzy_search_results=$(echo "$containers" | awk '$NF ~ /.*_.*'"$1"'.*/ {print}')
  fuzzy_search_count=$(wc -w <<< $fuzzy_search_results)

  full_name_search_result=$(echo "$containers" | awk -v n=$1 '$NF == $n {print}')
  full_name_search_count=$(wc -w <<< $full_name_search_result)

  if [ $fuzzy_search_count -ge 1 ]; then
    echo_nonempty "$headers"
    echo "$fuzzy_search_results"
  else
    if [ $full_name_search_count -eq "1" ]; then
      echo_nonempty "$headers"
      echo "$full_name_search_result"
    else
      echo_nonempty "$headers"
    fi
  fi

}
function dexec() {
  search_results=$(dfc --no-headers $1 | awk '{print $NF}')
  search_results_count=$(wc -w <<< "$search_results")
  echo $search_results
  echo $search_results_count

  if [ $search_results_count -eq "1" ]; then
    docker exec -it $search_results bash
  elif [ $search_results_count -eq "0" ]; then
    echo " ** Cannot find any container with that name"
  else
    echo " ** Multiple conntainers are found with that name"
    echo "################################"
    echo "$search_results"
    echo "################################"
    echo " ** Please use the unique key word in the name"
    echo " ** Or use the full name from the list above"
  fi
}
