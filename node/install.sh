command -v node || {
	export PROFILE=$DOTFILES/profile_auto
	export NVM_DIR=$HOME/.nvm
  NVM_VERSION=0.34.0
  mkdir -p ${NVM_DIR} &&
  curl https://raw.githubusercontent.com/creationix/nvm/v${NVM_VERSION}/install.sh | bash &&
  . $NVM_DIR/nvm.sh &&
  nvm install --lts && 
  nvm use --lts
}
