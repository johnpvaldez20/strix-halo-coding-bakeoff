#!/usr/bin/env python3
"""Delete .aider.results.json files that only record a crash ("exception" key)
or are unreadable, so `benchmark.py --cont` re-runs those exercises.
Exercises that completed normally (pass or fail) are left alone."""
import json
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
removed = 0
for f in run_dir.glob("*/exercises/practice/*/.aider.results.json"):
    try:
        data = json.loads(f.read_text())
        crashed = (not data) or ("exception" in data and "tests_outcomes" not in data)
    except (json.JSONDecodeError, OSError):
        crashed = True
    if crashed:
        f.unlink()
        removed += 1
print(f"purge_exceptions: removed {removed} crashed result(s) in {run_dir}")
