command -v rg || {
  RIPGREP_PATH=$HOME/ripgrep.deb
  curl -L https://github.com/BurntSushi/ripgrep/releases/download/11.0.2/ripgrep_11.0.2_amd64.deb -o $RIPGREP_PATH && \
  sudo dpkg -i $RIPGREP_PATH && \
  rm -f $RIPGREP_PATH
}
