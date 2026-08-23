#!/bin/bash
# Agent Proctor.app を組み立てて /Applications に置き、CLI へのリンクを張る。
#
# SwiftPM は .app を作らないので、実行ファイルを2つ焼いてからここで包む。
# CLI をバンドルの中に同梱するのは、配る物を1つにするため。
# ~/bin/proctor はその中身を指すシンボリックリンクになる。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Agent Proctor"
BUNDLE_ID="net.syarihu.proctor"
VERSION="1.0.0"

DEST="${PROCTOR_INSTALL_DIR:-/Applications}"
APP="$DEST/$APP_NAME.app"
CLI_LINK="${PROCTOR_CLI_LINK:-$HOME/bin/proctor}"

# 署名の身元。安定した ID があるとオートメーションの許可が1度で済む。
# 無ければアドホック署名にするが、その場合はビルドのたびに許可を聞かれる
# (許可は「バンドルID + 署名の中身」に紐づき、アドホックだと毎回変わるため)
CERT_NAME="${PROCTOR_CERT_NAME:-Proctor Local Signing}"
if [ -n "${PROCTOR_SIGN_ID:-}" ]; then
    SIGN_ID="$PROCTOR_SIGN_ID"
# -v を付けると信頼済みしか出ない。自己署名は信頼していないので付けない
elif security find-identity -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    SIGN_ID="$CERT_NAME"
else
    SIGN_ID="-"
fi

echo "==> ビルド (release)"
cd "$ROOT"
swift build -c release --product proctor
swift build -c release --product ProctorApp
BIN="$(swift build -c release --show-bin-path)"

echo "==> $APP を組み立て"
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

echo "==> 署名 (identity: $SIGN_ID)"
# 内側から順に署名する (--deep は署名時には非推奨)。
# アプリ本体にだけ entitlement を渡す。CLI は Apple Event を投げないので要らない
codesign --force --options runtime --sign "$SIGN_ID" \
    "$APP/Contents/Helpers/proctor" 2>&1 | sed 's/^/    /'
codesign --force --options runtime --sign "$SIGN_ID" \
    --entitlements "$ROOT/Resources/Proctor.entitlements" "$APP" 2>&1 | sed 's/^/    /'
if [ "$SIGN_ID" = "-" ]; then
    echo "    注意: アドホック署名です。ビルドのたびにオートメーションの許可を聞かれます。"
    echo "          scripts/create-signing-cert.sh を一度実行すると解消します。"
fi

echo "==> CLI のリンク: $CLI_LINK"
mkdir -p "$(dirname "$CLI_LINK")"
ln -sfn "$APP/Contents/Helpers/proctor" "$CLI_LINK"

echo
echo "完了しました。"
echo "  アプリ : $APP"
echo "  CLI    : $CLI_LINK -> $(readlink "$CLI_LINK")"
echo
echo "起動するには: open -a \"$APP_NAME\""
echo "初回はメニューバーから「設定…」を開いて「ログイン時に起動」を入れておくと、次からは自動で立ち上がります。"
