#!/bin/bash

command -v rbenv || {
	RUBY_VERSION=2.7.0
	RBENV_ROOT=$HOME/.rbenv
	git clone --depth=1 https://github.com/rbenv/rbenv.git $RBENV_ROOT &&
	git clone --depth=1 https://github.com/rbenv/ruby-build.git $RBENV_ROOT/plugins/ruby-build &&
	echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> $PROFILE &&
	echo 'eval "$(rbenv init -)"' >> $PROFILE &&
	export PATH="$RBENV_ROOT/bin:$PATH" &&
	eval "$(rbenv init -)" &&
	echo "gem: --no-document" > ~/.gemrc &&
	rbenv install $RUBY_VERSION &&
	rbenv global $RUBY_VERSION &&
	gem install solargraph
}
