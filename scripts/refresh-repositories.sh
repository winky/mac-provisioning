#!/bin/bash
#
# refresh-repositories.sh
# Bring every repository under the ghq root up to date, and say what was left alone.
#
# Run from launchd every morning, and by hand whenever. It never merges, rebases or
# stashes: a repository is either fast-forwardable on its default branch with nothing
# uncommitted, or it is skipped. Anything that needs a decision is a decision for a person.
#
# Being late is harmless, which matters because launchd cannot run this at 07:00 on a
# machine nobody has unlocked yet -- a LaunchAgent is not loaded until then. The job catches
# up when it can and nothing here depends on the time it ran.
#
# Most skips are not problems. Ten repositories sitting on a feature branch and six with
# uncommitted work is what a working machine looks like, so those are counted rather than
# listed. Only states that want fixing once -- a broken repository, a detached HEAD, a
# remote with no default branch recorded, a pull that failed -- are named.
#
set -euo pipefail

DRY_RUN=false
for argument in "$@"; do
  case "${argument}" in
    --dry-run) DRY_RUN=true ;;
    *)
      echo "usage: $(basename "$0") [--dry-run]" >&2
      exit 2
      ;;
  esac
done

# Same resolution order as scripts/install.sh, so both agree on a machine where the dotfiles
# have not been linked yet.
if command -v ghq > /dev/null 2>&1; then
  GHQ_ROOT="$(ghq root)"
else
  GHQ_ROOT="${GHQ_ROOT:-$(git config --get ghq.root 2> /dev/null || echo "${HOME}/src")}"
fi
GHQ_ROOT="${GHQ_ROOT/#\~/${HOME}}"

if ! command -v ghq > /dev/null 2>&1; then
  echo "ghq is not installed, so there is no list of repositories to walk." >&2
  echo "Run \`make init\` to apply the Brewfile." >&2
  exit 1
fi

pulled=0
other_branch=0
uncommitted=0
no_remote=0
notable=()

while IFS= read -r repository; do
  name="${repository#"${GHQ_ROOT}"/}"

  # `.git` can be a file rather than a directory -- a worktree or a submodule points at one
  # elsewhere -- so ask git instead of looking for a directory. This is also what catches a
  # worktree whose parent has moved away: the pointer still exists and no longer resolves.
  if ! git -C "${repository}" rev-parse --git-dir > /dev/null 2>&1; then
    notable+=("${name}: not a usable git repository")
    continue
  fi

  if ! git -C "${repository}" remote get-url origin > /dev/null 2>&1; then
    no_remote=$((no_remote + 1))
    continue
  fi

  if ! default_branch="$(git -C "${repository}" symbolic-ref --short refs/remotes/origin/HEAD 2> /dev/null)"; then
    notable+=("${name}: no default branch recorded (git -C ${repository} remote set-head origin -a)")
    continue
  fi

  if ! current_branch="$(git -C "${repository}" symbolic-ref --short HEAD 2> /dev/null)"; then
    notable+=("${name}: detached HEAD")
    continue
  fi

  if [ "origin/${current_branch}" != "${default_branch}" ]; then
    other_branch=$((other_branch + 1))
    continue
  fi

  if [ -n "$(git -C "${repository}" status --porcelain 2> /dev/null)" ]; then
    uncommitted=$((uncommitted + 1))
    continue
  fi

  if [ "${DRY_RUN}" = true ]; then
    pulled=$((pulled + 1))
    continue
  fi

  # --ff-only so that a diverged branch is reported instead of being merged behind your back.
  if pull_output="$(git -C "${repository}" pull --ff-only --quiet 2>&1)"; then
    pulled=$((pulled + 1))
  else
    notable+=("${name}: pull failed (${pull_output%%$'\n'*})")
  fi
done < <(ghq list -p)

skipped=$((other_branch + uncommitted + no_remote + ${#notable[@]}))
summary="$(printf '%d pulled, %d skipped (%d on another branch, %d with uncommitted work, %d without a remote)' \
  "${pulled}" "${skipped}" "${other_branch}" "${uncommitted}" "${no_remote}")"
if [ "${DRY_RUN}" = true ]; then
  summary="${summary} [dry run: nothing was pulled]"
fi

message="${summary}"
if [ "${#notable[@]}" -gt 0 ]; then
  message="${message}"$'\n'"$(printf '  %s\n' "${notable[@]}")"
fi

echo "${message}"

# The webhook URL lives in the keychain rather than in this repository or the environment.
# With FileVault on and no auto-login, the login keychain is only open once a person has
# unlocked the machine -- which is also the only time a LaunchAgent runs, so the job and its
# secret become available together.
SLACK_WEBHOOK_KEYCHAIN_SERVICE="${SLACK_WEBHOOK_KEYCHAIN_SERVICE:-mac-provisioning-slack-webhook}"

if ! webhook="$(security find-generic-password -s "${SLACK_WEBHOOK_KEYCHAIN_SERVICE}" -w 2> /dev/null)"; then
  echo "No Slack webhook in the keychain (${SLACK_WEBHOOK_KEYCHAIN_SERVICE}), so the summary above was not sent." >&2
  echo "Add it with: security add-generic-password -s ${SLACK_WEBHOOK_KEYCHAIN_SERVICE} -a \"\${USER}\" -w" >&2
  exit 0
fi

if [ "${DRY_RUN}" = true ]; then
  echo "Dry run, so nothing was sent to Slack." >&2
  exit 0
fi

# jq builds the payload so that a repository name with a quote in it cannot break the JSON.
payload="$(jq -n --arg text "${message}" '{text: $text}')"
if ! curl -fsS -X POST -H 'Content-Type: application/json' -d "${payload}" "${webhook}" > /dev/null; then
  echo "Posting the summary to Slack failed." >&2
  exit 1
fi
