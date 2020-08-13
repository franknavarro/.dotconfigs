#!/bin/bash

# Taken from nvm to help detect user profile
# https://github.com/nvm-sh/nvm/blob/master/install.sh
nvm_try_profile() {
  if [ -z "${1-}" ] || [ ! -f "${1}" ]; then
    return 1
  fi
  echo "${1}"
}

#
# Detect profile file if not specified as environment variable
# (eg: PROFILE=~/.myprofile)
# The echo'ed path is guaranteed to be an existing file
# Otherwise, an empty string is returned
#
nvm_detect_profile() {
  if [ "${PROFILE-}" = '/dev/null' ]; then
    # the user has specifically requested NOT to have nvm touch their profile
    return
  fi

  if [ -n "${PROFILE}" ] && [ -f "${PROFILE}" ]; then
    echo "${PROFILE}"
    return
  fi

  local DETECTED_PROFILE
  DETECTED_PROFILE=''

  if [ -n "${BASH_VERSION-}" ]; then
    if [ -f "$HOME/.bashrc" ]; then
      DETECTED_PROFILE="$HOME/.bashrc"
    elif [ -f "$HOME/.bash_profile" ]; then
      DETECTED_PROFILE="$HOME/.bash_profile"
    fi
  elif [ -n "${ZSH_VERSION-}" ]; then
    DETECTED_PROFILE="$HOME/.zshrc"
  fi

  if [ -z "$DETECTED_PROFILE" ]; then
    for EACH_PROFILE in ".profile" ".bashrc" ".bash_profile" ".zshrc"
    do
      if DETECTED_PROFILE="$(nvm_try_profile "${HOME}/${EACH_PROFILE}")"; then
        break
      fi
    done
  fi

  if [ -n "$DETECTED_PROFILE" ]; then
    echo "$DETECTED_PROFILE"
  fi
}

install_dotconfigs_help() {
  echo
  echo "Usage: install [OPTIONS]"
  echo
  echo "Install necessary development tools"
  echo
  echo "Options:"
  echo "    --debian8   Download packages for compatibility with debian 8"
  echo "-e, --except    Pass in a comma seperated list of applications to not install"
  echo "-h, --help      Print usage"
  echo "-o, --only      Pass in a comma seperated list of applications to install"
  echo
  echo "NOTE: By default the command will install all the following tools if they already aren't installed on your system (ruby, node, neovim, tmux, ls_colors, ripgrep, git)"

}

EXCEPT_LIST=""
ONLY_LIST=""

RUBY_INSTALL=true
NODE_INSTALL=true
NEOVIM_INSTALL=true
TMUX_INSTALL=true
LS_COLORS_INSTALL=true
RIPGREP_INSTALL=true
GIT_INSTALL=true
PYTHON_INSTALL=true
PACKAGE_FILE="debian.txt"

for arg in "$@"; do
  case $arg in
    --debian8) 
      PACKAGE_FILE="debian8.txt"
      shift
    ;;
    -e*|--except*)
      EXCEPT_LIST=$(echo "$arg" | sed -e 's/^[^= ]*[= ]\?//g')
      shift
      if [[ -z "$EXCEPT_LIST" ]]; then
        EXCEPT_LIST="$1"
        shift
      fi
    ;;
    -o*|--only*)
      RUBY_INSTALL=false
      NODE_INSTALL=false
      NEOVIM_INSTALL=false
      TMUX_INSTALL=false
      LS_COLORS_INSTALL=false
      RIPGREP_INSTALL=false
      GIT_INSTALL=false
      PYTHON_INSTALL=false
      ONLY_LIST=$(echo "$arg" | sed -e 's/^[^= ]*[= ]\?//g')
      shift
      if [[ -z "$ONLY_LIST" ]]; then
        ONLY_LIST="$1"
        shift
      fi
    ;;
    -h|--help)
      install_dotconfigs_help
      return
    ;;
  esac
done

IFS=, read -r -a only_list <<< "$ONLY_LIST"
IFS=, read -r -a except_list <<< "$EXCEPT_LIST"

for only in "${only_list[@]}"; do
  only="${only,,}"
  case $only in
    ruby) RUBY_INSTALL=true ;;
    node) NODE_INSTALL=true ;;
    neovim|nvim) NEOVIM_INSTALL=true ;;
    tmux) TMUX_INSTALL=true ;;
    ls_colors) LS_COLORS_INSTALL=true ;;
    ripgrep) RIPGREP_INSTALL=true ;;
    git) GIT_INSTALL=true ;;
    python) PYTHON_INSTALL=true ;;
  esac
done

for except in "${except_list[@]}"; do
  except="${except,,}"
  case $except in
    ruby) RUBY_INSTALL=false ;;
    node) NODE_INSTALL=false ;;
    neovim|nvim) NEOVIM_INSTALL=false ;;
    tmux) TMUX_INSTALL=false ;;
    ls_colors) LS_COLORS_INSTALL=false ;;
    ripgrep) RIPGREP_INSTALL=false ;;
    git) GIT_INSTALL=false ;;
    python) PYTHON_INSTALL=false ;;
  esac
done

export DOTFILES=$(pwd)
export PROFILE="$(nvm_detect_profile)"
echo $PROFILE

echo ". ${DOTFILES}/bash/profile" >> $PROFILE

LINUX_PACKAGES=$DOTFILES/packages/$PACKAGE_FILE
sudo apt-get clean && sudo apt-get update;
xargs sudo apt-get install -y <$LINUX_PACKAGES

if [ "$PYTHON_INSTALL" = true ] ; then
  echo 'INSTALLING PYTHON'
  command -v python3 || {
    sudo apt-get install -y python3
  }
fi
if [ "$RUBY_INSTALL" = true ] ; then
  echo 'INSTALLING RUBY'
  bash $DOTFILES/ruby/install.sh
fi
if [ "$NODE_INSTALL" = true ] ; then
  echo 'INSTALLING NODE'
  bash $DOTFILES/node/install.sh
fi
if [ "$NEOVIM_INSTALL" = true ] ; then
  echo 'INSTALLING NEOVIM'
  bash $DOTFILES/neovim/install.sh
fi
if [ "$TMUX_INSTALL" = true ] ; then
  echo 'INSTALLING TMUX'
  bash $DOTFILES/tmux/install.sh
fi
if [ "$LS_COLORS_INSTALL" = true ] ; then
  echo 'INSTALLING LS_COLORS'
  bash $DOTFILES/ls_colors/install.sh
fi
if [ "$RIPGREP_INSTALL" = true ] ; then
  echo 'INSTALLING RIPGREP'
  bash $DOTFILES/ripgrep/install.sh
fi
if [ "$GIT_INSTALL" = true ] ; then
  echo 'INSTALLING GIT'
  bash $DOTFILES/git/install.sh
fi
