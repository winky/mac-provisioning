#!/bin/bash
# build-apps.sh: Stream Deckの「開く」アクションから呼べる .app を生成する
# ターミナルを開かずにバックグラウンドで display-mode を実行できる
#   出力先: ~/Applications/Display Modes/

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/display-mode"
APP_DIR="${APP_DIR:-$HOME/Applications/Display Modes}"

chmod +x "$SCRIPT" "$SCRIPT_DIR/discover.sh"
mkdir -p "$APP_DIR"

build() {
  local mode=$1 name=$2
  local app="$APP_DIR/$name.app"
  rm -rf "$app"
  osacompile -o "$app" \
    -e "do shell script quoted form of \"$SCRIPT\" & \" $mode\""
  # Dockに表示させない
  /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$app/Contents/Info.plist" 2>/dev/null || true
  echo "built: $app"
}

build mini    "Display - Mac mini"
build dock    "Display - Dock"
build split   "Display - Split (Mac mini main)"
build split-r "Display - Split (MBP main)"
