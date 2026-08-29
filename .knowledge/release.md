---
keywords: [formula, gh-release, homebrew, release, sha256, tag, tap, version, リリース, 配布]
category: context
---

# agent-proctor のリリース手順

## Entry: agent-proctor のリリース手順 (v0.3.0 で再実施)
keywords: [formula, gh-release, homebrew, release, sha256, tag, tap, version, リリース, 配布]
uid: 694a2494ec86

v0.2.0 / v0.3.0 の2回で実際に回した手順。CI は無いので全部手作業。

## 手順
1. `swift build -c release` でビルドが通ることを確認 (CI が無いのでここが唯一の関門)
2. リリース内容の棚卸し: `git log --oneline vX.Y.Z..HEAD` と
   `gh pr list --state merged --json number,title,mergedAt` を突き合わせる。
   PR 本文の Summary/Details がそのままリリースノートの素材になる
3. `VERSION` を新しい版に書き換える。ここが版の唯一の出どころで、
   `scripts/build-app.sh` が CFBundleShortVersionString / CFBundleVersion に流し込む
   (`Sources/ProctorKit/Repository/AppVersion.swift` のコメント参照)
4. main に直接コミット。文体は "Start at 0.1.0" / "Move on to 0.2.0" / "Move on to 0.3.0"。
   バージョンバンプで PR は切らない。
   **co-author トレーラーは付けない** (132コミット中0件。リポジトリの慣習)
5. `git tag -a vX.Y.Z -m "vX.Y.Z"` して main とタグを push
6. `gh release create vX.Y.Z --verify-tag --title "vX.Y.Z - <見出し>" -F <notes>` でリリース。
   本文は英語。体裁は絵文字見出し (✨ New / 🐛 Fixes / 🔧 Internal) + Installation +
   Full Changelog の compare リンク + Documentation リンク。
   タイトルは "v0.2.0 - Pull request numbers on session rows" のように内容の見出しを付ける。
   **リポジトリ内部の作法の変更 (CLAUDE.md のルール追加など) はノートに載せない** — 使う人に関係ない
7. tarball の sha256 を取る:
   `curl -sL -o x.tar.gz https://github.com/syarihu/agent-proctor/archive/refs/tags/vX.Y.Z.tar.gz && shasum -a 256 x.tar.gz`
8. tap の formula を更新。ローカルの実体は
   `/opt/homebrew/Library/Taps/syarihu/homebrew-tap` (= `brew --repo syarihu/tap`)。
   ここで直接 url と sha256 を書き換えてコミット・push すればよい。clone し直す必要はない。
   コミット文の慣習は "Update agent-proctor to vX.Y.Z"
9. push 前に `brew audit --strict --online syarihu/tap/agent-proctor`。
   無出力 (exit 0) なら通っている。--online なので url 到達性と sha256 もここで確かめられる

## 注意
- `VERSION` と formula のタグを揃える仕組みは無い。人が守る
- formula 本体 (install/post_install/caveats) は url と sha256 以外いじらないのが通常。
  いじる必要があるかは `git diff --name-only vX.Y.Z..vA.B.C -- scripts/ Resources/ Package.swift`
  で判定できる。formula が触るのは build-app.sh / sign-app.sh / create-signing-cert.sh /
  Resources/Proctor.entitlements の4つだけなので、そこに出てこなければ url+sha256 だけでよい
  (v0.3.0 では baseline.sh と switch-cli.sh しか変わっておらず、formula 本体は無傷だった)
- formula の push は GitHub Release より先でも問題ない。formula が指すのは
  `archive/refs/tags/` の自動生成 tarball で、Release のアセットではないため
- brew の中では安定した自己署名で codesign できずアドホックになるので、
  アップグレード後は Apple Event の許可ダイアログが 1 回出る。これは既知で仕様どおり
  (詳細は「検証済み formula: agent-proctor (Homebrew)」)
