# agent-proctor のルール

## 言語

| 対象 | 言語 |
| --- | --- |
| コミットメッセージ | **英語** |
| コード中のコメント | **日本語** |
| Pull Request のタイトル・本文 | 日本語 または 英語 |
| 文書（README・docs/） | 英語が正本。`*.ja.md` がその訳 |

コメントを日本語にしているのは、**なぜそう書いたのかを残すため**。
何をしているかはコードを読めば分かるので、コメントには
「なぜこうしたか」「そうしないと何が壊れるか」を書く。

コミットメッセージに `feat:` `fix:` `chore:` のような
Conventional Commits のプレフィックスは使わない。何をしたかを普通の文で書く。

## 文書を直すとき

英語版が正本で、日本語版はその訳。今あるのはこの2組。

| 正本（英語） | 訳（日本語） |
| --- | --- |
| `README.md` | `README.ja.md` |
| `Sources/ProctorKit/Resources/en.lproj/skill-*.md` | `ja.lproj/skill-*.md` |

**片方だけ直さない。** 内容がずれると、どちらが正しいのか分からなくなる。

`README.ja.md` の冒頭には「英語版が正本」と書いておく。

`skill-*.md` はエージェントに読ませる手引きで、`proctor skill <名前>` が出す本体。
**エージェントの設定に貼る写しを作らない**（写したものが古びるため）。
どちらの言語を出すかは `Localized` が選ぶので、鍵と同じく**両方に置く**。
こちらに「英語版が正本」とは書かない——読むのはエージェントで、
出てくるのは片方だけなので、見比べる相手がいない。

日本語版から他の文書へリンクするときは日本語版を指す。
読み進めている途中で言語が変わらないようにする。

## 設計

`ProctorKit` は3層に分かれている。層をまたぐ変更をするときは、
どこに置くべきかを先に決める。

| 層 | 置くもの | 置かないもの |
| --- | --- | --- |
| `Model/` | データと語彙 | I/O、判断 |
| `Repository/` | 台帳・git・環境との出入り口 | 業務上の判断 |
| `UseCase/` | やりたいこと1つにつき1つ。判断はすべてここ | 表示の都合 |

View（CLI とアプリ）は UseCase を呼んで整形するだけにする。

守っていること。

- **表示の都合を Kit に持ち込まない。** 端末の ANSI 色は CLI 側の `Terminal`、
  SwiftUI の色はアプリ側の `Palette` がそれぞれ持つ。`TaskStatus` が知っているのは
  「どんな状態があり、どんな記号と名前で呼ぶか」まで
- **View は Repository を直接触らない。** アプリ側は `TaskStore` が台帳を包む
- **集計は `CollectTasks.run()` だけを通る。** 表示側に集計を書かない
- **人に見せる言葉をコードに直接書かない。** `Localized.text("…")` で引く。
  訳文は `Sources/ProctorKit/Resources/{en,ja}.lproj/Localizable.strings` にあり、
  **鍵は必ず両方に足す**（片方にしか無い鍵は、もう片方の言語では鍵がそのまま出る）。
  `Localized` を3層のどれにも入れていないのは、言葉がどの層からも要るものであり、
  引くだけで何も決めないため

## 変更後の確認

`scripts/baseline.sh` で振る舞いのスナップショットを取り、前後で見比べる。
使い捨ての git リポジトリと台帳を相手にするので、実際の台帳には触らない。

```bash
scripts/baseline.sh before   # 変更前
scripts/baseline.sh after    # 変更後
diff -u /tmp/proctor-baseline/{before,after}.txt
```

アプリの見た目を変えたときは `scripts/install.sh` で入れ直して実機で確かめる。


# Local Knowledge Base
@.knowledge/lk-instructions.md
