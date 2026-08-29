# git worktree を作る・片付ける

いまいるリポジトリは agent-proctor が見ている。worktree の作り方と片付け方はここに書いてある。

**proctor は worktree を作らないし消さない。** 読むだけ（`git worktree list`・`git diff`・
hooks が書いた台帳）。以下の変更はすべて**あなたが打つ git コマンド**でやる。

## 作る前に見る

```bash
proctor worktree ls            # いまのリポジトリ
proctor worktree ls --all      # proctor が見たことのある全リポジトリ
proctor worktree ls --json     # 同じ内容を読み取り向けに
```

1件ごとに、そこで動いているセッション・未コミットの変更・ブランチが取り込み済みか・
最後のコミットからどれだけ経ったかが返る。`isRemovable` は「誰も使っておらず、
未コミットの変更が無く、取り込み済みで、鍵も掛かっていない」ときだけ true になる。

**バイナリは、行が1行も動かなくても「未コミットの変更」に数える。** `.png` が何行
変わったかは git には言えないので、そういうファイルは `added`/`removed` ではなく
`diff.binary`（端末では `~N`）に1個ずつ数える。他の変更と同じように `isRemovable` を
false にするので、書き換えたバイナリしか無い worktree は「空」ではない。

**`diff` が意味を持つのは `diffKnown` が true のときだけ。** worktree を読めなかったときも
0 が並ぶので、`isRemovable` はそういうものを弾いている。この旗ではなく**手で判断する**
（下の 2 の経路）ときは、`diffKnown`・`sessions`・`isLocked`・`isMain`・`isBare`・`isPrunable`
を自分で確かめること。読めなかった worktree は「空」ではなく「**分からない**」。

**毎回これを先に読むこと。** その作業の worktree が既にあるなら、作り直さずそれを使う。
同じ仕事のディレクトリが5つ並ぶのは、たいていこれを見なかったせい。

## どこに作るか

規約は `~/.config/proctor/config.json` に書く。**新しく書くならここで、
リポジトリの中には置かない。** worktree の切り方は使う人の都合であって、
そのリポジトリの持ち物ではないので、proctor を使っていない人のリポジトリに
ファイルを増やさない。リポジトリ直下の `.proctor.json` も読むが、あれは
チームで規約を共有したいときの上書き（下の「鍵ごとに、次の順で」）。

```json
{
  "worktreeBase": ".claude/worktrees",
  "branchPattern": "{user}/{name}",
  "repositories": {
    "github.com/syarihu/agent-proctor": {
      "copyFiles": ["local.properties"]
    }
  }
}
```

| 鍵 | 意味 |
| --- | --- |
| `worktreeBase` | worktree を作る場所。リポジトリ root からの相対（絶対パスでもよい） |
| `branchPattern` | ブランチ名の形。`{name}` は作業名のスラグ、`{user}` は git のユーザー、`{issue}` は issue 番号（あるとき） |
| `copyFiles` | gitignore されていて worktree に付いてこないファイル。本体からコピーする。無いと最初のビルドで即死する類（`local.properties` など）。リポジトリごとに違うので、たいてい `repositories` の下に書く |

トップレベルが全リポジトリの既定で、`repositories` がリポジトリごとの上書き。
鍵は remote origin を `<ホスト>/<持ち主>/<名前>` に均したもの。
`git remote get-url origin` が返す書き方は1つではない（scp 風の
`git@github.com:owner/repo.git`、URL の `ssh://…` や `https://…`）ので、
末尾を削るのではなく、ホスト・持ち主・名前を読み取って `/` で繋ぐ
（`.git` は落とす）。
**置き場所のパスを鍵にしないのは、どこに clone するかが人それぞれだから。**
worktree の中で走っているときは本体のパスとも離れているので、なおさら当てにならない。

鍵ごとに、次の順で最初に見つかったものを使う。

1. リポジトリ直下の `.proctor.json`（**あれば**すべてに勝つ。チームで規約を共有したい
   ときのための逃げ道で、置いていないのが普通）
2. `~/.config/proctor/config.json` の `repositories` の、そのリポジトリの origin の項
3. 同じファイルのトップレベル

**どこにも書かれていないとき、規約を黙って決めないこと。** 既存の worktree
（`proctor worktree ls --json`）と `git branch` のブランチ名を見て、読み取った規約を提案し、
**人が同意してから** `~/.config/proctor/config.json` に書き足す。

## 作る

```bash
git worktree add -b <ブランチ> <worktreeBase>/<名前> <元のブランチ>
```

- 分岐元はそのリポジトリが実際に開発しているブランチ（普通は既定ブランチを fetch した直後）。
  作業の指示に別の指定があればそちらに従う
- そのあと `copyFiles` を本体からコピーする
- ブランチが既にあるなら `-b` は付けず、checkout するだけにする

あとはそのディレクトリでエージェントを起こす。hooks が入っていれば最初のフックで
勝手に proctor の一覧に出るので、登録の手続きは要らない。

## 片付ける

リポジトリを埋めるのは、終わった仕事の worktree。こう掃く。

1. `proctor worktree ls --all --json` を取り、`isRemovable: true` のものを拾う
2. **`merged: false` は「終わっていない」の証拠ではない。** squash merge された PR は
   歴史が繋がらないので proctor からは見えない。残ったブランチは GitHub に聞いてから諦める。
   ```bash
   git rev-parse <ブランチ>
   gh pr list --head <ブランチ> --state merged --json number,mergedAt,headRefOid
   ```
   **コミットまで一致すること。** マージ済みの PR が言えるのは「その名前のブランチが
   一度マージされた」ことだけで、そのあとも作業が続いていたり名前を使い回していたら、
   そのコミットはここにしか無い。マージ済み PR の `headRefOid` が
   いまのブランチの先端と一致するときだけ「マージ済み」とみなす。
   `gh` が無い・ログインしていない・取得に失敗したときは**分からない**であって、
   分からないものは残す
3. **消す前に必ず一覧を人に見せて、返事をもらう。** どの worktree の、どのブランチを、
   なぜ終わったと判断したかを添える
4. 許可が出たものだけ、
   ```bash
   git worktree remove <パス>
   git branch -d <ブランチ>
   ```
   **squash merge されたブランチは `-d` では消せない。** git が辿れる歴史が
   無いからで、それがそもそも 2 を置いた理由。そこは `git branch -D` が正しいが、
   使ってよいのは 2 を全部満たしたときだけ——マージ済み PR の `headRefOid` が
   そのブランチの先端で、`diff` が空で、その worktree に許可が出ていること。
   それ以外の場面では、`-D` は今までどおり明示的に言われたときだけ。
5. proctor 側の後始末は要らない。行は勝手に消える

## 触ってはいけないとき

次のどれかに当てはまるものは残す。**なぜ残したかを言うこと。**

- 未コミットの変更がある（`diff` が空でない）。そこにしか無い仕事
- push していないコミットがある（`git log --branches --not --remotes`）
- まだセッションが動いている（`sessions` が空でない）
- `isLocked` が true。誰かが意図して鍵を掛けた

worktree を消すのは、控えのない仕事を捨てること。二度聞かれる面倒は一文で済むが、
間違えると一日が消える。
