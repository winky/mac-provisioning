#!/bin/bash
#
# init.sh
# Set up Homebrew and apply the Brewfile.
# Running this repeatedly must always produce the same result (idempotent).
# The Xcode Command Line Tools are not checked here: `make` is itself a CLT shim, so
# `make init` cannot reach this script without them, and the Homebrew installer pulls
# them in on the rare path that does.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISION_ROOT="$(dirname "${SCRIPT_DIR}")"
BREW_PREFIX="/opt/homebrew"

if [ "$(uname)" != "Darwin" ]; then
  echo "This script is only for macOS." >&2
  exit 1
fi

if [ "$(uname -m)" != "arm64" ]; then
  echo "This script assumes Apple Silicon (${BREW_PREFIX})." >&2
  exit 1
fi

if ! command -v brew > /dev/null 2>&1 && [ ! -x "${BREW_PREFIX}/bin/brew" ]; then
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

eval "$("${BREW_PREFIX}/bin/brew" shellenv)"

# Append brew shellenv to .zprofile exactly once.
ZPROFILE="${HOME}/.zprofile"
SHELLENV_LINE="eval \"\$(${BREW_PREFIX}/bin/brew shellenv)\""
if ! grep -Fqx "${SHELLENV_LINE}" "${ZPROFILE}" 2> /dev/null; then
  echo "${SHELLENV_LINE}" >> "${ZPROFILE}"
fi

# --no-lock was removed in Homebrew 6.x (no lockfile is generated at all).
brew bundle --file "${PROVISION_ROOT}/Brewfile"
