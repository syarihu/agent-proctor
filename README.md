# taskhub

git worktree ごとにコーディングエージェントを走らせ、動いているエージェントを
一箇所で見るための Mac アプリと CLI。

タブを1枚ずつ確かめなくても、どのセッションが確認待ちで止まっているか、
どれが裏で動き続けているかが分かる。

```
⏳ サイドバーの空状態の表示を直す  (context: 13%)
   develop · 経過: 59s
▶ Kit を層に分ける  (context: 32%)
   main · 経過: 1m  🤖2              +74 -3 ?2
```

セッション名・コンテキスト使用率・サブエージェントの数は、タブを見ても分からない情報。
`経過` は最後に状態が変わってからの時間で、実行中のまま長ければ考え込んでいるか
止まっているかの手がかりになる。

## かたち

ロジックを CLI とアプリの両方から使えるように、`TaskhubKit` を3層に分けている。
**表示の都合を Kit に持ち込まない**のが境界の引き方で、たとえば端末の ANSI 色は
CLI 側 (`Terminal.swift`)、SwiftUI の色はアプリ側 (`Palette`) がそれぞれ持つ。
Kit が知っているのは「どんな状態があり、どんな記号と名前で呼ぶか」まで。

```
TaskhubKit/
  Model/       データと語彙。I/O を持たない
               TaskRecord, DiffCounts, CollectedTask, TaskStatus, RepoConfig, TaskID
  Repository/  外の世界との出入り口。ここだけが台帳・git・環境を触る
               LedgerStore, GitClient, ProcessRunner, ConfigStore,
               EnvironmentSource, Paths
  UseCase/     やりたいこと1つに1つ。判断はすべてここが持つ
               CollectTasks, CreateWorktree, RemoveWorktree,
               CleanMergedWorktrees, RecordHookEvent, RecordSessionStats,
               ReapClosedSessions, HookPayload

taskhub/       CLI (View)。引数を読んで UseCase を呼び、結果を端末向けに整える
TaskhubApp/    アプリ (View)。SwiftUI と AppKit。TaskStore が Repository を包む
```

| ファイル | 役割 |
| --- | --- |
| `~/.local/state/taskhub/state.json` | 台帳。リポジトリを横断して1つ。実行時に自動で作られる |

### 守っていること

- **集計は `CollectTasks.run()` だけを通る。** CLI の表もサイドバーもこの戻り値を
  整形するだけにして、表示側にロジックが漏れないようにしている。
  集計を足したくなったらそこに書く
- **View は Repository を直接触らない。** アプリ側は `TaskStore` が台帳を包み、
  メニューも「開く」もそこを経由する。台帳の読み方が変わっても直すのは1箇所で済む
- **台帳は排他ロック (`LedgerStore.withLock`) で守り、中身が変わらなかったときは
  書かない。** 台帳の更新時刻はサイドバーが変化を知る合図なので、無変更で触ると
  その都度 git を起動して数え直してしまう。hooks は何度も呼ばれ、多くは何も変えずに
  終わるため、ここが効く
- **`ls --json` のキーは名前順に固定してある。** Swift の辞書はプロセスごとに
  並びが変わるので、指定しないと同じ内容でも実行のたびに順序が入れ替わる。
  この出力は AI やツールが差分を取るので揺れると扱いにくい

### 振る舞いを確かめる

`scripts/baseline.sh` が主要なコマンドを一通り叩いて出力を書き出す。
作り替える前後で見比べれば、壊していないことを確かめられる。

```bash
scripts/baseline.sh before   # 変更前
scripts/baseline.sh after    # 変更後
diff -u /tmp/taskhub-baseline/{before,after}.txt
```

使い捨ての git リポジトリと台帳を相手にするので、実際に使っている台帳には触らない。

## 入れる

```bash
scripts/create-signing-cert.sh   # 初回だけ。ローカル署名用の証明書を作る
scripts/install.sh               # /Applications に入れ、~/bin/taskhub を張る
```

証明書を先に作るのは、オートメーション（Apple Events）の許可が
「バンドルID + コード署名」に紐づくため。アドホック署名だとビルドのたびに
署名の中身が変わり、そのつど iTerm2 の操作許可を聞き直される。

初回起動時に iTerm2 の操作許可を求められるので、許可する。
メニューバーの「ログイン時に起動」を入れておくと、次からは自動で立ち上がる。

## 使う

```bash
taskhub ls              # 一覧（--all で全リポジトリ、--json で機械向け）
taskhub new <名前>      # worktree を作る
taskhub open <ID>       # worktree のパスを出す（cd "$(taskhub open x)"）
taskhub attach <ID>     # そのタスクの claude を開く（続きから）
taskhub diff <ID>       # ベースからの差分
taskhub clean           # マージ済みの worktree を片付ける（--yes で実行）
taskhub sidebar         # サイドバー（アプリ）を起動する
```

破壊的な操作は既定で何もしない。`clean` は一覧を出すだけで、消すには `--yes` が要る。
未コミットの変更がある worktree は `clean` の対象から外れる。

サイドバーの行をクリックすると、そのタブが生きていればフォーカスし、
閉じていれば新しいタブで会話の続きから開く。

## リポジトリごとの設定

リポジトリ直下に `.taskhub.json` を置くと `new` の挙動を変えられる。無くても動く。

```json
{
  "baseBranch": "develop",
  "branchPrefix": "syarihu/",
  "worktreeDir": ".claude/worktrees",
  "copyFiles": ["local.properties"],
  "maxConcurrent": 3
}
```

`copyFiles` は gitignore されていて worktree に引き継がれないファイルを持ち込むためのもの。
`worktreeDir` は初回に `.git/info/exclude` へ自動で追加されるので、親リポジトリの
`git status` は汚れない。

## エージェントとの連携

**入れただけでは一覧は空のまま。** taskhub は台帳を読んで表示するだけの受け身の道具で、
状態を書き込むのは Claude Code の hooks のほう。

繋ぎ方は環境によって変わる（すでに hooks や statusLine を使っていれば混ぜる必要がある）ので、
手順書ではなく **AI に渡す指示**にしてある。

→ [docs/setup-prompt.md](docs/setup-prompt.md) を Claude Code に貼る

hooks から呼ばれるのは次の3つ。人が打つものではないのでヘルプには出していない。
どれも stdin にフックの JSON を受ける。

| コマンド | 呼ぶ側 | 中身 |
| --- | --- | --- |
| `taskhub _touch <状態>` | hooks | running / waiting / done / clear / notification |
| `taskhub _subagent start\|stop` | hooks | サブエージェントの増減 |
| `taskhub _stats` | statusline | セッション名・モデル・コンテキスト使用率 |

`_touch` は**記録した状態を stdout に返す**。呼び出し側が「結局どうなったか」を
使えるようにするため（タブの色を変えるなど）。

`notification` だけは特別で、権限確認なのか「60秒入力なし」のアイドル通知なのかを
taskhub 側が payload の `message` を見て切り分ける。アイドルなら何も記録せず、
何も返さない。区別せず確認待ちにすると、終わったあと放置しただけで印が付いてしまう。
この判断を呼び出し側に書き写すと、片方だけ直したときに食い違う。

taskhub 経由で作った worktree だけでなく、普通に開いた対話セッションも
`_touch` の呼び出しから拾って一覧に載せる。

## iTerm2 との連携

タブへのフォーカスと新しいタブの作成は AppleScript で行う。
`id of session` は `ITERM_SESSION_ID` の `:` 以降と同じ値（どちらも
PTYSession の guid）なので、台帳に持っておけばそのまま突き合わせられる。

hardened runtime の下では `com.apple.security.automation.apple-events` の
entitlement が要る。これが無いと Apple Event がランタイムに弾かれ、
TCC まで届かないためシステム設定のオートメーション一覧にも出てこない。

サイドバーの位置合わせは CGWindowList で iTerm2 のウィンドウ枠を読む。
こちらはオートメーションの許可が要らないので、許可を出す前でも吸着だけは動く。

## 依存

`git` のほかに、`clean` が `gh`（マージ済み PR の判定）を使う。
Swift の外部パッケージには依存していない。
