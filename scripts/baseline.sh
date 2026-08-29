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
        -e 's/"(ageSeconds|idleSeconds|createdAt|updatedAt|pid|pidStartedAt|startedAt|lastSeenAt|elapsedSeconds|lastCommitAt)" : [0-9]+/"\1" : <N>/g' \
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

    # resume したセッションは、最初のプロンプトを送るまで何も飛んでこない。
    # SessionStart (idle) が無いと、その間ずっと worktree が「誰もいない」に見える
    say "_touch idle (何もしていないセッションが登録される)"
    payload s0 "$LAB/work" | "$BIN" _touch idle
    "$BIN" ls --all
    payload s0 "$LAB/work" | "$BIN" _touch clear

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

    # SessionStart は圧縮 (compact) や /clear でも飛ぶ。
    # 素直に受けると、働いている最中のセッションが待機中に落ちる
    say "動いているセッションは idle で塗り替えられない"
    payload s1 "$LAB/work" | "$BIN" _touch idle
    "$BIN" ls --all --json | grep '"status"'

    say "_touch notification (アイドル通知: 確認待ちでなければ記録した状態を返す)"
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

    # --- ここから agent_id を送ってくるエージェント (Claude Code) の経路
    payload s1 "$LAB/work" | "$BIN" _touch running

    say "親が触っているツールが載る"
    payload s1 "$LAB/work" ',"tool_name":"Edit","tool_input":{"file_path":"/x/TaskStore.swift"}' \
        | "$BIN" _touch running
    "$BIN" ls --all --json | grep '"activity"'

    say "SubagentStart で1体ぶら下がる"
    payload s1 "$LAB/work" ',"agent_id":"a1","agent_type":"Explore"' | "$BIN" _subagent start
    "$BIN" ls --all --json | grep -E '"(subagents|id|name|type)"'

    say "Agent ツールの PostToolUse で「何をさせているか」が付く"
    payload s1 "$LAB/work" ',"tool_name":"Agent","tool_input":{"description":"台帳の読み方を調べる","subagent_type":"Explore"},"tool_response":{"agentId":"a1","description":"台帳の読み方を調べる","resolvedModel":"haiku"}' \
        | "$BIN" _touch running
    "$BIN" ls --all --json | grep -E '"(label|activity)"'

    say "子が叩いたツールは子の行に出る (親の activity は Edit のまま)"
    payload s1 "$LAB/work" ',"agent_id":"a1","agent_type":"Explore","tool_name":"Grep","tool_input":{"description":"TaskStatus を探す"}' \
        | "$BIN" _touch running
    "$BIN" ls --all --json | grep -E '"(label|activity)"'

    say "2体目が増える"
    payload s1 "$LAB/work" ',"agent_id":"a2","agent_type":"general-purpose"' | "$BIN" _subagent start
    "$BIN" ls --all --json | grep '"subagents"'

    say "ls (表にサブエージェントがぶら下がる)"
    "$BIN" ls --all

    say "SubagentStop で1体減る"
    payload s1 "$LAB/work" ',"agent_id":"a1","agent_type":"Explore"' | "$BIN" _subagent stop
    "$BIN" ls --all --json | grep -E '"(subagents|name)"'

    say "SubagentStart / Stop では経過が 0 に戻らない"
    M1=$("$BIN" ls --all --json | grep '"updatedAt"' | head -1)
    payload s1 "$LAB/work" ',"agent_id":"a3","agent_type":"Explore"' | "$BIN" _subagent start
    M2=$("$BIN" ls --all --json | grep '"updatedAt"' | head -1)
    [ "$M1" = "$M2" ] && echo "updatedAt: 動かない" || echo "updatedAt: 動いた"

    # 子は非同期に起動されるので、親のターンは子を待たずに終わって Stop が飛ぶ。
    # そのまま完了にすると、まだ動いているのに緑の印が付いてしまう
    say "子が走っている間は done が来ても完了にしない"
    payload s1 "$LAB/work" | "$BIN" _touch done
    "$BIN" ls --all --json | grep -E '"(status|subagents)"'
    "$BIN" ls --all

    # 親の Stop と子の SubagentStop は非同期に飛ぶので、Stop が先に着くことがある。
    # 保留した終わりを覚えていないと、終わったセッションが実行中のまま居座る
    say "先に届いていた done は、最後の1体が帰った時点で確定する"
    payload s1 "$LAB/work" ',"agent_id":"a2","agent_type":"general-purpose"' | "$BIN" _subagent stop
    "$BIN" ls --all --json | grep '"status"'
    payload s1 "$LAB/work" ',"agent_id":"a3","agent_type":"Explore"' | "$BIN" _subagent stop
    "$BIN" ls --all --json | grep -E '"(status|subagents)"'

    say "子に起こされて動き出したら、預かった終わりは無かったことになる"
    payload s1 "$LAB/work" | "$BIN" _touch running
    payload s1 "$LAB/work" ',"agent_id":"a4","agent_type":"Explore"' | "$BIN" _subagent start
    payload s1 "$LAB/work" | "$BIN" _touch done      # 保留される
    payload s1 "$LAB/work" ',"prompt":"<task-notification>…"' | "$BIN" _touch running  # 起こされた
    payload s1 "$LAB/work" ',"agent_id":"a4","agent_type":"Explore"' | "$BIN" _subagent stop
    "$BIN" ls --all --json | grep '"status"'         # 実行中のまま (改めて Stop が来る)
    payload s1 "$LAB/work" | "$BIN" _touch done
    "$BIN" ls --all --json | grep -E '"(status|subagents)"'
    grep -q subagentRuns "$PROCTOR_STATE_DIR/state.json" \
        && echo "台帳: 子が残っている" || echo "台帳: 子はいない"
    payload s1 "$LAB/work" | "$BIN" _touch running

    # hooks は非同期に飛ぶので、子の最後のツールが SubagentStop より後に着きうる。
    # 受けてしまうと、終わりを告げる者がいない行が生まれてセッションが開いたままになる
    say "SubagentStop のあとに遅れて届いた子のイベントでは生き返らない"
    payload s1 "$LAB/work" ',"agent_id":"b1","agent_type":"Explore"' | "$BIN" _subagent start
    payload s1 "$LAB/work" ',"agent_id":"b1","tool_name":"Grep","tool_input":{"description":"探す"}' \
        | "$BIN" _touch running
    payload s1 "$LAB/work" ',"agent_id":"b1","agent_type":"Explore"' | "$BIN" _subagent stop
    payload s1 "$LAB/work" ',"agent_id":"b1","tool_name":"Read","tool_input":{"file_path":"/x/y.swift"}' \
        | "$BIN" _touch running
    "$BIN" ls --all --json | grep '"subagents"'
    grep -q subagentRuns "$PROCTOR_STATE_DIR/state.json" \
        && echo "台帳: 子が生き返った" || echo "台帳: 子はいない"
    payload s1 "$LAB/work" | "$BIN" _touch done
    "$BIN" ls --all --json | grep '"status"'

    say "保留中に確認待ちが挟まっても、預かった終わりは消えない"
    payload s1 "$LAB/work" | "$BIN" _touch running
    payload s1 "$LAB/work" ',"agent_id":"b2","agent_type":"Explore"' | "$BIN" _subagent start
    payload s1 "$LAB/work" | "$BIN" _touch done
    payload s1 "$LAB/work" ',"message":"needs your permission"' | "$BIN" _touch notification
    payload s1 "$LAB/work" ',"agent_id":"b2","agent_type":"Explore"' | "$BIN" _subagent stop
    "$BIN" ls --all --json | grep '"status"'

    # アプリの 🤖 は数だけを見て出しているので、行を出さない状態で数が残ると
    # 完了した行に 🤖 だけが脈打つ
    say "完了した行に子がぶら下がっても数は 0"
    payload s1 "$LAB/work" ',"agent_id":"b3","agent_type":"Explore"' | "$BIN" _subagent start
    "$BIN" ls --all --json | grep -E '"(status|subagents)"'
    "$BIN" ls --all
    payload s1 "$LAB/work" ',"agent_id":"b3","agent_type":"Explore"' | "$BIN" _subagent stop

    # 打ち切りは時間で効くので、台帳を直に仕込んで作る。
    # 起点を「生まれた時刻」にすると、長く走っている子が動いている最中に消え、
    # その拍子に親の預かった終わりが確定して完了の印が付く
    say "何時間走っていても、声が届いている子は打ち切られない"
    plant() {  # $1: startedAt の何秒前, $2: 最後に声を聞いたのが何秒前
        python3 - "$PROCTOR_STATE_DIR/state.json" "$1" "$2" <<'PY'
import json, sys, time
path, born, seen = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
now = int(time.time())
box = json.load(open(path))
for task in box["tasks"]:
    if task["id"] != "work":
        continue
    task["status"] = "running"
    task["pendingStatus"] = "done"
    task["subagentRuns"] = [{"id": "long", "type": "Explore",
                             "label": "重い調べもの",
                             "startedAt": now - born, "lastSeenAt": now - seen}]
json.dump(box, open(path, "w"), ensure_ascii=False)
PY
    }
    plant 25200 60          # 7時間前に生まれ、1分前まで喋っている
    payload s9 "$LAB/work" | "$BIN" _touch running   # 別セッションのイベントで箒がかかる
    "$BIN" ls --all --json | grep -E '"(status|label)"'

    say "声が途絶えた子は打ち切られ、預かった終わりが確定する"
    plant 25200 25200       # 7時間前から音沙汰なし
    payload s9 "$LAB/work" | "$BIN" _touch running
    "$BIN" ls --all --json | grep -E '"(status|subagents)"'
    # 箒をかけるためだけに開いたセッションなので片付ける。
    # 残すと以降の節で ID の採番がずれて、何を見ている節なのか分かりにくくなる
    payload s9 "$LAB/work" | "$BIN" _touch clear

    # 終わった行には2行目が無く、印と名前だけでは「何が終わったか」が分からない。
    # Stop が渡してくる last_assistant_message を、要確認の一覧に出す分だけ載せる
    # コードは開きと閉じで挟まれるので、フェンスの行だけ落としても中身が残る。
    # 短い返事だと、それだけで2行目がコードで埋まる。
    # 箇条書きは記号のものだけでなく番号付きも捨てるが、
    # 「1.5 倍」のような文は残す (あちらは . の次が空白ではない)
    say "終わったターンの締めが載る (骨組みは落ち、地の文だけ残る)"
    payload s1 "$LAB/work" ',"last_assistant_message":"## 結論\n\n**recap** は `hook` では取れないのだ。\n\n```swift\nlet policy = Policy(rawValue: raw)\nstore.apply(policy)\n```\n\n- 案1\n+ 案2\n\n1. まず調べる\n2) 次に直す\n\n1.5 倍になったのだ。"' \
        | "$BIN" _touch done
    "$BIN" ls --all --json | grep -E '"(status|summary)"'

    # 保留されていた終わりが確定するときの done は、文を持たずに飛んでくる。
    # そこで消すと、載せてくるエージェントでも締めが1回で消える
    say "文を持たない done では、載っている締めが消えない"
    payload s1 "$LAB/work" | "$BIN" _touch done
    "$BIN" ls --all --json | grep '"summary"'

    # 文は来たのに、骨組みだけで地の文が残らなかったとき。
    # 「載せる文が無い」と分かっているので、前のターンの締めは残さない
    say "骨組みだけの done では、載っている締めが消える"
    payload s1 "$LAB/work" ',"last_assistant_message":"## 結論\n\n- 案1\n- 案2"' \
        | "$BIN" _touch done
    "$BIN" ls --all --json | grep -E '"(status|summary)"'

    say "また動き出すと締めは消える (前のターンの話なので)"
    payload s1 "$LAB/work" | "$BIN" _touch running
    "$BIN" ls --all --json | grep -E '"(status|summary)"'

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

    # --- ここから worktree の一覧。セッションではなく場所を数える経路
    # 使い捨てリポジトリの外側に置く。中に作ると本体の未追跡ファイルとして
    # 差分に数えられ、何を見ている節なのか分からなくなる
    git -C "$LAB/work" worktree add -q -b merged-work "$LAB/worktrees/merged" main
    git -C "$LAB/work" worktree add -q -b spike "$LAB/worktrees/spike" main
    (cd "$LAB/worktrees/spike" \
        && echo spike > spike.txt && git add spike.txt && git commit -qm spike \
        && echo more >> spike.txt)

    say "worktree ls (セッションのある場所と、無い場所が並ぶ)"
    payload s7 "$LAB/worktrees/spike" | "$BIN" _touch running
    "$BIN" worktree ls --all
    "$BIN" worktree ls --all --json

    # ここが worktree の一覧を足した理由。セッションの一覧からは消えるのに
    # 場所は残るので、残ったものを見る道が要る
    say "セッションが終わっても worktree は残る (ls からは消える)"
    payload s7 "$LAB/worktrees/spike" | "$BIN" _touch clear
    "$BIN" ls --all
    "$BIN" worktree ls --all

    # 消してよいかの判断は、ここを踏み外すと**控えの無い仕事を捨てる**ことになる。
    # 鍵の掛かったものと実体を失ったものが候補から外れることを見ておく
    say "鍵を掛けた worktree と、実体を失った worktree"
    git -C "$LAB/work" worktree lock "$LAB/worktrees/merged"
    rm -rf "$LAB/worktrees/spike"
    "$BIN" worktree ls --all
    "$BIN" worktree ls --all --json | grep -E '"(name|isLocked|isPrunable|isRemovable)"'
    git -C "$LAB/work" worktree unlock "$LAB/worktrees/merged"

    say "worktree ls (知らないサブコマンド)"
    "$BIN" worktree nope; echo "exit=$?"

    # 権限確認をキャンセル (Esc) すると Claude Code はフックを1つも飛ばさない。
    # 唯一届くアイドル通知で降ろせることを見ておく (でないと確認待ちが居座る)
    say "確認待ちは、キャンセルされたあとアイドル通知で待機へ降りる"
    payload s9 "$LAB/work" ',"notification_type":"permission_prompt","tool_name":"Bash","tool_input":{"command":"rm -rf build"}' \
        | "$BIN" _touch notification
    "$BIN" ls --all --json | grep -E '"(status|request)"'
    payload s9 "$LAB/work" ',"notification_type":"idle_prompt"' | "$BIN" _touch notification
    "$BIN" ls --all --json | grep -E '"(status|request)"'

    # Notification は権限確認だけではない。認証できた・自動再開したも同じ口から来る。
    # 全部を確認待ちに寄せると、ログインしただけで印が付いて居座る
    say "状態と関係のない通知では何も起きない (認証できた)"
    payload s9 "$LAB/work" ',"notification_type":"permission_prompt"' | "$BIN" _touch notification
    payload s9 "$LAB/work" ',"notification_type":"auth_success"' | "$BIN" _touch notification
    echo "(上の行に何も出なければ「変えない」の意味)"
    "$BIN" ls --all --json | grep '"status"'

    # 親のプロンプトが開いている最中に、子が暇になっただけということがある
    say "子から届いたアイドル通知では親を降ろさない"
    payload s9 "$LAB/work" ',"notification_type":"idle_prompt","agent_id":"c9"' \
        | "$BIN" _touch notification
    "$BIN" ls --all --json | grep '"status"'
    payload s9 "$LAB/work" | "$BIN" _touch clear

    # --- ここから「セッションが自分で名前を付ける」経路
    #
    # **このスクリプトは Claude Code の中から走る。** つまり
    # CLAUDE_CODE_SESSION_ID も ITERM_SESSION_ID も環境に載っている。
    # title は環境変数から自分の行を引く仕組みなので、素で叩くと
    # 「走らせた場所」によって当たる行が変わる。以下では必ず env を明示し、
    # 「引けない」ことを見る節では 4つとも落とす
    NAKED="env -u PROCTOR_ID -u CLAUDE_CODE_SESSION_ID -u ITERM_SESSION_ID -u CLAUDE_PID"

    # 台帳の値を直に読む。**台帳のIDは採番されるので、こちらはセッションIDで引く**
    # (時刻の類は scrub が伏せるので、比べるならここで取って結果だけ印字する)。
    #
    # 行が無いときは `<no row>` と言わせる。黙って空を返すと「欄が空」と
    # 「行がそもそも登録されていない」が同じ出力になり、登録の経路が壊れても
    # 気づけない
    field() {
        python3 - "$PROCTOR_STATE_DIR/state.json" "$1" "$2" <<'PY'
import json, sys
path, session, key = sys.argv[1], sys.argv[2], sys.argv[3]
for task in json.load(open(path))["tasks"]:
    if task.get("sessionId") == session:
        print(task.get(key, ""))
        break
else:
    print("<no row>")
PY
    }

    # UserPromptSubmit の stdout はそのまま会話の文脈に注ぎ込まれる。
    # 名前が無いあいだはそこで名付けを頼み、状態の文字列 (running) は出さない
    say "UserPromptSubmit: 名前の無いセッションに囁く (登録された初回でも出る)"
    payload t1 "$LAB/work" ',"hook_event_name":"UserPromptSubmit","source":"user","prompt":"台帳を直したい"' \
        | "$BIN" _touch running

    say "title (CLAUDE_CODE_SESSION_ID から自分の行を引く)"
    $NAKED CLAUDE_CODE_SESSION_ID=t1 "$BIN" title "台帳の名付けを直す"
    "$BIN" ls --all --json | grep '"title"'

    say "名前が付いたら囁かないし、状態も出さない"
    OUT=$(payload t1 "$LAB/work" ',"hook_event_name":"UserPromptSubmit","source":"user","prompt":"続き"' \
        | "$BIN" _touch running)
    echo "出力: [$OUT]"

    # `--json` の約束は「状態の文字列を出さない」ことで、囁きはそれを破らない
    # (JSON を出しているので約束は守られている)。名前が付いていれば {} だけ
    say "--json: 名前が付いていれば {} だけ"
    OUT=$(payload t1 "$LAB/work" ',"hook_event_name":"UserPromptSubmit","source":"user","prompt":"続き"' \
        | "$BIN" _touch running --json)
    echo "出力: [$OUT]"

    say "同じ名前をもう一度付けても台帳を触らない / 改名しても経過が 0 に戻らない"
    M1=$(stat -f %Fm "$PROCTOR_STATE_DIR/state.json")
    $NAKED CLAUDE_CODE_SESSION_ID=t1 "$BIN" title "台帳の名付けを直す"
    M2=$(stat -f %Fm "$PROCTOR_STATE_DIR/state.json")
    [ "$M1" = "$M2" ] && echo "mtime: 動かない" || echo "mtime: 動いた"
    U1=$(field t1 updatedAt)
    $NAKED CLAUDE_CODE_SESSION_ID=t1 "$BIN" title "名付けの入口を作る"
    U2=$(field t1 updatedAt)
    [ "$U1" = "$U2" ] && echo "updatedAt: 動かない" || echo "updatedAt: 動いた"

    say "空文字で名前を外す"
    $NAKED CLAUDE_CODE_SESSION_ID=t1 "$BIN" title ""
    echo "title: [$(field t1 title)]"

    say "--json でも囁きを優先する (名前なし)"
    payload t1 "$LAB/work" ',"hook_event_name":"UserPromptSubmit","source":"user","prompt":"続き"' \
        | "$BIN" _touch running --json

    say "title (名前を渡していない)"
    $NAKED "$BIN" title; echo "exit=$?"

    # 子が帰ってきたときの task notification も、自動継続も、人が打ったのと
    # 同じ UserPromptSubmit として届く。source で分けないと、そのたびに囁く
    #
    # **この下2節は t1 に名前が無い状態でしか意味を持たない** (前の「空文字で
    # 名前を外す」がそれを作っている)。名前があると namingHint は source も
    # agent_id も見ずに nil を返すので、判定を丸ごと消しても素通りしてしまう。
    # 節を前へ動かさないこと
    say "source が user でなければ囁かない (system)"
    OUT=$(payload t1 "$LAB/work" ',"hook_event_name":"UserPromptSubmit","source":"system","prompt":"<task-notification>…"' \
        | "$BIN" _touch running)
    echo "出力: [$OUT]"

    say "子の手元で起きたことでは親に囁かない (agent_id 付き)"
    OUT=$(payload t1 "$LAB/work" ',"hook_event_name":"UserPromptSubmit","source":"user","agent_id":"t9","prompt":"子の依頼"' \
        | "$BIN" _touch running)
    echo "出力: [$OUT]"

    # agy / codex は CLAUDE_CODE_SESSION_ID を渡してこない。
    # あちらで自分の行を引ける鍵はタブの guid だけになる
    say "title (ITERM_SESSION_ID だけでも引ける)"
    payload t2 "$LAB/work" | env ITERM_SESSION_ID="w0t0p0:PROCTOR-BASELINE" "$BIN" _touch running
    $NAKED ITERM_SESSION_ID="w0t0p0:PROCTOR-BASELINE" "$BIN" title "タブから引いた名前"

    say "title (どの鍵も無ければ止まる)"
    $NAKED "$BIN" title "誰のものでもない名前"; echo "exit=$?"

    say "hook_event_name の無い payload では今までどおり状態が出る"
    payload t1 "$LAB/work" | "$BIN" _touch running

    # Notification の title は通知の見出しであってセッション名ではない。
    # 拾うと「Claude Code」や権限確認の文言が行の名前として居座る
    say "Notification の title はセッション名にしない"
    payload t3 "$LAB/work" ',"hook_event_name":"Notification","notification_type":"permission_prompt","title":"Claude Code"' \
        | "$BIN" _touch notification
    echo "name: [$(field t3 name)]"

    # **これが agy / codex の経路。** あちらは hook_event_name を送ってこないので、
    # title を飛ばす判定に一度も掛からない。あちらの title は本当にセッション名なので、
    # 一律に外してはいけない
    say "hook_event_name を送ってこない相手の title はセッション名になる"
    payload t4 "$LAB/work" ',"title":"agy が付けたセッション名"' | "$BIN" _touch running
    echo "name: [$(field t4 name)]"

    # 同じ鍵を Claude Code の別のイベントで見る。飛ばすのは Notification の
    # ときだけなので、他のイベントで届いた title は今までどおり拾う
    say "Claude Code でも Notification 以外の title は拾う"
    payload t3 "$LAB/work" ',"hook_event_name":"Stop","title":"人が付けたタブの名前"' | "$BIN" _touch done
    echo "name: [$(field t3 name)]"

    # 開いたセッションは節の中で畳む。残すと最後の ls に並んで、
    # どの節の話なのか分からなくなる
    payload t1 "$LAB/work" | "$BIN" _touch clear
    payload t2 "$LAB/work" | "$BIN" _touch clear
    payload t3 "$LAB/work" | "$BIN" _touch clear
    payload t4 "$LAB/work" | "$BIN" _touch clear

    say "skill ls"
    "$BIN" skill ls
    "$BIN" skill ls --json

    say "skill worktree (冒頭だけ)"
    "$BIN" skill worktree | head -6

    say "skill (無い名前)"
    "$BIN" skill nope; echo "exit=$?"

    say "setup ls"
    "$BIN" setup ls
    "$BIN" setup ls --json

    # setup all は本文を持たず、エージェントごとの手引きを繋いで出す。
    # 見出しの数で、繋ぐ相手が欠けていないことを見る (文面は変わっても崩れない)
    say "setup all (見出しの数)"
    echo "見出し: $("$BIN" setup all | grep -c '^# ')"
    "$BIN" setup claude | head -3

    say "setup (無い相手)"
    "$BIN" setup nope; echo "exit=$?"

    say "ls (最後)"
    "$BIN" ls --all
} 2>&1 | scrub > "$OUT"

echo "書き出しました: $OUT ($(wc -l < "$OUT") 行)"
