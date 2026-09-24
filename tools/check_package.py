#!/usr/bin/env python3
"""Check that the release ZIP can load every file listed by its TOC/XML."""

import os
import posixpath
import re
import zipfile

from package import NAME, ROOT, version

archive = f"{ROOT}/dist/{NAME}-{version()}.zip"
prefix = NAME + "/"
with zipfile.ZipFile(archive) as package:
    files = set(package.namelist())
    toc = prefix + NAME + ".toc"
    assert toc in files, f"missing {toc}"
    pending = [toc]
    while pending:
        path = pending.pop()
        text = package.read(path).decode("utf-8")
        if path.endswith(".toc"):
            refs = [line.strip() for line in text.splitlines()
                    if line.strip() and not line.lstrip().startswith("#")
                    and line.strip().lower().endswith((".lua", ".xml"))]
        else:
            refs = re.findall(r'<(?:Script|Include)\s+file="([^"]+)"', text, re.I)
        for ref in refs:
            target = posixpath.normpath(posixpath.join(posixpath.dirname(path), ref.replace("\\", "/")))
            assert target in files, f"{path} references missing {target}"
            if target.endswith(".xml"):
                pending.append(target)
    for path in files:
        assert path.startswith(prefix), f"file outside addon folder: {path}"
        assert not path.startswith((prefix + "tools/", prefix + "guides-src/", prefix + "data-src/")), path
    if os.path.isfile(os.path.join(ROOT, "LICENSE")):
        assert prefix + "LICENSE" in files, "LICENSE not included in release ZIP"
print(f"OK: {archive} contains all TOC/XML references and no development sources")
