#!/bin/bash
# 振る舞いのスナップショットを取る。層で切り直す前後で見比べるためのもの。
#
# 固定した台帳と使い捨ての git リポジトリを相手にするので、
# 実際に使っている台帳には触らない。
#
#   scripts/baseline.sh before   # リファクタ前に取る
#   scripts/baseline.sh after    # リファクタ後に取る
#   diff -u /tmp/taskhub-baseline/{before,after}.txt
set -uo pipefail

LABEL="${1:-before}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR=/tmp/taskhub-baseline
OUT="$OUT_DIR/$LABEL.txt"
mkdir -p "$OUT_DIR"

swift build --package-path "$ROOT" >/dev/null 2>&1 || {
    echo "ビルドに失敗しました" >&2; exit 1
}
BIN="$(swift build --package-path "$ROOT" --show-bin-path)/taskhub"

LAB="$(mktemp -d)"
export TASKHUB_STATE_DIR="$LAB/state"

# 時刻に依存する項目 (経過秒・AGE) は毎回変わるので伏せる。
# 見たいのは構造と文言であって、何秒経ったかではない
scrub() {
    sed -E \
        -e "s#$LAB#<LAB>#g" \
        -e 's/"(ageSeconds|idleSeconds|createdAt|updatedAt)" : [0-9]+/"\1" : <N>/g' \
        -e 's/[0-9]+[smhd]$/<AGE>/' \
        -e 's/経過: [0-9]+[smhd]/経過: <AGE>/g'
}

say() { echo; echo "### $*"; }

{
    say "help"
    "$BIN" --help

    say "ls (台帳なし)"
    "$BIN" ls --all
    "$BIN" ls --all --json

    # --- 使い捨てリポジトリを用意する
    git init -q --bare "$LAB/origin.git"
    git clone -q "$LAB/origin.git" "$LAB/work" 2>/dev/null
    cd "$LAB/work"
    git config user.email t@e.st; git config user.name test
    echo hello > README.md; echo secret > local.properties
    git add README.md; git commit -qm init; git push -q origin HEAD:main
    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    printf '{"branchPrefix":"syarihu/","copyFiles":["local.properties"]}\n' > .taskhub.json
    git add .taskhub.json; git commit -qm cfg; git push -q origin HEAD:main

    say "new (チケットキー)"
    "$BIN" new ABC-123 --no-fetch
    say "new (同じものをもう一度 = エラー)"
    "$BIN" new ABC-123 --no-fetch; echo "exit=$?"
    say "new --json でのエラー"
    "$BIN" new ABC-123 --no-fetch --json; echo "exit=$?"
    say "new (スラッシュ入りはprefixを足さない)"
    "$BIN" new feature/x --no-fetch

    say "copyFiles が持ち込まれたか"
    ls .claude/worktrees/syarihu-ABC-123/local.properties
    say ".git/info/exclude"
    tail -2 .git/info/exclude
    say "親リポジトリの git status"
    git status --porcelain

    say "ls (表)"
    "$BIN" ls --all
    say "ls --json"
    "$BIN" ls --all --json

    say "open"
    "$BIN" open abc-123
    say "open (曖昧なID)"
    "$BIN" open feature; echo "exit=$?"
    say "open (無いID)"
    "$BIN" open nope; echo "exit=$?"

    say "_touch running (1回目)"
    printf '{"session_id":"s1","cwd":"%s"}' "$LAB/work" | "$BIN" _touch running
    M1=$(stat -f %Fm "$TASKHUB_STATE_DIR/state.json")
    say "_touch running (2回目: 無変更なので台帳の更新時刻が動かない)"
    printf '{"session_id":"s1","cwd":"%s"}' "$LAB/work" | "$BIN" _touch running
    M2=$(stat -f %Fm "$TASKHUB_STATE_DIR/state.json")
    [ "$M1" = "$M2" ] && echo "mtime: 動かない" || echo "mtime: 動いた"

    say "_touch notification (アイドル通知: 何も出ない)"
    printf '{"session_id":"s1","cwd":"%s","message":"Claude is waiting for your input"}' "$LAB/work" | "$BIN" _touch notification
    say "_touch notification (権限確認)"
    printf '{"session_id":"s1","cwd":"%s","message":"needs your permission"}' "$LAB/work" | "$BIN" _touch notification
    say "_touch (不正な状態)"
    printf '{}' | "$BIN" _touch bogus; echo "exit=$?"

    say "_subagent start x2 → done で 0 に戻る"
    printf '{"session_id":"s1","cwd":"%s"}' "$LAB/work" | "$BIN" _subagent start
    printf '{"session_id":"s1","cwd":"%s"}' "$LAB/work" | "$BIN" _subagent start
    "$BIN" ls --all --json | grep -E '"(id|subagents)"'
    printf '{"session_id":"s1","cwd":"%s"}' "$LAB/work" | "$BIN" _touch done
    "$BIN" ls --all --json | grep -E '"(id|subagents)"'

    say "_stats"
    printf '{"session_id":"s1","model":{"display_name":"Opus 5"},"context_window":{"used_percentage":42.6},"session_name":"テスト"}' | "$BIN" _stats
    "$BIN" ls --all --json | grep -E '"(name|model|contextPercent)"'

    say "_touch clear (セッションは一覧から消える)"
    printf '{"session_id":"s1","cwd":"%s"}' "$LAB/work" | "$BIN" _touch clear
    "$BIN" ls --all --json | grep '"id"'

    say "rm (未コミット変更があるので止まる)"
    echo change >> .claude/worktrees/syarihu-ABC-123/README.md
    "$BIN" rm abc-123; echo "exit=$?"
    say "rm -f"
    "$BIN" rm -f abc-123; echo "exit=$?"

    say "clean (gh が答えられない)"
    "$BIN" clean; echo "exit=$?"

    say "ls (最後)"
    "$BIN" ls --all
} 2>&1 | scrub > "$OUT"

echo "書き出しました: $OUT ($(wc -l < "$OUT") 行)"
