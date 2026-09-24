#!/usr/bin/env python3
"""A collected report must not retain a SavedVariables account folder name."""

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
import collect_reports  # noqa: E402

with tempfile.TemporaryDirectory() as tmp:
    collect_reports.OUT = os.path.join(tmp, "reports.json")
    with open(collect_reports.OUT, "w", encoding="utf-8") as fh:
        json.dump([{"key": "old", "file": "account-label", "guide": "G", "t": 1}], fh)
    collect_reports.foreverdb.load_saved_variables = lambda _: (
        {"reports": [{"t": 2, "guide": "G", "step": 1, "q": 42, "text": "bad step"}]}, {})
    sys.argv = ["collect_reports.py", os.path.join(tmp, "account-label", "SavedVariables", "ForeverGuide.lua")]
    assert collect_reports.main() == 0
    with open(collect_reports.OUT, encoding="utf-8") as fh:
        assert all("file" not in report for report in json.load(fh))
