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

export DOTFILES=$(pwd)
export PROFILE="$(nvm_detect_profile)"

echo ". ${DOTFILES}/bash/profile" >> $PROFILE

LINUX_PACKAGES=$DOTFILES/packages.txt
sudo apt-get clean && sudo apt-get update;
xargs sudo apt-get install -y <$LINUX_PACKAGES

bash $DOTFILES/ruby/install.sh
bash $DOTFILES/node/install.sh
bash $DOTFILES/neovim/install.sh
bash $DOTFILES/tmux/install.sh
bash $DOTFILES/ls_colors/install.sh
bash $DOTFILES/git/install.sh
