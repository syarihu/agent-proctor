#!/bin/bash
# 組み上がった .app に署名する。証明書があればそれで、無ければアドホック。
#
# build-app.sh から切り離してあるのは Homebrew の都合 (理由は build-app.sh の頭に書いた)。
# 入れ直したあと許可を聞かれ直したときは、これだけを叩けば直せる。
#
# 使い方:
#   scripts/sign-app.sh "/Applications/Agent Proctor.app"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP="${1:-}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "使い方: $(basename "$0") <Agent Proctor.app のパス>" >&2
    exit 1
fi

# entitlement の在り処。formula の post_install から呼ぶときはソースツリーがもう無いので、
# スクリプトの隣 (Homebrew なら libexec) も見る
ENTITLEMENTS="${PROCTOR_ENTITLEMENTS:-}"
if [ -z "$ENTITLEMENTS" ]; then
    for candidate in "$HERE/Proctor.entitlements" "$ROOT/Resources/Proctor.entitlements"; do
        if [ -f "$candidate" ]; then
            ENTITLEMENTS="$candidate"
            break
        fi
    done
fi
if [ ! -f "$ENTITLEMENTS" ]; then
    echo "entitlement が見つかりません。PROCTOR_ENTITLEMENTS で指定してください。" >&2
    exit 1
fi

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

echo "==> 署名 (identity: $SIGN_ID)" >&2
# 内側から順に署名する (--deep は署名時には非推奨)。
# アプリ本体にだけ entitlement を渡す。CLI は Apple Event を投げないので要らない
codesign --force --options runtime --sign "$SIGN_ID" \
    "$APP/Contents/Helpers/proctor" 2>&1 | sed 's/^/    /' >&2
codesign --force --options runtime --sign "$SIGN_ID" \
    --entitlements "$ENTITLEMENTS" "$APP" 2>&1 | sed 's/^/    /' >&2
if [ "$SIGN_ID" = "-" ]; then
    # 証明書を作るスクリプトの在り処も、entitlement と同じ理由で決め打ちにできない。
    # Homebrew から入れた場合はソースツリーが無く、libexec に置かれている
    CERT_SCRIPT="$HERE/create-signing-cert.sh"
    [ -f "$CERT_SCRIPT" ] || CERT_SCRIPT="$ROOT/scripts/create-signing-cert.sh"
    echo "    注意: アドホック署名です。入れ直すたびにオートメーションの許可を聞かれます。" >&2
    echo "          次の2つを順に実行すると解消します。" >&2
    echo "            \"$CERT_SCRIPT\"" >&2
    # $0 は呼ばれ方次第で相対になる。そのまま案内すると、
    # 別のディレクトリで貼り直したときに見つからない
    echo "            \"$HERE/$(basename "$0")\" \"$APP\"" >&2
fi
