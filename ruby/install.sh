#!/bin/bash

command -v rbenv || {
	RUBY_VERSION=2.7.0
	RBENV_ROOT=$HOME/.rbenv
	git clone --depth=1 https://github.com/rbenv/rbenv.git $RBENV_ROOT &&
	git clone --depth=1 https://github.com/rbenv/ruby-build.git $RBENV_ROOT/plugins/ruby-build &&
	echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> $PROFILE &&
	echo 'eval "$(rbenv init -)"' >> $PROFILE &&
	echo "gem: --no-document" > ~/.gemrc &&
	eval "$($RBENV_ROOT/bin/rbenv init -)" &&
	rbenv install $RUBY_VERSION &&
	rbenv global $RUBY_VERSION &&
	gem install solargraph
}
