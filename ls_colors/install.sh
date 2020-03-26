#!/bin/bash

cd $HOME &&
  git clone https://github.com/trapd00r/LS_COLORS.git $HOME/LS_COLORS &&
  cd $HOME/LS_COLORS &&
  sudo sh install.sh &&
  source $HOME/.local/share/lscolors.sh &&
  echo ". $HOME/.local/share/lscolors.sh" >> $PROFILE &&
  rm -r $HOME/LS_COLORS
