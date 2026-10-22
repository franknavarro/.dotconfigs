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
chmod +x $DOTFILES/tmux/claude_session_hook.sh
chmod +x $DOTFILES/tmux/claude_sessions_save.sh
chmod +x $DOTFILES/tmux/claude_resume.sh
chmod +x $DOTFILES/tmux/antigravity_session_hook.sh
chmod +x $DOTFILES/tmux/antigravity_sessions_save.sh
chmod +x $DOTFILES/tmux/antigravity_resume.sh
ln -s -f $DOTFILES/tmux/tmux.conf $HOME/.tmux.conf

# Plugins (tmux-resurrect, tmux-continuum) via TPM; runs without a tmux server
[ -d $HOME/.tmux/plugins/tpm ] ||
	git clone -q https://github.com/tmux-plugins/tpm $HOME/.tmux/plugins/tpm
$HOME/.tmux/plugins/tpm/bin/install_plugins

# Claude Code SessionStart hook that tags panes with their session ID, so
# tmux-resurrect can resume each Claude pane's own session after a reboot
CLAUDE_SETTINGS=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
CLAUDE_HOOK=$DOTFILES/tmux/claude_session_hook.sh
if ! command -v jq >/dev/null; then
	echo "jq not found: add $CLAUDE_HOOK as a SessionStart hook in $CLAUDE_SETTINGS manually"
else
	mkdir -p "$(dirname $CLAUDE_SETTINGS)"
	[ -s $CLAUDE_SETTINGS ] || echo '{}' >$CLAUDE_SETTINGS
	if ! jq -e --arg cmd "$CLAUDE_HOOK" 'any(.hooks.SessionStart[]?.hooks[]?; .command == $cmd)' $CLAUDE_SETTINGS >/dev/null; then
		jq --arg cmd "$CLAUDE_HOOK" '.hooks.SessionStart += [{"hooks": [{"type": "command", "command": $cmd}]}]' $CLAUDE_SETTINGS >$CLAUDE_SETTINGS.tmp &&
			mv $CLAUDE_SETTINGS.tmp $CLAUDE_SETTINGS
	fi
fi

# Antigravity CLI SessionStart/PreInvocation hooks that tag panes with their conversation
# ID, so tmux-resurrect can resume each agy pane's own conversation after a reboot
AGY_HOOKS=${AGY_HOOKS:-$HOME/.gemini/config/hooks.json}
AGY_HOOK=$DOTFILES/tmux/antigravity_session_hook.sh
if ! command -v jq >/dev/null; then
	echo "jq not found: add $AGY_HOOK as a SessionStart and PreInvocation hook in $AGY_HOOKS manually"
else
	mkdir -p "$(dirname $AGY_HOOKS)"
	[ -s $AGY_HOOKS ] || echo '{}' >$AGY_HOOKS
	jq --arg cmd "$AGY_HOOK" '."tmux-resurrect" = {
		"SessionStart": [{"type": "command", "command": $cmd, "timeout": 5}],
		"PreInvocation": [{"type": "command", "command": $cmd, "timeout": 5}]
	}' $AGY_HOOKS >$AGY_HOOKS.tmp &&
		mv $AGY_HOOKS.tmp $AGY_HOOKS
fi

