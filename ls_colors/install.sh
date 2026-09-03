#!/bin/bash

echo "Installing LS_COLORS"
cd $HOME &&
  mkdir -p $HOME/.local/share &&
  git clone https://github.com/trapd00r/LS_COLORS.git $DOTFILES_TMP/LS_COLORS &&
  cd $DOTFILES_TMP/LS_COLORS &&
  sh install.sh &&
  source $HOME/.local/share/lscolors.sh &&
  echo ". $HOME/.local/share/lscolors.sh" >> $PROFILE &&
  rm -rf $DOTFILES_TMP/LS_COLORS
