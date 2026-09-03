#!/bin/bash

load_homebrew_env() {
  if [ -x "/opt/homebrew/bin/brew" ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x "/usr/local/bin/brew" ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

# Find existing Homebrew or install it
if ! command -v brew >/dev/null 2>&1; then
  load_homebrew_env

  if ! command -v brew >/dev/null 2>&1; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    load_homebrew_env
  fi
fi

# Persist Homebrew loading into user profile if configured
if [ -n "$PROFILE" ]; then
  if [ -x "/opt/homebrew/bin/brew" ]; then
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$PROFILE"
  elif [ -x "/usr/local/bin/brew" ]; then
    echo 'eval "$(/usr/local/bin/brew shellenv)"' >> "$PROFILE"
  fi
fi
