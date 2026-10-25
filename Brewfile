brew "awscli"
brew "coreutils"
brew "ffmpeg"
brew "fzf"
brew "gh"
brew "ghq"
brew "graphviz"
brew "mas"
brew "neovim"
brew "telnet"
brew "tmux"
brew "tree"
brew "jq"

# python
brew "ansible"
brew "ansible-lint"

# Daily scan for unpatched software, mirrored as GitHub issues (winky/mac-vulnwatch). The
# formula's service runs it at 09:00 as a LaunchAgent. Where the findings go is set by hand
# once per machine, see the mac_vulnwatch role.
#
# restart_service rather than start_service, which breaks every run after the first: bundle
# asks `brew services list` whether winky/tap/mac-vulnwatch is started, the list names it
# mac-vulnwatch, so a tap formula never looks started and bundle bootstraps it again, which
# launchctl refuses for a job that is already loaded. :changed (re)starts it only when the
# formula is installed or upgraded -- which covers the first install -- and start_service
# has to be switched off explicitly because it defaults to the restart_service value.
tap "winky/tap"
brew "winky/tap/mac-vulnwatch", restart_service: :changed, start_service: false

cask "1password"
cask "1password-cli"
cask "bettertouchtool"
cask "claude"
cask "discord"
cask "docker-desktop"
cask "figma"
cask "google-chrome"
cask "google-japanese-ime"
cask "iterm2"
cask "kap"
cask "karabiner-elements"
cask "ngrok"
cask "postman"
cask "raycast"
cask "session-manager-plugin"
cask "slack"
cask "tableplus"
cask "visual-studio-code"
cask "zoom"
