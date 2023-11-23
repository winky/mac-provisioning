#!/bin/bash

# This command installs the Xcode command line tools silently, without displaying any output.
xcode-select --install > /dev/null

# This script checks if Homebrew is installed and installs it if not.
# It also adds the necessary configuration to the user's .zprofile file and sets up the environment variables.
# The script uses the Homebrew installation script from the official Homebrew GitHub repository.
# If Homebrew is already installed, the script does nothing.
if !(type "brew" > /dev/null 2>&1); then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> /Users/winky/.zprofile
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

brew bundle --no-lock --file Brewfile
