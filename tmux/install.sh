command -v tmux >/dev/null || {
	TMUX_VERSION=3.0
	cd $HOME
	curl -LOsS https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz &&
	tar xf tmux-${TMUX_VERSION}.tar.gz &&
	cd $HOME/tmux-${TMUX_VERSION} &&
	./configure &&
	make -s &&
	sudo make -s install &&
	cd $HOME &&
	rm -rf $HOME/tmux-${TMUX_VERSION}/ &&
	rm -f $HOME/tmux-${TMUX_VERSION}.tar.gz
}

ln -s -f $DOTFILES/tmux/tmux.conf $HOME/.tmux.conf
