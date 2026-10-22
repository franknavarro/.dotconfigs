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
chmod +x $DOTFILES/tmux/agents/agent_hook.sh
chmod +x $DOTFILES/tmux/agents/claude/session_hook.sh
chmod +x $DOTFILES/tmux/agents/claude/sessions_save.sh
chmod +x $DOTFILES/tmux/agents/claude/resume.sh
chmod +x $DOTFILES/tmux/agents/antigravity/session_hook.sh
chmod +x $DOTFILES/tmux/agents/antigravity/sessions_save.sh
chmod +x $DOTFILES/tmux/agents/antigravity/resume.sh
ln -s -f $DOTFILES/tmux/tmux.conf $HOME/.tmux.conf

# Plugins (tmux-resurrect, tmux-continuum) via TPM; runs without a tmux server
[ -d $HOME/.tmux/plugins/tpm ] ||
	git clone -q https://github.com/tmux-plugins/tpm $HOME/.tmux/plugins/tpm
$HOME/.tmux/plugins/tpm/bin/install_plugins

# Claude Code SessionStart hook that tags panes with their session ID, so
# tmux-resurrect can resume each Claude pane's own session after a reboot
CLAUDE_SETTINGS=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
CLAUDE_HOOK=$DOTFILES/tmux/agents/claude/session_hook.sh
if ! command -v jq >/dev/null; then
	echo "jq not found: add $CLAUDE_HOOK as a SessionStart hook in $CLAUDE_SETTINGS manually"
else
	mkdir -p "$(dirname $CLAUDE_SETTINGS)"
	[ -s $CLAUDE_SETTINGS ] || echo '{}' >$CLAUDE_SETTINGS
	# Drop the hook's pre-agents/ path, then add the current one if missing
	CLAUDE_HOOK_OLD=$DOTFILES/tmux/claude_session_hook.sh
	jq --arg cmd "$CLAUDE_HOOK" --arg old "$CLAUDE_HOOK_OLD" '
		.hooks.SessionStart = [(.hooks.SessionStart // [])[] | .hooks |= map(select(.command != $old)) | select(.hooks != [])]
		| if any(.hooks.SessionStart[].hooks[]?; .command == $cmd) then .
		  else .hooks.SessionStart += [{"hooks": [{"type": "command", "command": $cmd}]}] end
	' $CLAUDE_SETTINGS >$CLAUDE_SETTINGS.tmp &&
		mv $CLAUDE_SETTINGS.tmp $CLAUDE_SETTINGS
fi

# Antigravity CLI SessionStart/PreInvocation hooks that tag panes with their conversation
# ID, so tmux-resurrect can resume each agy pane's own conversation after a reboot
AGY_HOOKS=${AGY_HOOKS:-$HOME/.gemini/config/hooks.json}
AGY_HOOK=$DOTFILES/tmux/agents/antigravity/session_hook.sh
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

