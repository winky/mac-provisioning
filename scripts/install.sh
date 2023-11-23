#!/bin/bash

# Check if the current operating system is macOS.
# If not, display an error message and exit the script.
if [ "$(uname)" != "Darwin" ]; then
  echo "This script is only for macOS."
  exit 1
fi

# This script checks if the directory $HOME/mac-provisioning exists. If it doesn't, it clones the repository
# https://github.com/winky/mac-provisioning.git into the $HOME/mac-provisioning directory.
if [ ! -d $HOME/mac-provisioning ]; then
  git clone https://github.com/winky/mac-provisioning.git $HOME/mac-provisioning
fi

# Change directory to the mac-provisioning folder in the user's home directory
cd $HOME/mac-provisionning

# Run the 'init' target of the Makefile to initialize the provisioning process
make all
