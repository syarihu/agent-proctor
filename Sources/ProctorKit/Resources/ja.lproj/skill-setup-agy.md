# Antigravity (`agy`) と proctor を繋ぐ

agent-proctor は受け身の道具で、台帳 (`~/.local/state/proctor/state.json`) を
読んで見せるだけ。その台帳へ状態を書き込むのはエージェント側の hooks です。
**繋がないかぎり一覧は空のまま**です。

繋ぎ方は環境によって違います。既に hooks や statusLine を使っているなら、
置き換えではなく併存させる必要があり、手順書やスクリプトでは既存の設定を
覆いきれません。なので、これは**AI に読ませて実行させる指示**として書いてあります
——対象のエージェントに渡すか、エージェント自身に `proctor skill <名前>` を
実行させて読ませてください。

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
   proctor は絶対パスで書いてください——`command -v proctor` で調べて、その値を使います
   （表は `$HOME/bin/proctor` を前提にしています）。フックの実行環境では
   その場所が PATH に乗らないことがあります。

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

## worktree の入口も作ってください

あわせて、起動時に読んでいる指示ファイルに一行足してください——worktree の話が出たら
`proctor skill worktree` を実行して、その出力に従う、と。

**手引きの本文をそのファイルに写さないでください。** 本文は proctor が出すものなので、
写すと proctor を更新した次の日から古い写しに従うことになります。
