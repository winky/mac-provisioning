#!/bin/bash
set -eu

PROVISIONPATH=$HOME/mac-provisioning

if [ ! -d "$PROVISIONPATH" ]; then
  git clone https://github.com/winky/mac-provisioning.git "$PROVISIONPATH"
else

cd $PROVISIONPATH

make init
