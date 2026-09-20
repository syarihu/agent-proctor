# Copilot CLI (`copilot`) と proctor を繋ぐ

agent-proctor は受け身の道具で、台帳 (`~/.local/state/proctor/state.json`) を
読んで見せるだけ。その台帳へ状態を書き込むのはエージェント側の hooks です。
**繋がないかぎり一覧は空のまま**です。

繋ぎ方は環境によって違います。既に hooks や statusLine を使っているなら、
置き換えではなく併存させる必要があり、手順書やスクリプトでは既存の設定を
覆いきれません。なので、これは**AI に読ませて実行させる指示**として書いてあります
——対象のエージェントに渡すか、エージェント自身に `proctor setup <相手>` を
実行させて読ませてください。

Copilot CLI はライフサイクルフックと statusLine の両方を持っているので、
proctor が出すもののほとんどは届く。始める前に知っておくべきことが3つあり、
そのうち2つは「届かないもの」の話である。

以下は Copilot CLI 1.0.83 を読んで確かめたもの。

- **同じイベントに綴りが2通りあり、使えるのは片方だけ。** イベント名を camelCase
  （`sessionStart`）で書くと Copilot 自身の payload が来る。PascalCase
  （`SessionStart`）で書くと VS Code 互換の payload、つまり Claude Code と同じ形
  （`session_id`・`cwd`・`hook_event_name`・`tool_name`・`agent_id`）が来る。
  proctor が読むのは後者なので、PascalCase の綴りがあるイベントは下の表でも
  PascalCase で書いてある。
- **セッションが返事待ちであることを報せる口が無い。** `PermissionRequest` は
  権限の判定が走る前に、自動承認されて画面に出ないものも含めてツールの判定ごとに
  毎回飛ぶので、聞かれているかどうかを何も語らない。`notification` のほうも、
  運べる種別のどれ一つとして「いまあなたが聞かれている」を意味しない。1.0.83 時点では
  `agent_completed`・`agent_idle`・`shell_completed`・`shell_detached_completed`・
  `new_inbox_message`・`instruction_discovered`・`factory_completed`・
  `unclassified` の8つしかない。だから下ではどちらも繋いでおらず、
  Copilot の行に「確認待ち」は出ない。
- **レートリミットは読めない。** Copilot は AI クレジット制で、hooks にも
  statusLine にも枠をどれだけ使ったかが乗ってこない。Copilot の行では
  その列が空のままになる。設定することは何も無い。

### 使い方 (Copilot CLI 向け)

Copilot CLI で以下をそのまま貼る。

---

```
agent-proctor (https://github.com/syarihu/agent-proctor) と連携するように、
私の Copilot CLI の設定を整えてください。

## 前提の確認

まず `~/bin/proctor` または PATH 上の `proctor` が実行できることを確認してください。
無ければ proctor をインストールしていないので、そこで止めて教えてください。

## やってほしいこと

hooks は `~/.copilot/hooks/proctor.json` に、statusLine は
`~/.copilot/settings.json` に書いてください。**既存の設定は消さないこと。**
同じイベントに別のフックが登録されているなら、配列に足して両方残してください。
`~/.copilot/config.json` には触らないでください。あのファイルは自身のヘッダに
「自動管理」と書いてあり、ユーザーの設定は `settings.json` の担当です。

| イベント | コマンド | 意味 |
| --- | --- | --- |
| `SessionStart` | `proctor _touch idle` | ここでセッションが開いた（`--resume` でも飛ぶ） |
| `UserPromptSubmit` | `proctor _touch running` | 動き出した |
| `PostToolUse` | `proctor _touch running` | ツールが成功した、実行中に戻す |
| `PostToolUseFailure` | `proctor _touch running` | ツールが失敗した、実行中に戻す |
| `Stop` | `proctor _touch done` | ターンが終わった |
| `SessionEnd` | `proctor _touch clear` | セッションが終わった |
| `subagentStart` | `proctor _subagent start` | サブエージェントが増えた |
| `SubagentStop` | `proctor _subagent stop` | サブエージェントが減った |

camelCase で書いてあるのは `subagentStart` だけです。書き間違いではなく、
Copilot にはこれの PascalCase の綴りが無いので、これが唯一の届かせ方です。

コマンドは proctor が実際に置かれている絶対パスで書いてください
（`command -v proctor` で調べて、その値を使ってください。以下の例は
`$HOME/bin/proctor` を前提にしています）。`--agent=copilot` を付け、
**`UserPromptSubmit` を除いて**出力は捨てます（そこだけ別扱いな理由は下に書きます）。
フックの実行環境に proctor の置き場が PATH に入っているとは限らず、
`[ -x ... ]` のガードは、消えた実行ファイルを叩かないようにするためのものです:

    [ -x "$HOME/bin/proctor" ] && "$HOME/bin/proctor" _touch running --agent=copilot >/dev/null 2>&1

`UserPromptSubmit` だけは、同じ行からリダイレクトを外したものにします:

    [ -x "$HOME/bin/proctor" ] && "$HOME/bin/proctor" _touch running --agent=copilot

`~/.copilot/hooks/proctor.json` は1件だけ書くとこうなります（ここに出しているのは
リダイレクトを**付ける**側の `PostToolUse` です）:

    {
      "version": 1,
      "hooks": {
        "PostToolUse": [
          {
            "type": "command",
            "bash": "[ -x \"$HOME/bin/proctor\" ] && \"$HOME/bin/proctor\" _touch running --agent=copilot >/dev/null 2>&1",
            "timeoutSec": 10
          }
        ]
      }
    }

### それぞれの理由（外さないでください）

- **`--agent=copilot` を付ける理由**: Copilot の PascalCase の payload は
  Claude Code と全く同じ形（`session_id` も `cwd` も `tool_name` も同じ名前）なので、
  JSON だけではどちらか言い切れない。付けないと Copilot のセッションが全部
  Claude Code として一覧に出る。
- **イベント名を PascalCase で書く理由**: 同じイベントを camelCase で書くと
  Copilot 自身の payload が来て、セッションは `sessionId`、ツールは `toolName` に
  なる。proctor が読むのは VS Code 互換の名前なので、camelCase のフックは
  何も記録できない。PascalCase の綴りが無い `subagentStart` については、
  proctor 側が camelCase の鍵を読む。
- **出力を捨てる理由**: ここに挙げたイベントのいくつかは、フックが出力したものを
  指示として読む——`Stop` はターンの終了を拒める。proctor が出すのは記録した状態で、
  端末に向けたものであって Copilot に向けたものではない。
- **`UserPromptSubmit` だけ例外にする理由**: サイドバーでそのセッションにまだ名前が
  無いあいだ、proctor はこのイベントにだけ `hookSpecificOutput` を返して
  `proctor title "<名前>"` を実行するよう頼む。リダイレクトするとその依頼ごと捨てる
  ことになる。Copilot のフック層は `hookSpecificOutput` という鍵を知っているので、
  Claude Code と同じように届くはず——そこまでは見届けていないが、無視される側に
  転んでも残しておく損は無く、リダイレクトすれば確実に失う。
- **`PermissionRequest` も `notification` も表に入れていない理由**: どちらも
  「セッションが自分の返事で止まっている」ことを伝えられない。`PermissionRequest` は
  自動承認されて画面に出ないものも含めて、ツールの判定ごとに毎回飛ぶ。
  `notification` の種別はどれも「待たれているのはあなただ」を意味しないので、繋ぐと
  背後のシェルが返ってきただけでセッションが確認待ちに落ちるうえ、本当に聞かれた
  ときには一度も飛ばない。どちらも外したところで、動いていたものは何も減らない。
- **`PostToolUse` を入れる理由**: 長いターンの間、プロンプトから `Stop` までを
  生きているように見せているのがこれで、いま動かしているツールを行に出すのもこれ。
  頻繁に飛ぶが、proctor は何も変わらない書き込みを捨てるのでただ同然。
- **`PostToolUseFailure` を入れる理由**: `PostToolUse` はツールが**成功した**ときしか
  飛ばない。これが無いと、最後のツール呼び出しが失敗したターンの行が、
  ターンが終わるまで直前のイベントが置いていった状態のまま残る。
- **`SessionEnd`・`subagentStart`・`SubagentStop` を同期で呼ぶ理由**:
  バックグラウンドに投げると、書き終わる前に本体と一緒に殺されることがある
  （`SubagentStop` を取りこぼすと、そのサブエージェントが一覧に居座る）。
  他のイベントは末尾に `&` を付けても構わないが、この3つは同期のままにする。

### statusLine

セッション名とコンテキスト使用率はフックには来ない。来るのは statusLine だけです。
proctor はこれらも出したいので、そちらから渡してください。Copilot が statusLine の
コマンドに渡す JSON は Claude Code と同じ鍵（`session_id`・`session_name`・
`model.display_name`・`context_window`）なので、`proctor _stats` がそのまま読めます。

- **statusLine をまだ使っていない場合**: `~/.copilot/settings.json` に以下を足して
  ください。そのファイルに既にあるものは残したままにします。

      {
        "statusLine": {
          "type": "command",
          "command": "[ -x \"$HOME/bin/proctor\" ] && \"$HOME/bin/proctor\" _stats --agent=copilot"
        }
      }

- **既に statusLine を使っている場合**: 既存の表示を壊さないでください。標準入力は
  一度しか読めないので、既存のスクリプトの中で JSON を最後まで読み切り、
  同じ内容を `proctor _stats --agent=copilot` にも渡してください。**ここでも
  フラグは上の例と同じくらい大事です**。statusLine の payload が渡してくるのは
  transcript のファイルではなく session-state のディレクトリなので、どのエージェント
  なのか分からないままの `_stats` は、描画のたびに自分の推測を行へ書き戻します。
  失敗は握り潰して、表示が止まらないようにします。描画のたびに呼ばれますが、proctor は何も変わっていなければ
  書かないので、台帳の更新時刻は動きません。
  ついでに `~/.copilot/settings.json` の `footer.showCustom` が `false` に
  なっていないか確認してください。`false` でもコマンドは動きますが何も描かれないので、
  今まで出ていた表示が止まっても気付けません。

`proctor _stats` はそれ自体では何も出力しません。これだけを呼ぶ statusLine は
空行を描きます。それで正しく、フッターではなく proctor に渡すためのものです。

## 確認

Copilot CLI を新しく起動して、`proctor ls` でセッションが一覧に出ることを
確認してください。出てこなければ設定が効いていません。

`proctor _touch` は記録した状態を標準出力に出します。git リポジトリの中で手で
確かめるなら（`running` と出れば正しい）:

    printf '{"session_id":"test-1","cwd":"'"$PWD"'","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"}}' | proctor _touch running --agent=copilot

そのうえで、Claude Code ではなく Copilot の行として入ったことを確かめます。鍵だけで
なく値まで見てください。`"agent"` だけを grep すると Claude Code の行でも通ってしまい、
何も確かめたことになりません:

    proctor ls --json | grep -E '"agent"[[:space:]]*:[[:space:]]*"copilot"'

これは台帳に行を残します。その行の ID は worktree のディレクトリ名から採られるもので、
**渡したセッション ID ではありません**。`proctor ls` に出た ID を読んで
`proctor rm <ID>` で消してください。

## 報告

どのファイルをどう変えたか教えてください。既存の設定と共存させた箇所があれば、
それも書いてください。
```

---

### Copilot CLI で見えないもの

- **レートリミットは届かない。** Copilot は AI クレジット制で、報告するのは
  セッションが積み上げたコストであって、5時間枠や週次枠をどれだけ使ったかではない。
  hooks にも statusLine にも消費率が乗ってこないので、Copilot の行ではその列が
  空のまま残る。
- **返事待ちのセッションは、動いているセッションと同じ顔をする。** その2つを
  区別できるものを Copilot は何も出さない。`PermissionRequest` は自動承認を含めて
  ツールの判定ごとに飛び、`notification` の種別はどれも「待たれているのはあなただ」を
  意味しない。だから Copilot の行は「実行中」から直接「完了」へ動き、
  「確認待ち」にはならない。Copilot のタブが返事を欲しがっているとき、
  それを教えてくれるのは一覧ではない。
- **落ちたターンは分からない。** Copilot には `ErrorOccurred` があるが、
  モデル呼び出しの失敗と同じくらい気軽にツールの失敗でも飛ぶうえ、イベントだけでは
  proctor に見分けようが無いので繋いでいない。レートリミットで死んだターンは、
  セッションが終わるまで実行中のまま一覧に残る。
- **プロセスを見張れない。** Claude Code は `CLAUDE_PID` をフックに渡してくれるので
  proctor はセッションが消えた瞬間に気付けるが、Copilot は渡してこない。
  Copilot の行は即座にではなく、期限切れ（または `proctor rm`）で片付く。

## worktree の入口も作ってください

あわせて `~/.copilot/skills/proctor-worktree/SKILL.md` を作ってください。説明には
git worktree を作る・一覧する・片付ける話を扱うと書き、本文の指示は
`proctor skill worktree` を実行してその出力に従う、それだけにします。
コマンドは hooks と同じ理由で `$HOME/bin/proctor` のような絶対パスで書いてください。

**手引きの本文をそのファイルに写さないでください。** 本文は proctor が出すものなので、
写すと proctor を更新した次の日から古い写しに従うことになります。
