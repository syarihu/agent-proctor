#!/bin/bash
# ローカル署名用の自己署名証明書を作る。一度作れば以降は不要。
#
# なぜ要るか: オートメーション (Apple Events) の許可は「バンドルID + コード署名」に
# 紐づく。アドホック署名だと署名の中身がビルドのたびに変わるため、そのたびに
# iTerm2 の操作許可を聞かれ直す。安定した署名 ID があれば初回の1度で済む。
#
# 信頼設定 (add-trusted-cert) はしない。codesign は信頼されていない自己署名でも
# 署名に使えるし、TCC が見るのは署名の中身であって信頼の可否ではない。
# 信頼設定には管理者認証が要るので、要らないものは求めない。
set -euo pipefail

NAME="${PROCTOR_CERT_NAME:-Proctor Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# -v を付けると信頼済みのものしか出ない。信頼はしない方針なので付けない
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "すでにあります: $NAME"
    echo "署名するとき (scripts/install.sh・sign-app.sh) はこれが使われます。"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Security framework は空パスワードの PKCS12 を読めないので、使い捨てを噛ませる
PASS="proctor-$RANDOM$RANDOM"

echo "==> 鍵と証明書を作る"
# macOS 同梱の LibreSSL を明示して使う。Homebrew の OpenSSL 3 が作る PKCS12 は
# 既定の MAC が新しすぎて Security framework が読めない
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "keyUsage=critical,digitalSignature" 2>/dev/null

/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout "pass:$PASS" 2>/dev/null

echo "==> キーチェーンに入れる"
# -T で codesign から鍵を使えるようにする
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

echo
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "できました: $NAME"
    echo
    echo "「この証明書は信頼されていません」と出ますが、それで構いません。"
    echo "codesign は信頼の有無を問わず署名に使えます。"
    echo
    # ソースツリーから走らせたのか、Homebrew が libexec に置いた物を走らせたのかで
    # 次の一手が変わる。Package.swift の有無で見分ける
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$HERE/../Package.swift" ]; then
        echo "次は scripts/install.sh を実行してください。"
    else
        echo "次は署名をやり直してください。Homebrew から入れた場合は:"
        echo "  brew postinstall agent-proctor"
    fi
else
    echo "証明書を作れませんでした。" >&2
    exit 1
fi
