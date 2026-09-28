#!/bin/bash
#
# host-profile.sh
# Print the provisioning profile for this machine: either "laptop" or "mac-mini".
#
# Both machines are provisioned over a local connection, so nothing in an ansible
# inventory distinguishes them. The profile is derived from the hardware instead, which
# is why the Mac mini needs no extra argument on the day it arrives -- `make deploy`
# with no arguments resolves to the right profile on either machine.
#
# The marketing name is used rather than the model identifier. Apple stopped putting the
# product name in the identifier: a Mac mini used to report "Macmini9,1" but now reports
# "Mac14,12" or "Mac16,10", so matching on it would fail on exactly the new machine this
# repository exists to set up. "Model Name" still reads "Mac mini".
#
# HOST_PROFILE overrides the detection, for a VM, a CI runner, or any machine whose
# model is neither of the two. An unrecognised model is an error rather than a guess:
# provisioning a laptop as the always-on box is worse than stopping.
#
set -euo pipefail

if [ -n "${HOST_PROFILE:-}" ]; then
  echo "${HOST_PROFILE}"
  exit 0
fi

if [ "$(uname)" != "Darwin" ]; then
  echo "This script is only for macOS." >&2
  exit 1
fi

model="$(system_profiler SPHardwareDataType 2> /dev/null \
  | awk -F': ' '/Model Name/ { print $2; exit }')"

case "${model}" in
  "Mac mini") echo "mac-mini" ;;
  MacBook*) echo "laptop" ;;
  *)
    cat >&2 <<MSG
Unrecognised model: ${model:-<empty>}

This machine matches neither profile. Set HOST_PROFILE explicitly:

  HOST_PROFILE=laptop   make deploy
  HOST_PROFILE=mac-mini make deploy

MSG
    exit 1
    ;;
esac
