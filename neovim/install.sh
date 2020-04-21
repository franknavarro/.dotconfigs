#!/bin/bash

# Install neovim
command -v nvim >/dev/null || {
	NEOVIM_SRC=$HOME/neovim-src
  git clone --depth=1 --single-branch --branch stable https://github.com/neovim/neovim.git $NEOVIM_SRC &&
	cd $NEOVIM_SRC &&
	make -s CMAKE_BUILD_TYPE=Release &&
	sudo make -s install &&
	cd $DOTFILES &&
	rm -rf $NEOVIM_SRC
}

# Install neovim configs
mkdir -p ~/.config/nvim &&
git clone https://github.com/franknavarro/nvim.git ~/.config/nvim &&
nvim --headless +PlugInstall +qa
