#!/bin/bash
# 振る舞いのスナップショットを取る。作り替える前後で見比べるためのもの。
#
# 使い捨ての台帳と git リポジトリを相手にするので、
# 実際に使っている台帳には触らない。
#
#   scripts/baseline.sh before
#   scripts/baseline.sh after
#   diff -u /tmp/proctor-baseline/{before,after}.txt
set -uo pipefail

LABEL="${1:-before}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR=/tmp/proctor-baseline
OUT="$OUT_DIR/$LABEL.txt"
mkdir -p "$OUT_DIR"

swift build --package-path "$ROOT" >/dev/null 2>&1 || {
    echo "ビルドに失敗しました" >&2; exit 1
}
BIN="$(swift build --package-path "$ROOT" --show-bin-path)/proctor"

LAB="$(mktemp -d)"
export PROCTOR_STATE_DIR="$LAB/state"

# 時刻に依存する項目は毎回変わるので伏せる。
# 見たいのは構造と文言であって、何秒経ったかではない
scrub() {
    sed -E \
        -e "s#$LAB#<LAB>#g" \
        -e 's/"(ageSeconds|idleSeconds|createdAt|updatedAt|pid|pidStartedAt)" : [0-9]+/"\1" : <N>/g' \
        -e 's/[0-9]+[smhd]$/<AGE>/'
}

say() { echo; echo "### $*"; }

# hooks が送ってくる payload を組み立てる
payload() {
    printf '{"session_id":"%s","cwd":"%s"%s}' "$1" "$2" "${3:-}"
}

{
    say "help"
    "$BIN" --help

    say "ls (台帳なし)"
    "$BIN" ls --all
    "$BIN" ls --all --json

    # --- セッションが動く場所として使い捨てのリポジトリを用意する
    git init -q "$LAB/work"
    cd "$LAB/work"
    git config user.email t@e.st; git config user.name test
    echo hello > README.md
    git add README.md; git commit -qm init
    git checkout -qb feature

    say "_touch running (セッションが登録される)"
    payload s1 "$LAB/work" | "$BIN" _touch running
    "$BIN" ls --all --json

    say "_touch running をもう一度 (無変更なので台帳の更新時刻が動かない)"
    M1=$(stat -f %Fm "$PROCTOR_STATE_DIR/state.json")
    payload s1 "$LAB/work" | "$BIN" _touch running
    M2=$(stat -f %Fm "$PROCTOR_STATE_DIR/state.json")
    [ "$M1" = "$M2" ] && echo "mtime: 動かない" || echo "mtime: 動いた"

    say "ls (表)"
    "$BIN" ls --all

    say "未コミットの変更と新規ファイルが差分に出るか"
    echo change >> README.md
    echo new > untracked.txt
    "$BIN" ls --all
    "$BIN" ls --all --json | grep -E '"(added|removed|untracked)"'

    say "_touch notification (アイドル通知: 何も出さない)"
    payload s1 "$LAB/work" ',"message":"Claude is waiting for your input"' | "$BIN" _touch notification
    "$BIN" ls --all --json | grep '"status"'

    say "_touch notification (権限確認: waiting を返す)"
    payload s1 "$LAB/work" ',"message":"needs your permission"' | "$BIN" _touch notification
    "$BIN" ls --all --json | grep '"status"'

    say "_touch (不正な状態)"
    printf '{}' | "$BIN" _touch bogus; echo "exit=$?"

    say "_subagent start x2 → done で 0 に戻る"
    payload s1 "$LAB/work" | "$BIN" _subagent start
    payload s1 "$LAB/work" | "$BIN" _subagent start
    "$BIN" ls --all --json | grep '"subagents"'
    payload s1 "$LAB/work" | "$BIN" _touch done
    "$BIN" ls --all --json | grep '"subagents"'

    say "_stats (statusline からの横流し)"
    printf '{"session_id":"s1","model":{"display_name":"Opus 5"},"context_window":{"used_percentage":42.6},"session_name":"テスト"}' | "$BIN" _stats
    "$BIN" ls --all --json | grep -E '"(name|model|contextPercent)"'

    say "_stats を同じ内容でもう一度 (mtime が動かない)"
    M1=$(stat -f %Fm "$PROCTOR_STATE_DIR/state.json")
    printf '{"session_id":"s1","model":{"display_name":"Opus 5"},"context_window":{"used_percentage":42.6},"session_name":"テスト"}' | "$BIN" _stats
    M2=$(stat -f %Fm "$PROCTOR_STATE_DIR/state.json")
    [ "$M1" = "$M2" ] && echo "mtime: 動かない" || echo "mtime: 動いた"

    say "2つ目のセッションが同じ場所で開いても取り違えない"
    payload s2 "$LAB/work" | "$BIN" _touch running
    "$BIN" ls --all --json | grep -E '"(id|sessionId)"'

    say "git の外では登録しない"
    payload s3 "$LAB" | "$BIN" _touch running
    "$BIN" ls --all --json | grep '"id"'

    say "プロセスが生きているうちは残る / 死んだら次のフックで片付く"
    # CLAUDE_PID は Claude Code が子プロセスへ渡すもの。ここでは使い捨ての
    # プロセスで代用して、それが死んだときに記録が落ちることを見る。
    # 端末のセッションID (ITERM_SESSION_ID) は渡していない。iTerm2 以外で
    # 動かしているセッションでも片付くことを、ここで確かめている
    sleep 30 & FAKE=$!
    payload s4 "$LAB/work" | CLAUDE_PID=$FAKE "$BIN" _touch running
    echo "登録直後 (生きている):"; "$BIN" ls --all --json | grep -E '"(id|sessionId)"'
    kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null
    # 掃除は台帳を触るときに走るので、既にいるセッションのフックで起こす
    # (新しく登録すると、空いた ID を拾って消えたことが見えなくなる)
    payload s1 "$LAB/work" | "$BIN" _touch running
    echo "プロセスを殺したあと (s4 が消えている):"; "$BIN" ls --all --json | grep -E '"(id|sessionId)"'

    say "開き直した当人からのフックなら、前のプロセスが死んでいても残る (--resume)"
    sleep 30 & FAKE=$!
    payload s6 "$LAB/work" | CLAUDE_PID=$FAKE "$BIN" _touch running
    echo "登録直後:"; "$BIN" ls --all --json | grep -E '"(id|sessionId)"' | head -2
    kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null
    # 同じセッションを別のプロセスで開き直す。ID も経過時間も引き継がれてほしい
    payload s6 "$LAB/work" | CLAUDE_PID=$$ "$BIN" _touch running
    echo "開き直したあと (work-3 のまま。新しい記録が増えない):"
    "$BIN" ls --all --json | grep -E '"(id|sessionId)"'

    say "rm (台帳から外す)"
    payload s5 "$LAB/work" | "$BIN" _touch running
    "$BIN" rm work-4
    "$BIN" rm nope; echo "exit=$?"
    "$BIN" ls --all --json | grep '"id"'

    say "_touch clear (セッションが一覧から消える)"
    payload s1 "$LAB/work" | "$BIN" _touch clear
    "$BIN" ls --all --json | grep '"id"'

    say "attach (無いID)"
    "$BIN" attach nope; echo "exit=$?"

    say "ls (最後)"
    "$BIN" ls --all
} 2>&1 | scrub > "$OUT"

echo "書き出しました: $OUT ($(wc -l < "$OUT") 行)"
