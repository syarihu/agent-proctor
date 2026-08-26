#!/bin/bash
# Agent Proctor.app を組み立てて /Applications に置き、CLI へのリンクを張る。
#
# 組み立ては build-app.sh、署名は sign-app.sh が持つ。ここはその2つを呼んで
# 置き場とリンクの面倒を見るだけ。分けてあるのは Homebrew の formula が
# 同じ物を別々の段階で呼ぶ必要があるため (理由は build-app.sh の頭に書いた)。
#
# SwiftPM は .app を作らないので、実行ファイルを2つ焼いてから包んでいる。
# CLI をバンドルの中に同梱するのは、配る物を1つにするため。
# ~/bin/proctor はその中身を指すシンボリックリンクになる。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEST="${PROCTOR_INSTALL_DIR:-/Applications}"
CLI_LINK="${PROCTOR_CLI_LINK:-$HOME/bin/proctor}"

# build-app.sh は進み具合を stderr、組み上がった .app のパスを stdout に出す
APP="$("$ROOT/scripts/build-app.sh" "$DEST")"
"$ROOT/scripts/sign-app.sh" "$APP"

echo "==> CLI のリンク: $CLI_LINK"
mkdir -p "$(dirname "$CLI_LINK")"
ln -sfn "$APP/Contents/Helpers/proctor" "$CLI_LINK"

APP_NAME="$(basename "$APP" .app)"
echo
echo "完了しました。"
echo "  アプリ : $APP"
echo "  CLI    : $CLI_LINK -> $(readlink "$CLI_LINK")"
echo
# 動いているプロセスは古いバンドルのまま動き続ける (中身を入れ替えても切り替わらない)。
# 入れ直したのに変わらない、で悩まないよう、その場で言う
if pgrep -f "$APP/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    echo "起動中のアプリは入れ替わっていません。終了して開き直してください:"
    echo "  osascript -e 'tell application \"$APP_NAME\" to quit' && open -a \"$APP_NAME\""
    echo
fi
echo "起動するには: open -a \"$APP_NAME\""
echo "初回はメニューバーから「設定…」を開いて「ログイン時に起動」を入れておくと、次からは自動で立ち上がります。"
