#!/usr/bin/env python3
"""
proctor 用の iTerm2 hotkey window プロファイルを作成・更新するスクリプト。

Window Style: No title bar (Window Type: 12)
Pin hotkey window: OFF (HotKey Window AutoHides: True)
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
    existing = next((b for b in bookmarks if b.get("Name") == "proctor"), None)

    if existing:
        print("Profile 'proctor' already exists. Updating settings...")
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
    target["HotKey Window Floats"] = True
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
