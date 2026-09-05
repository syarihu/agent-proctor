#!/bin/bash
# 多言語リソースおよびドキュメントの整合性を検証する。
#
# 英語が正本で日本語がその訳という運用ルールに基づき、
# キー抜けやファイル欠落を検査する。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/check-l10n.py"
