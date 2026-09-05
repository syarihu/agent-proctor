#!/usr/bin/env python3
"""
多言語・対訳リソース整合性チェックスクリプト。

英語（正本）と日本語（訳）のリソースが常に 1:1 で揃っていることを検証する。
片方だけにキーやファイルが存在すると、実行時にキー名がそのまま画面に出たり、
エージェントへの手引きが欠落したりするため、CI およびローカルで事前に検知する。
"""

import os
import re
import sys
from collections import Counter
from pathlib import Path


def extract_strings_keys(file_path: Path):
    """
    .strings ファイルからキーとその行番号を抽出する。
    標準の .strings 形式 ("key" = "value";) を想定し、
    ブロックコメントおよび行コメントを除外した上でキーを収集する。
    """
    keys = []
    lines = file_path.read_text(encoding="utf-8").splitlines()
    in_block_comment = False

    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        # 複数行ブロックコメントの簡易処理
        if "/*" in stripped and "*/" not in stripped:
            in_block_comment = True
            continue
        if in_block_comment:
            if "*/" in stripped:
                in_block_comment = False
            continue
        if stripped.startswith("//") or stripped.startswith("/*"):
            continue

        # 行頭の "key" = を探す
        match = re.match(r'^\s*"([^"]+)"\s*=', line)
        if match:
            keys.append((match.group(1), i))

    return keys


def check_strings_pair(en_file: Path, ja_file: Path) -> list[str]:
    """
    en と ja の .strings ファイルを突き合わせ、キーの重複や過不足を報告する。
    どちらか片方にしか無いキーは未翻訳または正本の同期漏れを意味する。
    """
    errors = []
    if not en_file.exists():
        return [f"File not found: {en_file}"]
    if not ja_file.exists():
        return [f"File not found: {ja_file}"]

    en_keys = extract_strings_keys(en_file)
    ja_keys = extract_strings_keys(ja_file)

    # 重複キーの検査: 同じキーが複数回定義されていると予期しない値で上書きされる恐れがある
    en_counts = Counter(k for k, _ in en_keys)
    ja_counts = Counter(k for k, _ in ja_keys)

    for key, count in en_counts.items():
        if count > 1:
            errors.append(f"{en_file}: duplicate key '{key}' found {count} times")
    for key, count in ja_counts.items():
        if count > 1:
            errors.append(f"{ja_file}: duplicate key '{key}' found {count} times")

    en_set = set(en_counts.keys())
    ja_set = set(ja_counts.keys())

    missing_in_ja = en_set - ja_set
    missing_in_en = ja_set - en_set

    for key in sorted(missing_in_ja):
        errors.append(f"Key '{key}' exists in {en_file.name} but missing in {ja_file.name}")
    for key in sorted(missing_in_en):
        errors.append(f"Key '{key}' exists in {ja_file.name} but missing in {en_file.name}")

    return errors


def check_markdown_resources(en_dir: Path, ja_dir: Path) -> list[str]:
    """
    skill-*.md や setup-*.md などの Markdown 手引きが en と ja で 1:1 に揃っているか検証する。
    proctor skill / proctor setup は Localized を通じて読み出すため、
    片方しか無いと片方の言語環境のエージェントで手引きが出力できなくなる。
    """
    errors = []
    en_files = {p.name for p in en_dir.glob("*.md")}
    ja_files = {p.name for p in ja_dir.glob("*.md")}

    missing_in_ja = en_files - ja_files
    missing_in_en = ja_files - en_files

    for name in sorted(missing_in_ja):
        errors.append(f"Markdown file '{name}' exists in {en_dir.name} but missing in {ja_dir.name}")
    for name in sorted(missing_in_en):
        errors.append(f"Markdown file '{name}' exists in {ja_dir.name} but missing in {en_dir.name}")

    return errors


def check_root_documents(root: Path) -> list[str]:
    """
    README.md と README.ja.md の対比および、日本語版の正本表記ルールを検証する。
    AGENTS.md / CLAUDE.md に「README.ja.md の冒頭には『英語版が正本』と書いておく」と明記されているため。
    """
    errors = []
    en_readme = root / "README.md"
    ja_readme = root / "README.ja.md"

    if not en_readme.exists():
        errors.append("README.md (English canonical) is missing")
    if not ja_readme.exists():
        errors.append("README.ja.md (Japanese translation) is missing")
    else:
        content = ja_readme.read_text(encoding="utf-8")
        # 冒頭部分で正本について言及されているか
        top_lines = "\n".join(content.splitlines()[:20])
        if "英語版が正本" not in top_lines:
            errors.append("README.ja.md must state '英語版が正本' near the beginning")

    return errors


def check_swift_key_references(root: Path, defined_keys: set[str]) -> list[str]:
    """
    Swift コード内で Localized.text("リテラル") 形式で参照されているキーが
    Localizable.strings に存在するか検証する。
    タイポなどで存在しないキーを叩くと、実行時にキー名がそのまま露出してしまう。
    動的生成されるキー（文字列補間を含むものなど）はスキップする。
    """
    errors = []
    sources_dir = root / "Sources"
    literal_pattern = re.compile(r'Localized\.text\(\s*"([a-zA-Z0-9_.-]+)"\s*[,)]')

    for swift_file in sources_dir.rglob("*.swift"):
        try:
            content = swift_file.read_text(encoding="utf-8")
        except Exception as e:
            errors.append(f"Failed to read {swift_file}: {e}")
            continue

        for match in literal_pattern.finditer(content):
            key = match.group(1)
            if key not in defined_keys:
                rel_path = swift_file.relative_to(root)
                errors.append(f"{rel_path}: Referenced key '{key}' is not defined in Localizable.strings")

    return errors


def main() -> int:
    # スクリプトの位置からリポジトリルートを特定する
    root = Path(__file__).resolve().parent.parent
    resources_dir = root / "Sources" / "Resources" / "Resources"
    en_dir = resources_dir / "en.lproj"
    ja_dir = resources_dir / "ja.lproj"

    all_errors = []

    # 1. Localizable.strings の検査
    all_errors.extend(check_strings_pair(en_dir / "Localizable.strings", ja_dir / "Localizable.strings"))

    # 2. InfoPlist.strings の検査
    all_errors.extend(check_strings_pair(en_dir / "InfoPlist.strings", ja_dir / "InfoPlist.strings"))

    # 3. Markdown リソースファイルの検査
    all_errors.extend(check_markdown_resources(en_dir, ja_dir))

    # 4. ルートドキュメントの検査
    all_errors.extend(check_root_documents(root))

    # 5. Swift コード内のキー参照の検査
    en_strings_file = en_dir / "Localizable.strings"
    if en_strings_file.exists():
        defined_keys = {k for k, _ in extract_strings_keys(en_strings_file)}
        all_errors.extend(check_swift_key_references(root, defined_keys))

    if all_errors:
        print("❌ Localization consistency check failed:", file=sys.stderr)
        for err in all_errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print("✅ All localization and document consistency checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
