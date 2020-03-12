#!/bin/bash

DOTFILES=$(pwd)

LINUX_PACKAGES='./linux/packages.txt'
sudo apt-get clean && sudo apt-get update;
xargs sudo apt-get install <$LINUX_PACKAGES

bash $DOTFILES/neovim/install.sh

ln -s -f .tmux.conf ~/.tmux.conf
