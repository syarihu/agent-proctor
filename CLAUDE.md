# taskhub のルール

## 言語

| 対象 | 言語 |
| --- | --- |
| コミットメッセージ | **英語** |
| コード中のコメント | **日本語** |
| Pull Request のタイトル・本文 | 日本語 または 英語 |
| README.md | 英語（こちらが正本） |
| README.ja.md | 日本語（README.md の訳） |

コメントを日本語にしているのは、**なぜそう書いたのかを残すため**。
何をしているかはコードを読めば分かるので、コメントには
「なぜこうしたか」「そうしないと何が壊れるか」を書く。

コミットメッセージに `feat:` `fix:` `chore:` のような
Conventional Commits のプレフィックスは使わない。何をしたかを普通の文で書く。

## README を直すとき

`README.md`（英語）が正本で、`README.ja.md` はその訳。
**片方だけ直さない。** 内容がずれると、どちらが正しいのか分からなくなる。

## 設計

`TaskhubKit` は3層に分かれている。層をまたぐ変更をするときは、
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

## 変更したら

`scripts/baseline.sh` で振る舞いのスナップショットを取り、前後で見比べる。
使い捨ての git リポジトリと台帳を相手にするので、実際の台帳には触らない。

```bash
scripts/baseline.sh before   # 変更前
scripts/baseline.sh after    # 変更後
diff -u /tmp/taskhub-baseline/{before,after}.txt
```

アプリの見た目を変えたときは `scripts/install.sh` で入れ直して実機で確かめる。
