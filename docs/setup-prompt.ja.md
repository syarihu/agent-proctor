# エージェントとの連携

*[English](setup-prompt.md) が正本です。こちらはその訳なので、内容がずれていたら英語版が正しい。*

agent-proctor は台帳 (`~/.local/state/proctor/state.json`) を読んで表示するだけの受け身の道具で、
そこに状態を書き込むのはエージェントの hooks。**繋がないと一覧は空のまま**になる。

繋ぎ方は環境によって変わる。すでに hooks や statusLine を使っていれば、
上書きせずに混ぜないといけない。手順書やスクリプトにすると
「既存の設定がある場合」を全部書き切れないので、**AI に読ませる指示**にしてある。

節はエージェントごとに分かれている。[Claude Code](#claude-code-との連携) /
[Antigravity](#antigravity-agy-との連携) / [Codex](#codex-codex-との連携) のうち、
使っているものだけを読めばよい。互いに依存していない。

## Claude Code との連携

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
| `StopFailure` | なし | `proctor _touch failed` | ターンが落ちた (レートリミット等) |
| `SessionEnd` | なし | `proctor _touch clear` | セッションが終わった |
| `SubagentStart` | なし | `proctor _subagent start` | サブエージェントが増えた |
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
- **`StopFailure` を入れる理由**: レートリミットや overloaded でターンが落ちたときは
  `Stop` が発火しません。繋がないと、落ちたセッションが「実行中」のまま一覧に居座ります。
- **`PreToolUse` (`Task|Agent`) ではなく `SubagentStart` を使う理由**:
  サブエージェントを1体ずつ見分ける鍵 `agent_id` が載るのは `SubagentStart` だけです。
  `PreToolUse` はまだ子が生まれる前に親側で発火するので、数えることしかできません。
  古い `PreToolUse` の繋ぎ方を残したままでも壊れません (proctor は数より
  1体ずつの一覧を優先します) が、残す利点もありません。
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

---

## Antigravity (`agy`) との連携

Antigravity は `hooks.json`（`~/.gemini/config/hooks.json` または `.agents/hooks.json`）および `~/.gemini/antigravity-cli/settings.json` の statusLine を使って連携します。

Antigravity のセッション名（タイトル）は、以下の優先順で自動解決されます:
1. `~/.gemini/antigravity-cli/conversation_summaries.db` に記録された AI 自動生成の会話要約タイトル
2. `brain/<conversationId>/` 配下のアーティファクト（Plan等のMarkdown）の H1 見出し
3. `transcript.jsonl` に記録されたユーザーの最初のプロンプトの1行目

### 使い方 (Antigravity 向け)

Antigravity（または `agy`）で以下をそのまま貼る。

```
agent-proctor (https://github.com/syarihu/agent-proctor) と連携するように、
私の Antigravity / agy の設定を整えてください。

## 前提の確認

まず `~/bin/proctor` または PATH 上の `proctor` が実行できることを確認してください。
無ければ proctor をインストールしていないので、そこで止めて教えてください。

## やってほしいこと

1. `~/.gemini/config/hooks.json`（または `.agents/hooks.json`）に以下のフックを用意してください。
   Antigravity のフックは stdout に JSON を期待するため、`proctor _touch` には `--json` フラグを付けてください。

| イベント | matcher | コマンド | 意味 |
| --- | --- | --- | --- |
| `PostToolUse` | `*` | `[ -x "$HOME/bin/proctor" ] && "$HOME/bin/proctor" _touch running --json` | 実行中に戻す |
| `PreToolUse` | `ask_question` | `[ -x "$HOME/bin/proctor" ] && "$HOME/bin/proctor" _touch waiting --json` | ユーザーの確認待ち |
| `PreToolUse` | `invoke_subagent` | `[ -x "$HOME/bin/proctor" ] && "$HOME/bin/proctor" _subagent start` | サブエージェントが増えた |
| `Stop` | なし | `[ -x "$HOME/bin/proctor" ] && "$HOME/bin/proctor" _touch done --json` | ターンが終わった |

2. `~/.gemini/antigravity-cli/settings.json` で statusLine を使っている場合は、スクリプト内で stdin の JSON を `proctor _stats` に渡してください:
   ```python
   # statusline スクリプト内:
   try:
       proctor = os.path.expanduser('~/bin/proctor')
       if os.access(proctor, os.X_OK):
           subprocess.run([proctor, '_stats'], input=raw, text=True,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                          timeout=2)
   except Exception:
       pass
   ```
```

---

---

## Codex (`codex`) との連携

Codex は `~/.codex/hooks.json` にライフサイクルフックを持つ。形は Claude Code と
ほぼ同じで、違うのは次の2点。

- **statusLine に相当する差し込み口が無い。** proctor が出すもののうち、
  フックに来るのはモデル名だけで、セッション名・コンテキスト使用率・レートリミットは
  来ない。これらは Codex 自身が残している記録（名前は `~/.codex/state_<n>.sqlite` の
  `threads` 表、使用率とレートリミットは `~/.codex/sessions/` 配下の rollout の JSONL）
  から proctor が読み取るので、設定することは何も無い。
- **Codex はフックを信頼するかどうかを聞いてくる。** 信頼したフックのコマンドは
  ハッシュで `~/.codex/config.toml` の `[hooks.state]` に記録される。つまり
  `hooks.json` を書き換えた次のセッションで承認を求められ、承認するまでフックは
  動かない。設定したあと一度は手で起動して答えること。

### 使い方 (Codex 向け)

Codex で以下をそのまま貼る。

---

```
agent-proctor (https://github.com/syarihu/agent-proctor) と連携するように、
私の Codex の設定を整えてください。

## 前提の確認

まず `~/bin/proctor` または PATH 上の `proctor` が実行できることを確認してください。
無ければ proctor をインストールしていないので、そこで止めて教えてください。

## やってほしいこと

`~/.codex/hooks.json` に以下のフックを足してください。
**既存の設定は消さないこと。** 同じイベントに別のフックが登録されているなら、
配列に足して両方残してください。

| イベント | コマンド | 意味 |
| --- | --- | --- |
| `UserPromptSubmit` | `proctor _touch running` | 動き出した |
| `PostToolUse` | `proctor _touch running` | 実行中に戻す |
| `PermissionRequest` | `proctor _touch waiting` | こちらの返事待ち |
| `Stop` | `proctor _touch done` | ターンが終わった |
| `SessionEnd` | `proctor _touch clear` | セッションが終わった |
| `SubagentStart` | `proctor _subagent start` | サブエージェントが増えた |
| `SubagentStop` | `proctor _subagent stop` | サブエージェントが減った |

コマンドは proctor が実際に置かれている絶対パスで書いてください
（`command -v proctor` で調べて、その値を使ってください。以下の例は
`$HOME/bin/proctor` を前提にしています）。`--agent=codex` を付け、出力は捨てます。
フックの実行環境に proctor の置き場が PATH に入っているとは限らず、
`[ -x ... ]` のガードは、消えた実行ファイルを叩かないようにするためのものです:

    [ -x "$HOME/bin/proctor" ] && "$HOME/bin/proctor" _touch running --agent=codex >/dev/null 2>&1

1件だけ書くとこうなります:

    {
      "hooks": {
        "UserPromptSubmit": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "[ -x \"$HOME/bin/proctor\" ] && \"$HOME/bin/proctor\" _touch running --agent=codex >/dev/null 2>&1",
                "timeout": 10
              }
            ]
          }
        ]
      }
    }

### それぞれの理由（外さないでください）

- **`--agent=codex` を付ける理由**: Codex の payload は Claude Code とほぼ同じ形
  （`session_id` も `cwd` も `tool_name` も同じ名前）なので、JSON だけではどちらか
  言い切れない。proctor は transcript の置き場所を見て補うが、名乗ってもらうのが
  一番確実で、これで一覧の行が「Claude Code」ではなく「Codex」になる。
- **出力を捨てる理由**: Codex はフックが出力したものを判断（`PermissionRequest`
  での承認・拒否）として読む。proctor が出すのは記録した状態で、端末に向けたもの
  であって Codex に向けたものではない。終了コードのほうは、どちらに転んでも安全で、
  Codex が判断として読むのは**終了コード 2 だけ**、proctor は失敗しても 1 で終わる。
  つまり proctor が壊れていても権限の確認を拒否することはなく、記録されないだけ。
- **通知ではなく `PermissionRequest` を使う理由**: Codex にはアイドル通知に当たる
  イベントが無く、`PermissionRequest` はまさに返事を待っているときだけ飛ぶ。
  だから中身を読んで見分ける必要がなく、そのまま `waiting` にできる。
- **`PostToolUse` を入れる理由**: 権限の確認に答えたあと「実行中に戻った」ことを
  伝えられる唯一の経路。頻繁に飛ぶが、proctor は何も変わらない書き込みを捨てるので
  ただ同然。
- **`SessionEnd` を同期で呼ぶ理由**: バックグラウンドに投げると、書き終わる前に
  Codex 本体と一緒に殺されることがある。他のイベントは末尾に `&` を付けても
  構わないが、`SessionEnd` は同期のままにする。

## 確認

Codex を新しく起動してください。新しいフックを信頼するか聞かれるので承認します
（承認しないとフックは動きません）。そのうえで `proctor ls` を実行し、
セッションが一覧に出ることを確認してください。

## 報告

どのファイルをどう変えたか教えてください。既存の設定と共存させた箇所があれば、
それも書いてください。
```

---

### Codex で見えないもの

- **落ちたターンは分からない。** Claude Code にはレートリミットや過負荷でターンが
  死んだときの `StopFailure` があるが、Codex には相当するイベントが無い。
  そういうセッションは、セッションが終わるまで実行中のまま一覧に残る。
- **プロセスを見張れない。** Claude Code は `CLAUDE_PID` をフックに渡してくれるので
  proctor はセッションが消えた瞬間に気付けるが、Codex は渡してこない。
  Codex の行は即座にではなく、期限切れ（または `proctor rm`）で片付く。

## 他のエージェントとの連携

`_touch` / `_subagent` / `_stats` はどれも stdin の JSON を読むだけなので、
同じ形のライフサイクルフックを持つツールなら同様に繋げる。
セッションIDは `session_id` のほか `conversationId` / `conversation_id` も見る
(Antigravity 向け)。どのエージェントのセッションかは、どれにも `--agent=<名前>` で
名乗らせられる。

すでに同じイベントで別のことをしている場合（端末のタブに色を付けるなど）は、
stdin が一度しか読めないことに注意する。先に JSON を読み切ってから、
同じ内容を `proctor` にも渡す。
