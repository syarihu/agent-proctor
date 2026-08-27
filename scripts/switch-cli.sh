#!/bin/bash
# proctor の入口を、手元でビルドした版と Homebrew 版とで切り替える。
#
# 入口が2つあって、しかも別々に解決されるのが厄介なところ。
#
#   ~/bin/proctor      hooks が呼ぶところ。~/.claude/hooks の中に直書きされていて、
#                      PATH を通らない (フックの実行環境に ~/bin が乗らないため)
#   PATH 上の proctor  人が手で打つところ
#
# 片方だけ張り替えると、hook は手元の版・手打ちは Homebrew 版という食い違いが起きて、
# 今どちらの挙動を見ているのか分からなくなる。だからこの2つは必ず一緒に動かす。
#
# 台帳 (~/.local/state/proctor) は分けない。分けると hook が書き込む先と
# 見に行く先がずれて、動いているセッションが一覧に出なくなる。
# 台帳ごと隔離したいときは PROCTOR_STATE_DIR を自分で渡すこと。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# hooks が直に見るパス。ここは動かせない (スクリプト側に書かれている)
HOOK_LINK="$HOME/bin/proctor"
# PATH の先頭にあるユーザーの bin。Homebrew より前に来るので、
# ここに置くと手打ちの proctor が手元の版になる
PATH_LINK="$HOME/.local/bin/proctor"
# Homebrew が張る symlink。Cellar のバージョン付きパスではなくこちらを指すのは、
# brew upgrade でバージョンが変わってもリンクを張り直さずに済むため
BREW_CLI="$(brew --prefix 2>/dev/null || echo /opt/homebrew)/bin/proctor"

DEV_APP="${PROCTOR_INSTALL_DIR:-/Applications}/Agent Proctor.app"
DEV_CLI="$DEV_APP/Contents/Helpers/proctor"

usage() {
    cat <<EOS
使い方: scripts/switch-cli.sh <dev|brew|status>

  dev     手元のソースをビルドして入れ直し、2つの入口を手元の版へ向ける
  brew    2つの入口を Homebrew 版へ戻す (手元の .app はそのまま残る)
  status  今どちらを向いているかを見る
EOS
}

# symlink の finalな行き先。実体が無ければ空を返す
resolve() {
    [ -e "$1" ] || return 0
    readlink -f "$1" 2>/dev/null || true
}

# 行き先が手元の .app の中なら dev、Homebrew の Cellar の中なら brew
whose() {
    case "$1" in
        "") echo "(無し)" ;;
        "$DEV_APP"/*) echo "dev" ;;
        */Cellar/agent-proctor/*) echo "brew" ;;
        *) echo "他 ($1)" ;;
    esac
}

status() {
    local hook path_ which_
    hook="$(resolve "$HOOK_LINK")"
    path_="$(resolve "$PATH_LINK")"
    which_="$(resolve "$(command -v proctor 2>/dev/null || true)")"

    # printf の桁揃えは使わない。日本語の全角を1桁と数えるので、かえって崩れる
    echo "hooks が呼ぶ版: $(whose "$hook")"
    echo "  $HOOK_LINK -> ${hook:-(リンクが無い)}"
    echo "手打ちの版: $(whose "$which_")"
    echo "  PATH 上の proctor -> ${which_:-(見つからない)}"
    echo

    # 食い違っていると、直したつもりの挙動が出ずに悩むことになる。名指しで言う
    if [ -n "$hook" ] && [ -n "$which_" ] && [ "$hook" != "$which_" ]; then
        echo "⚠ hooks と手打ちで別の版を見ている。switch-cli.sh dev か brew で揃えること"
    elif [ -z "$hook" ]; then
        echo "⚠ $HOOK_LINK が無い。hooks は黙って何もしないので、一覧が空になる"
    fi
}

use_dev() {
    # install.sh が ~/bin/proctor まで面倒を見る (PROCTOR_CLI_LINK の既定がそこ)
    "$ROOT/scripts/install.sh"

    echo "==> 手打ち用のリンク: $PATH_LINK"
    mkdir -p "$(dirname "$PATH_LINK")"
    ln -sfn "$DEV_CLI" "$PATH_LINK"
    echo
    status
}

use_brew() {
    if [ ! -e "$BREW_CLI" ]; then
        echo "Homebrew 版が入っていない: $BREW_CLI" >&2
        echo "brew install syarihu/tap/agent-proctor を先に。" >&2
        exit 1
    fi

    echo "==> hooks の入口を Homebrew 版へ: $HOOK_LINK"
    mkdir -p "$(dirname "$HOOK_LINK")"
    ln -sfn "$BREW_CLI" "$HOOK_LINK"

    # Homebrew の bin は元から PATH にあるので、ここに残すと二重になる。
    # ただし手元の .app を指すリンクだけ消す。人が別の理由で置いた物には触らない
    if [ -L "$PATH_LINK" ] && [ "$(resolve "$PATH_LINK")" = "$(resolve "$DEV_CLI")" ]; then
        echo "==> 手打ち用のリンクを外す: $PATH_LINK"
        rm "$PATH_LINK"
    fi
    echo

    # 中身を入れ替えても、動いているプロセスは古いバンドルのまま動き続ける
    if pgrep -f "Agent Proctor.app/Contents/MacOS/Agent Proctor" >/dev/null 2>&1; then
        echo "起動中のアプリは切り替わっていない。開き直すこと:"
        echo "  osascript -e 'tell application \"Agent Proctor\" to quit' && proctor sidebar"
        echo
    fi
    status
}

case "${1:-status}" in
    dev) use_dev ;;
    brew) use_brew ;;
    status) status ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 1 ;;
esac
