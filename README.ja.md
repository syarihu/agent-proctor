[English](README.md) | 日本語

<p align="center">
  <img src="docs/images/agent-proctor-logo.png" alt="agent-proctor" width="720">
</p>

# agent-proctor

> 英語版が正本 ([README.md](README.md))

git worktree と iTerm2 タブで並行稼働する AI コーディングエージェント（Claude Code、Antigravity、Codex など）を一元監視・管理する macOS アプリ & CLI ツール。

## 概要

複数のリポジトリや git worktree にまたがって多数の AI コーディングエージェントを走らせていると、全体の進捗把握が難しくなります。どのエージェントがコマンドの実行承認を待っているのか、どれが深く考え込んでいるのか、どれが作業を完了したのかを、タブを1枚ずつ切り替えて探すのは非効率です。

**agent-proctor** は、稼働中のすべてのエージェントセッションを監視・統括するプロクター（試験監督）として機能します。iTerm2 のターミナルウィンドウの脇に寄り添ってセッション状態をリアルタイムに一覧表示し、ユーザーの確認が必要なセッションを強調表示して、ワンクリックで該当タブへジャンプできるようにします。

<p align="center">
  <img src="docs/images/sidebar-and-terminal.png" alt="iTerm2 の横に並んだ agent-proctor サイドバー。セッションの状態、要確認通知、macOS 通知を表示" width="880">
</p>

## 主な機能

- **iTerm2 連動サイドバー**: iTerm2 ウィンドウの横に吸着する折りたたみ可能なサイドバー。各行が iTerm2 のタブと対応しており、クリックするだけで瞬時にそのタブへフォーカスを移動できます。
- **「要確認 (Needs You)」ストリップ**: サイドバーの最上部に固定表示。危険なシェルコマンドの実行承認待ち、未確認の作業完了、異常終了したセッションなどが集約され、見逃しを防ぎます。
- **詳細なセッション情報の可視化**: 実行状態（実行中、確認待ち、完了、エラー）、状態変化からの経過時間、コンテキスト消費率、実行中のツール（`Read`, `Edit`, `Grep` など）、サブエージェントの親子階層をリアルタイムに表示します。
- **Pull Request との連携**: worktree のブランチに紐づく GitHub Pull Request を自動検出し、ステータス色（open, merged, closed, draft）と PR 番号を表示。クリックでブラウザの PR ページを直接開けます。
- **階層化された整理とグループ化**: セッションを GitHub リポジトリおよび組織・オーナー（アバターアイコン付き）ごとに自動分類。グループ単位での折りたたみ表示に対応し、折りたたみ時も内包セッションの集計（`⏳1 ▶2 ⌁2`）を確認できます。
- **macOS ネイティブ通知**: エージェントが承認待ちになった瞬間、作業が完了した瞬間、エラーが発生した瞬間にシステム通知を送信。通知をクリックするだけで該当のターミナルタブへジャンプします。
- **Git Worktree の監視と整理**: 各 worktree の未コミット差分（`+N -M ?K`）、ブランチのマージ状態、アイドル時間を一覧表示。マージ済みで不要になった worktree（Can go / 削除可能）を一目で特定できます。
- **外部パッケージ依存ゼロ**: 外部のサードパーティ Swift パッケージに依存せず、macOS 標準フレームワークとローカルの `git` のみで動作します（組織アイコン表示や PR 情報取得のための `gh` CLI は任意）。

<p align="center">
  <img src="docs/images/status-transitions.gif" alt="動的な状態遷移、サブエージェント階層、通知の動作例" width="760">
</p>

## インストール

### Homebrew（推奨）

```bash
brew install syarihu/tap/agent-proctor
proctor sidebar
```

### ソースコードからビルド

```bash
# オートメーション権限用のローカルコード署名証明書を作成（初回のみ）
scripts/create-signing-cert.sh

# ビルドして /Applications にインストールし、~/bin/proctor をシンボリックリンク
scripts/install.sh
```

> [!NOTE]
> 初回起動時に、macOS から iTerm2 の操作権限（Apple Events、タブの自動フォーカスに必要）および通知送信権限（デスクトップ通知バナーに必要）が求められます。許可をスキップした場合は、いつでも **設定… → 許可** からシステム設定を開いて有効化できます。

<p align="center">
  <img src="docs/images/settings.png" alt="agent-proctor の設定ウィンドウ" width="540">
</p>

## エージェントとの連携設定

agent-proctor は、共有台帳ファイル（`~/.local/state/proctor/state.json`）からセッション情報を読み取るビューアです。台帳にセッションを反映させるには、各エージェントのイベントフックを設定します。

proctor には、AI エージェント自身に読み込ませて自動設定できるセットアップガイドが内蔵されています：

```bash
# 利用可能なセットアップガイドの一覧を表示
proctor setup ls

# 特定のエージェント（claude, agy, codex など）向けのセットアップ手順を出力
proctor setup claude

# すべてのセットアップ手順を出力
proctor setup all
```

Claude Code の場合、会話内で `! proctor setup claude` を実行するだけで、エージェントが自律的にフック設定を完了します。

## CLI コマンド

`proctor` コマンドを使用することで、GUI サイドバーを開かずに任意のターミナルからセッションや worktree の一覧確認・管理を行えます：

| コマンド | 説明 |
| --- | --- |
| `proctor ls` | 稼働中の全エージェントセッションを一覧表示（`--all` で全リポジトリ対象、`--json` で JSON 出力）。 |
| `proctor worktree ls` | git worktree の稼働状態、未コミット差分、削除可能判定を一覧表示（`--all`, `--json`）。 |
| `proctor attach <id>` | 指定した ID のエージェントセッションを現在のターミナルで再開。 |
| `proctor title <text>` | 現在のセッションに任意の表示タイトルを設定（解除は `proctor title ""` を実行）。 |
| `proctor rm <id>` | 指定したセッションを台帳から削除（worktree 自体はそのまま保持）。 |
| `proctor setup [agent]` | エージェント連携用のフック設定手順を出力。 |
| `proctor skill [name]` | エージェントに実行させる標準ワークフロー手順を出力（例: `proctor skill worktree`）。 |
| `proctor sidebar` | macOS デスクトップサイドバーアプリを起動。 |
| `proctor --version` | バージョン番号を表示。 |

### Worktree の管理

複数のエージェントが作業を終えると、ディスク上には放置された worktree が蓄積します。`proctor worktree ls` を実行することで、アイドル状態の worktree や、すでにマージ済みのブランチを容易に確認できます：

```
agent-proctor
WORKTREE  BRANCH       STATE        DIFF   IDLE
work      feature      使用中 (2)   +1 ?1  3m
spike     spike        誰もいない   +1     2d
merged    merged-work  削除可能            6d
```

エージェント自身に安全な worktree の作成や片付け手順を実行させるには、同梱されているスキル手順を渡します：

```bash
proctor skill worktree
```

<p align="center">
  <img src="docs/images/menu-bar.png" alt="セッションの集計とクイックアクセスを表示する agent-proctor メニューバー" width="382">
</p>

## メニューバー常駐

agent-proctor は macOS のメニューバーに常駐します。アイコン横には確認待ちや実行中のセッション数がリアルタイムに集計表示され、メニューバーをクリックすると全セッションの一覧から任意の iTerm2 タブへ直接移動できます。

## アーキテクチャと設計

agent-proctor は、明確な層分離原則に基づき、Swift Package Manager のマルチターゲット構成で設計されています：

- **基盤層 (Core: `Model`, `Utility`, `Resources`)**: 基本データ構造、低レイヤのプロセス実行、多言語リソース。業務判断は含まない。
- **リポジトリ層 (Repository: `RepositoryLedger`, `RepositoryGit`, `RepositoryGitHub`)**: ディスク台帳の同期、git コマンド、GitHub CLI との出入り口。
- **ユースケース層 (UseCase: `UseCaseTask`, `UseCaseSession`, `UseCaseWorktree`, `UseCaseNotice`)**: 1 UseCase 1 責務に特化した業務判断とドメイン処理。
- **デザイン & ブリッジ層 (Design & Bridges: `DesignSystem`, `ItermBridge`)**: UI デザイントークン、状態グリフ、AppleScript による iTerm2 操作ブリッジ。
- **状態管理層 (Application State: `AppState`)**: バックグラウンドのポーリング結果を SwiftUI に橋渡しする `@MainActor` 状態ストア (`TaskStore`)。
- **UI / 機能層 (Features: `FeatureSidebar`, `FeatureMenuBar`, `FeatureSettings`)**: 画面コンポーネントおよびビューコントローラ。
- **エントリポイント (Entry Points: `proctor`, `ProctorApp`)**: CLI 実行ファイルおよび macOS メニューバーアプリ。

ターゲット間の依存関係図や詳細な境界ルールについては [docs/architecture.ja.md](docs/architecture.ja.md) を参照してください。

## 開発への参加

開発手順やコミット規則、コードコメントの指針、変更確認手順については [CLAUDE.md](CLAUDE.md) を参照してください。

## ライセンス

本プロジェクトは MIT License のもとで公開されています。詳細は [LICENSE](LICENSE) を参照してください。
