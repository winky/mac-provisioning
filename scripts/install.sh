#!/bin/bash
#
# install.sh
# The first script to run on a new Mac.
# Clones this repository under the ghq root and runs make all.
#
set -euo pipefail

REPO_URL="https://github.com/winky/mac-provisioning.git"
REPO_PATH="github.com/winky/mac-provisioning"

if [ "$(uname)" != "Darwin" ]; then
  echo "This script is only for macOS." >&2
  exit 1
fi

# Checked again in scripts/init.sh, which hardcodes the Apple Silicon Homebrew prefix.
# Bail out here too so an unsupported machine never gets a half-finished clone.
if [ "$(uname -m)" != "arm64" ]; then
  echo "This script assumes Apple Silicon." >&2
  exit 1
fi

# On a pristine macOS, git and make are the same Xcode Command Line Tools shim binary:
# running either pops up an install dialog and fails. This is the only place the check
# belongs -- it has to pass before `git clone` and before `make` can run at all.
if ! xcode-select -p > /dev/null 2>&1; then
  xcode-select --install || true
  echo "Started installing the Xcode Command Line Tools. Re-run this script once it finishes." >&2
  exit 1
fi

# ghq may not be installed yet, so resolve the root in this order:
# ghq itself, the environment variable, git config, then a default.
# ghq arrives with the dotfiles, which are installed after this script on a first run,
# so the default is the root actually in use rather than the ghq default (~/ghq).
if command -v ghq > /dev/null 2>&1; then
  GHQ_ROOT="$(ghq root)"
else
  GHQ_ROOT="${GHQ_ROOT:-$(git config --get ghq.root 2> /dev/null || echo "${HOME}/src")}"
fi

# git config returns the value with the tilde unexpanded (e.g. "~/src").
# Without expanding it, a directory literally named "~" is created in the current directory.
GHQ_ROOT="${GHQ_ROOT/#\~/${HOME}}"

PROVISION_ROOT="${GHQ_ROOT}/${REPO_PATH}"

if [ ! -d "${PROVISION_ROOT}" ]; then
  mkdir -p "$(dirname "${PROVISION_ROOT}")"
  git clone "${REPO_URL}" "${PROVISION_ROOT}"
fi

make -C "${PROVISION_ROOT}" all
