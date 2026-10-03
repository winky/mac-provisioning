#!/bin/bash
# discover.sh: DDCの入力値を実機で確認するためのヘルパー
#   discover.sh list
#       認識中のディスプレイとUUIDを表示
#   discover.sh probe <UUID> <input|input-alt> <away値> <home値> [待機秒]
#       指定ディスプレイを away値 に切り替え、待機後に home値 へ戻す。
#       「切り替わるか」と「切り替えた後にMac miniから戻せるか」を同時に確認できる。
#       ※ もう一方のモニターをMac miniに表示したまま実行すること

set -u
M1DDC="${M1DDC:-$(command -v m1ddc 2>/dev/null || echo /opt/homebrew/bin/m1ddc)}"

case "${1:-}" in
  list)
    "$M1DDC" display list
    ;;
  probe)
    [ $# -ge 5 ] || { echo "usage: $0 probe <UUID> <input|input-alt> <away> <home> [wait]" >&2; exit 2; }
    id=$2; cmd=$3; away=$4; home=$5; wait=${6:-8}

    echo "[1/3] $cmd=$away に切り替えます..."
    "$M1DDC" display "$id" set "$cmd" "$away" || echo "  → コマンドがエラーを返しました"

    echo "[2/3] ${wait}秒待機（画面が切り替わったか確認してください）"
    sleep "$wait"

    if "$M1DDC" display list | grep -q "$id"; then
      echo "  → 切り替え後もmacOSはこのディスプレイを認識しています（戻せる見込みあり）"
    else
      echo "  → 切り替え後にディスプレイが一覧から消えました（DDCで戻せない可能性大）"
    fi

    echo "[3/3] $cmd=$home に戻します..."
    if "$M1DDC" display "$id" set "$cmd" "$home"; then
      echo "  → 戻すコマンド送信OK。画面がMac miniに戻ったか確認してください"
    else
      echo "  → 戻せませんでした。モニターのボタンで手動で戻してください"
    fi
    ;;
  *)
    sed -n '2,9p' "$0"
    exit 2
    ;;
esac
