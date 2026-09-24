#!/usr/bin/env python3
"""
Zip the addon for distribution.

    python tools/package.py            -> dist/ForeverGuide-<version>.zip   (runtime files only)
    python tools/package.py --dev      -> also tools/, guides-src/, data-src/ (for contributors)

The version comes from ## Version in ForeverGuide.toc. The zip unpacks to
Interface\\AddOns\\ForeverGuide\\.
"""

import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
NAME = os.path.basename(ROOT)

RUNTIME_EXT = {".lua", ".xml", ".toc", ".tga", ".blp", ".md", ".txt"}
RUNTIME_DIRS = {"", "Data", "Guides", "Textures", "UI"}
DEV_DIRS = {"tools", "tools/test", "guides-src", "data-src"}
SKIP = {"dist", "__pycache__", ".git", "WTF"}


def version():
    with open(os.path.join(ROOT, NAME + ".toc"), "r", encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"##\s*Version:\s*(\S+)", line)
            if m:
                return m.group(1)
    return "0.0.0"


def main():
    dev = "--dev" in sys.argv
    ver = version()
    out_dir = os.path.join(ROOT, "dist")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, "%s-%s%s.zip" % (NAME, ver, "-dev" if dev else ""))
    n = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for dirpath, dirnames, filenames in os.walk(ROOT):
            rel = os.path.relpath(dirpath, ROOT).replace("\\", "/")
            rel = "" if rel == "." else rel
            dirnames[:] = [d for d in dirnames if d not in SKIP and not d.startswith(".")]
            allowed = rel in RUNTIME_DIRS or (dev and (rel in DEV_DIRS or rel.split("/")[0] in DEV_DIRS))
            if not allowed:
                continue
            for fn in sorted(filenames):
                ext = os.path.splitext(fn)[1].lower()
                if rel in RUNTIME_DIRS and ext not in RUNTIME_EXT and fn != "LICENSE" and not dev:
                    continue
                if fn.endswith(".pyc"):
                    continue
                src = os.path.join(dirpath, fn)
                z.write(src, NAME + "/" + (rel + "/" if rel else "") + fn)
                n += 1
    print("wrote %s (%d files, %.1f KB)" % (os.path.relpath(out, ROOT), n, os.path.getsize(out) / 1024))
    return 0


if __name__ == "__main__":
    sys.exit(main())
