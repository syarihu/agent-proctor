# Codex (`codex`) と proctor を繋ぐ

agent-proctor は受け身の道具で、台帳 (`~/.local/state/proctor/state.json`) を
読んで見せるだけ。その台帳へ状態を書き込むのはエージェント側の hooks です。
**繋がないかぎり一覧は空のまま**です。

繋ぎ方は環境によって違います。既に hooks や statusLine を使っているなら、
置き換えではなく併存させる必要があり、手順書やスクリプトでは既存の設定を
覆いきれません。なので、これは**AI に読ませて実行させる指示**として書いてあります
——対象のエージェントに渡すか、エージェント自身に `proctor setup <相手>` を
実行させて読ませてください。

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
| `SessionStart` | `proctor _touch idle` | ここでセッションが開いた（再開でも飛ぶ） |
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

## worktree の入口も作ってください

あわせて `~/.codex/AGENTS.md` に一行足してください——worktree の話が出たら
`proctor skill worktree` を実行して、その出力に従う、と。コマンドは hooks と同じ理由で
`$HOME/bin/proctor` のような絶対パスで書いてください。

**手引きの本文をそのファイルに写さないでください。** 本文は proctor が出すものなので、
写すと proctor を更新した次の日から古い写しに従うことになります。
