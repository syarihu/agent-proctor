# Claude Code と proctor を繋ぐ

agent-proctor は受け身の道具で、台帳 (`~/.local/state/proctor/state.json`) を
読んで見せるだけ。その台帳へ状態を書き込むのはエージェント側の hooks です。
**繋がないかぎり一覧は空のまま**です。

繋ぎ方は環境によって違います。既に hooks や statusLine を使っているなら、
置き換えではなく併存させる必要があり、手順書やスクリプトでは既存の設定を
覆いきれません。なので、これは**AI に読ませて実行させる指示**として書いてあります
——対象のエージェントに渡すか、エージェント自身に `proctor skill <名前>` を
実行させて読ませてください。

Claude Code で以下をそのまま貼る。

---

```
agent-proctor (https://github.com/syarihu/agent-proctor) と連携するように、
私の Claude Code の設定を整えてください。

## 前提の確認

まず `~/bin/proctor` または PATH 上の `proctor` が実行できることを確認してください。
無ければ proctor をインストールしていないので、そこで止めて教えてください。

## やってほしいこと

`~/.claude/settings.json` に以下の hooks と statusLine を用意してください。
**既存の設定は消さないこと。** 同じイベントに別のフックが登録されていれば、
配列に足す形で共存させてください。

proctor のコマンドは絶対パスで書いてください——`command -v proctor` で実際の場所を
調べて、その値を使ってください（以下の表は `$HOME/bin/proctor` を前提にしています）。
フックの実行環境ではその場所が PATH に乗らないことがあり、PATH 頼みだと
ここだけ静かに落ちます。また `[ -x "<パス>" ] &&` で存在を確かめてから呼ぶようにして、
proctor を消したときに Claude Code 側がエラーにならないようにしてください。

| イベント | matcher | コマンド | 意味 |
| --- | --- | --- | --- |
| `SessionStart` | なし | `proctor _touch idle` | ここでセッションが開いた（`--resume` でも飛ぶ） |
| `UserPromptSubmit` | なし | `proctor _touch running` | 動き出した |
| `PostToolUse` | `*` | `proctor _touch running` | 実行中に戻す |
| `Notification` | なし | `proctor _touch notification` | 確認待ちかもしれない |
| `Stop` | なし | `proctor _touch done` | ターンが終わった |
| `StopFailure` | なし | `proctor _touch failed` | ターンが落ちた (レートリミット等) |
| `SessionEnd` | なし | `proctor _touch clear` | セッションが終わった |
| `SubagentStart` | なし | `proctor _subagent start` | サブエージェントが増えた |
| `SubagentStop` | なし | `proctor _subagent stop` | サブエージェントが減った |

いずれも stdin にフックの JSON がそのまま渡る必要があります。
Claude Code は既定でそうするので、パイプなどを自分で足す必要はありません。

`SessionStart` は、**再開したセッションを、まだ何もしていないうちから一覧に載せる**ための
ものです。これが無いと最初のプロンプトを送るまで何も記録されず、そのあいだ、
そのセッションがいる worktree は「誰もいない」ように見えます。
このフックは会話の圧縮や `/clear` でも飛ぶので、proctor は `idle` を
**まだ知らないセッションを登録するときにしか使いません**。既に一覧に居るセッションに
`idle` が届いても何も変わらないので、動いているセッションが待機中に落ちることはありません。

### それぞれの理由 (省くと壊れるので消さないでください)

- **`PostToolUse` を入れる理由**: 権限確認で確認待ちになった後、承認して実行に戻ったことを
  伝える経路がこれしかありません。抜くと、承認したのに確認待ちの表示のまま止まって見えます。
  何度も呼ばれますが、agent-proctor は中身の変わらない書き込みを捨てるので負荷にはなりません。
- **`Notification` に `waiting` ではなく `notification` を渡す理由**: このイベントは
  権限確認のほかに「60秒入力なし」のアイドル通知でも発火します。区別せず確認待ちにすると、
  終わったあと放置しただけで印が付きます。`notification` を渡すと proctor 側が
  メッセージを見て切り分けます。
- **`StopFailure` を入れる理由**: レートリミットや overloaded でターンが落ちたときは
  `Stop` が発火しません。繋がないと、落ちたセッションが「実行中」のまま一覧に居座ります。
- **`PreToolUse` (`Task|Agent`) ではなく `SubagentStart` を使う理由**:
  サブエージェントを1体ずつ見分ける鍵 `agent_id` が載るのは `SubagentStart` だけです。
  `PreToolUse` はまだ子が生まれる前に親側で発火するので、数えることしかできません。
  古い `PreToolUse` の繋ぎ方を残したままでも壊れません (proctor は数より
  1体ずつの一覧を優先します) が、残す利点もありません。
- **`SessionEnd`・`SubagentStart`・`SubagentStop` を同期で呼ぶ理由**: バックグラウンドに投げると
  プロセスの終了に巻き込まれて書き終わる前に殺されることがあり、特に `SubagentStop` を
  取りこぼすとサブエージェントが一覧に居座る原因になります。他のイベントは末尾に `&` を付けて
  非同期にして構いませんが、これらのライフサイクルイベントは同期にしてください。

### statusLine

セッション名・モデル・コンテキスト使用率は hooks では取れず、statusLine にしか届きません。
一覧に出したいので、statusLine から proctor に横流ししてください。

- **statusLine をまだ使っていない場合**: stdin の JSON をそのまま
  `proctor _stats` に渡すだけのコマンドを設定してください。
- **すでに statusLine を使っている場合**: 既存の表示を壊さないこと。
  stdin は一度しか読めないので、既存のスクリプトの中で JSON を先に読み切り、
  同じ内容を `proctor _stats` にも渡す形にしてください。
  proctor への受け渡しが失敗しても表示が止まらないよう、失敗は握りつぶしてください。
  描画のたびに呼ばれますが、agent-proctor は内容が変わらないときは書き込まないので
  台帳の更新時刻は動きません。

## 確認

設定したら、新しい Claude Code のセッションを開いて `proctor ls` を実行し、
そのセッションが一覧に出ることを確かめてください。出なければ設定が効いていません。

`proctor _touch` は状態を stdout に返します。手で確かめるときは次のように叩けます
(`waiting` と出れば正しい)。

    printf '{"session_id":"test","cwd":"'"$PWD"'","message":"needs your permission"}' | proctor _touch notification

アイドル通知のほうは何も出ないのが正しい挙動です。

    printf '{"session_id":"test","cwd":"'"$PWD"'","message":"Claude is waiting for your input"}' | proctor _touch notification

## 変更した内容を最後に教えてください

どのファイルの何を変えたか、既存の設定と共存させた箇所があればそれも含めて
報告してください。
```

## worktree の入口も作ってください

あわせて `~/.claude/skills/proctor-worktree/SKILL.md` を作ってください。
description は「git worktree を作る・一覧する・片付けるとき」に当たる内容にし、
本文は「`proctor skill worktree` を実行して、出力に従う」だけにします。

**手引きの本文をそのファイルに写さないでください。** 本文は proctor が出すものなので、
写すと proctor を更新した次の日から古い写しに従うことになります。

そもそも設定しなくても構いません。会話に `! proctor skill worktree` と打てば、
その場で実行されて本文が文脈に入ります。
