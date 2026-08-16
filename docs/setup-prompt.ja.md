# Claude Code との連携

*[English](setup-prompt.md) が正本です。こちらはその訳なので、内容がずれていたら英語版が正しい。*

agent-proctor は台帳 (`~/.local/state/proctor/state.json`) を読んで表示するだけの受け身の道具で、
そこに状態を書き込むのは Claude Code の hooks。**繋がないと一覧は空のまま**になる。

繋ぎ方は環境によって変わる。すでに hooks や statusLine を使っていれば、
上書きせずに混ぜないといけない。手順書やスクリプトにすると
「既存の設定がある場合」を全部書き切れないので、**AI に読ませる指示**にしてある。

## 使い方

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

proctor のコマンドは `$HOME/bin/proctor` のように絶対パスで書いてください。
フックの実行環境では PATH に ~/bin が乗らないことがあり、PATH 頼みだと
ここだけ静かに落ちます。また `[ -x "$HOME/bin/proctor" ] &&` で存在を確かめてから
呼ぶようにして、proctor を消したときに Claude Code 側がエラーにならないようにしてください。

| イベント | matcher | コマンド | 意味 |
| --- | --- | --- | --- |
| `UserPromptSubmit` | なし | `proctor _touch running` | 動き出した |
| `PostToolUse` | `*` | `proctor _touch running` | 実行中に戻す |
| `Notification` | なし | `proctor _touch notification` | 確認待ちかもしれない |
| `Stop` | なし | `proctor _touch done` | ターンが終わった |
| `SessionEnd` | なし | `proctor _touch clear` | セッションが終わった |
| `PreToolUse` | `Task\|Agent` | `proctor _subagent start` | サブエージェントが増えた |
| `SubagentStop` | なし | `proctor _subagent stop` | サブエージェントが減った |

いずれも stdin にフックの JSON がそのまま渡る必要があります。
Claude Code は既定でそうするので、パイプなどを自分で足す必要はありません。

### それぞれの理由 (省くと壊れるので消さないでください)

- **`PostToolUse` を入れる理由**: 権限確認で確認待ちになった後、承認して実行に戻ったことを
  伝える経路がこれしかありません。抜くと、承認したのに確認待ちの表示のまま止まって見えます。
  何度も呼ばれますが、agent-proctor は中身の変わらない書き込みを捨てるので負荷にはなりません。
- **`Notification` に `waiting` ではなく `notification` を渡す理由**: このイベントは
  権限確認のほかに「60秒入力なし」のアイドル通知でも発火します。区別せず確認待ちにすると、
  終わったあと放置しただけで印が付きます。`notification` を渡すと proctor 側が
  メッセージを見て切り分けます。
- **`SessionEnd` を同期で呼ぶ理由**: バックグラウンドに投げると Claude 本体の終了に
  巻き込まれて、書き終わる前に殺されることがあります。他のイベントは末尾に `&` を付けて
  非同期にして構いませんが、`SessionEnd` だけは同期にしてください。

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

---

## 他のエージェントとの連携

`_touch` / `_subagent` / `_stats` はどれも stdin の JSON を読むだけなので、
同じ形のライフサイクルフックを持つツールなら同様に繋げる。
セッションIDは `session_id` のほか `conversationId` / `conversation_id` も見る
(Antigravity 向け)。

すでに同じイベントで別のことをしている場合（端末のタブに色を付けるなど）は、
stdin が一度しか読めないことに注意する。先に JSON を読み切ってから、
同じ内容を `proctor` にも渡す。
