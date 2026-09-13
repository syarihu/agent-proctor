---
keywords: [adjutant, adjutanthubstore, claude-pid, deskisland, hub, pid, resolvehubsessions, state-dir, 常駐ハブ, 見出し机]
category: architecture
---

# adjutant の常駐ハブと見取り図の見出し机

## Entry: adjutant の hub セッションを台帳と突き合わせる仕組み (pid 一致)
keywords: [adjutant, hub, claude-pid, resolvehubsessions, adjutanthubstore, deskisland, 常駐ハブ, 見出し机, state-dir, pid]
uid: 6fb94491f0d8
project: syarihu/agent-proctor

[agent-adjutant](https://github.com/syarihu/agent-adjutant) (`adj`) の常駐ハブを、見取り図の
見出し机に座らせるために調べたこと。

## 突き合わせの鍵は pid

`adj hub` は「このリポジトリの hub は自分だ」という記録を1ファイル書いてから、
**`exec` でエージェント本体に化ける**。PID が引き継がれるので、記録の `pid` は
そのままエージェント本体 (claude) の PID になる。

proctor 側の `TaskRecord.pid` は `EnvironmentSource.agentPID()` = `CLAUDE_PID`、つまり同じ
claude 本体の PID。**両者は同じプロセスを指しているので、pid 比較だけで台帳の行を特定できる。**

`claude` は Mach-O の実行ファイルでラッパースクリプトを噛まないので、pid がズレない。

## 記録の場所と中身

置き場所は adjutant の `state_dir()` と同じ順で決める (`AdjutantHubStore.stateDirectory`)。
**ここがずれると、動いている hub をいつまでも見つけられないまま何のエラーも出ずに空を返し続ける。**

    ADJUTANT_STATE_DIR → $XDG_STATE_HOME/adjutant → ~/.local/state/adjutant

    <state_dir>/hubs/<slug>.json
    { "pid": …, "hubName": "adjutant-<owner>-<repo>-<16桁>", "cwd": "<main checkout>",
      "startedAt": …, "psStarted": …, "nameInCommand": … }

## 判定 (`ResolveHubSessions.hubIDs`)

1. **pid + 作業ディレクトリの両方一致**。pid だけで決めないのは、macOS が pid を使い回したときに
   たまたま番号が一致した無関係のセッションを hub に仕立てないため
2. pid で当たらなかった hub は、`cwd` に座っているセッションが**ちょうど1つのとき**だけ採用。
   Claude Code 以外 (pid を送ってこないエージェント) の受け皿。2つ以上あるなら決まらないので、
   間違ったほうを見出し机に座らせるより何も動かさない

生死は `AdjutantHubStore.hubs()` では見ない。突き合わせる相手が台帳で、台帳は死んだセッションを
すでに刈り取っているため。ここで `ps` を叩くと机を描き直すたびにプロセスを起こすことになる。

## 見取り図側 (`DeskIsland`)

- ハブは `DeskIsland.hub` に入り、`seats` からは抜ける (抜かないと見出しとその隣に2つ座って見える)
- `indexedSeats` がハブを **席番号 `DeskIsland.hubSeatIndex` (= -1)** として混ぜる。
  `DeskLayout.seatPoint` が -1 を見出し机として解釈するので、呼ぶ側はハブと普通の席を区別せず回せる
- **違うのは動きだけで、それが常駐の中身**。分岐は3か所:
  - 待機列に並ばない (列は見出し机の前にできるので、自分の机に自分が並ぶことになる)
  - 待っていても席にいる (普通の席が待ちの間空くのは、その人が列に立っているから)
  - ラウンジに行かない (手が空いている間も依頼を待つのが役目)
- 着替え・紙のログ・仕草・サブエージェント・カメラ追従・入退室は**席と同じ経路をそのまま通る**。
  専用実装に割ると片方だけ直す事故が起きる

## 格子は元からハブに1セル空けてある

`OfficeFloorPlan` は「ハブも席も同じ格子に流し込む」設計 (`maxCells = 1 + seats.count`) なので、
ハブ机を 104pt の名札から 184pt の通常席に広げてもレイアウトは動かない。
変わるのは机を揃える上端だけ (`hubCellTop` 117 / `seatCellTop` 115)。

## 板の書き分け (`DeskWhiteboardNode.Kind`)

`.seat` / `.plate` (誰も座っていない見出し机) / `.hub` (常駐ハブが座っている見出し机) の3つ。
`isHub` 1つでは「見出し机か」と「名札だけか」が二重になって表せない。

`.hub` の板はリポジトリ名のまま (区画の見出しなので、セッション名に差し替えると
どのリポジトリか示すものが区画から無くなる)。ハブであることは上端の青いヘッダー帯に `HUB` と刷る。

**帯を足したら板の上端の座標が全部ずれる。** タブ番号バッジは自分の中心から上下 6.5pt ずつ伸びるので、
帯の直下に置いたつもりでも上半分が帯に食い込んで `HUB` を塗りつぶした (バッジの zPosition が上)。
数値はベタ書きせず `hubHeaderHeight` と `tabBadgeHalfHeight` から出す。

