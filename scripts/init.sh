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
  # NONINTERACTIVE keeps the installer from waiting on a RETURN it cannot receive through a
  # pipe -- but it also keeps it from asking for a sudo password, because the mode assumes sudo
  # already works. On a machine that has never been provisioned nothing is cached, and the
  # install stops with "insufficient permissions to install homebrew to /opt/homebrew".
  #
  # Priming the credentials first is what makes that assumption true. sudo reads the password
  # from the terminal rather than from stdin, so this works even when this script arrived
  # through `curl | bash` and stdin is the pipe.
  #
  # Only on the path that installs Homebrew: a machine that already has it should not be asked
  # for a password it does not need.
  if ! sudo -v; then
    echo "Homebrew has to be installed into ${BREW_PREFIX}, which needs sudo." >&2
    echo "This account cannot use sudo, so it is not an administrator." >&2
    echo "Create the first account as an administrator in the macOS setup wizard." >&2
    exit 1
  fi
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

# Machine-specific packages. host-profile.sh exits non-zero on a model it does not
# recognise and `set -e` stops us here, so there is no path where the profile file is
# silently skipped and the machine ends up half-provisioned.
PROFILE="$("${SCRIPT_DIR}/host-profile.sh")"
brew bundle --file "${PROVISION_ROOT}/Brewfile.${PROFILE}"
