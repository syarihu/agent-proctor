#!/bin/bash
# Agent Proctor.app を組み立てる。置くのも署名するのも呼ぶ側の仕事。
#
# 組み立てと署名を分けているのは Homebrew の都合。
# formula は def install の段階ではログインキーチェーンを読めない
# (Homebrew の sandbox が ~/Library/Keychains を読み取り拒否する) ので、
# 安定した自己署名で署名できるのは post_install に入ってからになる。
# 分けておけば install.sh も formula も同じ物を使える。
#   scripts/install.sh   → build-app.sh + sign-app.sh を続けて呼ぶ
#   formula def install  → build-app.sh (Cellar へ組み立てる)
#   formula post_install → sign-app.sh
#
# 使い方:
#   scripts/build-app.sh [置き場]      置き場の既定は .build/app
#
# 進み具合は stderr、組み上がった .app のパスだけを stdout に出す。
# 呼ぶ側が APP="$(scripts/build-app.sh "$DEST")" で受け取れるようにするため
# (バンドル名を呼ぶ側にも書くと、変えたときに片方だけ直す事故が起きる)。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Agent Proctor"
BUNDLE_ID="net.syarihu.proctor"
# 版はここだけに書く。Homebrew の formula が指すタグと必ず揃えること
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

DEST="${1:-$ROOT/.build/app}"
APP="$DEST/$APP_NAME.app"

echo "==> ビルド (release)" >&2
cd "$ROOT"
# --disable-sandbox は SwiftPM 自身の sandbox を切るもの。
# Homebrew の sandbox の中では入れ子になって動かないため要る。
# このパッケージは依存もプラグインも持たないので、切っても失うものは無い
swift build -c release --disable-sandbox --product proctor >&2
swift build -c release --disable-sandbox --product ProctorApp >&2
BIN="$(swift build -c release --disable-sandbox --show-bin-path)"

echo "==> $APP を組み立て" >&2
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

cp "$BIN/ProctorApp" "$APP/Contents/MacOS/$APP_NAME"
# CLI は Helpers に置く。macOS のファイルシステムは大文字小文字を区別しないため、
# MacOS/ に proctor を置くとアプリ本体の Proctor と同じ名前になって潰し合う
cp "$BIN/proctor" "$APP/Contents/Helpers/proctor"
# Finder や Spotlight、システム設定に出るアイコン。Dock には出ないアプリなので
# 目にする機会は多くないが、無いと白紙の書類の絵になる
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# 訳文。アプリ本体と同梱の CLI が同じ物を読む。
# ここに .lproj が無いと macOS は「訳のあるアプリ」と見なさず、
# システム設定の「アプリごとの言語」にこのアプリが出てこない。
# SwiftPM が作る .bundle をそのまま入れないのは、.app の作法に合わないため
# (Helpers 側に .lproj を置くのも駄目。codesign が入れ子のバンドルと解釈して失敗する)
cp -R "$ROOT"/Sources/ProctorKit/Resources/*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <!-- 拡張子は書かない。書いても動くが、Apple の作法に合わせておく -->
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- 端末に寄り添う道具なので Dock には出さない -->
    <key>LSUIElement</key><true/>
    <!-- 訳が無い言語ではここが出る。日本語などの訳は各 .lproj の InfoPlist.strings -->
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Agent Proctor controls iTerm2 to move you to an open tab and to open a task in a new tab.</string>
</dict>
</plist>
PLIST

echo "$APP"
