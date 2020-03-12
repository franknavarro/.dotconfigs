#!/bin/bash

export DOTFILES=$(pwd)

LINUX_PACKAGES=$DOTFILES/packages.txt
sudo apt-get clean && sudo apt-get update;
xargs sudo apt-get install -y <$LINUX_PACKAGES

bash $DOTFILES/neovim/install.sh
bash $DOTFILES/tmux/install.sh
