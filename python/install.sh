#!/bin/bash

command -v pyenv || {
  PYTHON_VERSION=3.8.0
  PYENV_ROOT=$HOME/.pyenv
  git clone --depth=1 https://github.com/pyenv/pyenv.git $PYENV_ROOT &&
  git clone https://github.com/pyenv/pyenv-virtualenv.git $PYENV_ROOT/plugins/pyenv-virtualenv &&
  echo 'export PYENV_ROOT="$HOME/.pyenv"' >> $PROFILE &&
  echo 'export PATH="$PYENV_ROOT/bin:$PATH"' >> $PROFILE &&
  echo 'eval "$(pyenv init -)"' >> $PROFILE &&
  echo 'eval "$(pyenv virtualenv-init -)"' >> $PROFILE &&
  export PATH="$PYENV_ROOT/bin:$PATH" &&
  eval "$(pyenv init -)" &&
  pyenv install $PYTHON_VERSION &&
  pyenv global $PYTHON_VERSION
}
