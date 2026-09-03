command -v tmux >/dev/null || {
	TMUX_VERSION=3.1
	cd $DOTFILES_TMP &&
	curl -LOsS https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz &&
	tar xf tmux-${TMUX_VERSION}.tar.gz &&
	cd $DOTFILES_TMP/tmux-${TMUX_VERSION} &&
	./configure &&
	make -s &&
	sudo make -s install &&
	cd $DOTFILES &&
	rm -rf $DOTFILES_TMP/tmux-${TMUX_VERSION}/ &&
	rm -f $DOTFILES_TMP/tmux-${TMUX_VERSION}.tar.gz
}

chmod +x $DOTFILES/tmux/session_tabs.sh
chmod +x $DOTFILES/tmux/top_right_info.sh
chmod +x $DOTFILES/tmux/agent_hook.sh
ln -s -f $DOTFILES/tmux/tmux.conf $HOME/.tmux.conf

