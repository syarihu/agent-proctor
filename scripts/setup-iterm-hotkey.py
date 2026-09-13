#!/usr/bin/env python3
"""
proctor 用の iTerm2 hotkey window プロファイルを作成・更新するスクリプト。

すでに hotkey を持っているプロファイルがあれば、名前が何であれそれを直す。

Window Style: No title bar (Window Type: 12)
Pin hotkey window: OFF (HotKey Window AutoHides: True)
Floating window: OFF (HotKey Window Floats: False)
  **浮かせない。浮いた hotkey window は焦点を取らないので、呼んだ直後に打てない。**
  一度は浮かせる設定にしていた。オフィス窓を通常より1段高いところに置いたせいで
  端末がその下に潜ったためで、こちら側の都合を iTerm2 の設定で埋め合わせていた。
  オフィス窓は通常の高さに戻したので、この設定は要らないどころか害になる。
"""

import plistlib
import subprocess
import sys
import uuid


def main():
    try:
        out = subprocess.check_output(["defaults", "export", "com.googlecode.iterm2", "-"])
        plist = plistlib.loads(out)
    except Exception as e:
        print(f"Error reading iTerm2 preferences: {e}", file=sys.stderr)
        return 1

    bookmarks = plist.get("New Bookmarks", [])

    # すでに hotkey window を持っているプロファイルがあれば、名前が何であれそれを直す。
    # 名前で "proctor" だけを探していた頃は、"Hotkey Window" のような別名で
    # 先に作ってあるプロファイルに一度も届かず、設定が入っていないのに
    # 入ったつもりになっていた (hotkey window が浮かず、オフィス窓の下に潜る)。
    existing = next((b for b in bookmarks if b.get("Has Hotkey")), None)
    if existing is None:
        existing = next((b for b in bookmarks if b.get("Name") == "proctor"), None)

    if existing:
        print(f"Updating the hotkey profile {existing.get('Name')!r}...")
        target = existing
    else:
        print("Creating profile 'proctor' based on Default profile...")
        default_bm = next((b for b in bookmarks if b.get("Name") == "Default"), None)
        if default_bm:
            target = dict(default_bm)
        else:
            target = {}
        target["Name"] = "proctor"
        target["Guid"] = str(uuid.uuid4())
        bookmarks.append(target)

    target["Window Type"] = 12  # No title bar
    target["Has Hotkey"] = True
    target["HotKey Window AutoHides"] = True
    target["HotKey Window Floats"] = False
    target["HotKey Window Reopens On Activation"] = False
    target["HotKey Window Dock Click Action"] = 0
    target["Space"] = -1

    plist["New Bookmarks"] = bookmarks

    try:
        p = subprocess.Popen(["defaults", "import", "com.googlecode.iterm2", "-"], stdin=subprocess.PIPE)
        p.communicate(plistlib.dumps(plist))
        if p.returncode == 0:
            print("Successfully updated iTerm2 preferences with 'proctor' profile.")
            return 0
        else:
            print("Failed to import iTerm2 preferences.", file=sys.stderr)
            return p.returncode
    except Exception as e:
        print(f"Error writing iTerm2 preferences: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
