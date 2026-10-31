#!/usr/bin/env python3
"""Copy results/custom/<model>/project into results/custom-blind/<letter>/ in random order.

  anonymize.py KIT_DIR model1 model2 ...

The mapping goes to results/custom-mapping.json (outside the blind folder).
"""
import hashlib
import json
import os
import random
import re
import shutil
import string
import sys
from datetime import datetime, timezone
from pathlib import Path

kit = Path(sys.argv[1])
models = sys.argv[2:]
res = kit / "results"
blind = res / "custom-blind"
mapping_file = res / "custom-mapping.json"

if (blind.exists() or mapping_file.exists()) and not os.environ.get("FORCE"):
    sys.exit(f"{blind} or {mapping_file} already exists; env FORCE=1 to overwrite (new random mapping)")
present = [m for m in models if (res / "custom" / m / "project").is_dir()]
missing = sorted(set(models) - set(present))
if missing:
    print(f"warning: no extracted project for {', '.join(missing)}; they are left out", file=sys.stderr)
if len(present) < 2:
    sys.exit("need at least 2 extracted projects")
if blind.exists():
    shutil.rmtree(blind)
blind.mkdir(parents=True)

order = present[:]
random.SystemRandom().shuffle(order)
letters = string.ascii_uppercase[: len(order)]
mapping, hashes = {}, {}
leak = re.compile(r"qwen|ornith|minimax|unsloth|alibaba|deepseek|anthropic|openai|claude|gpt-", re.I)
for letter, m in zip(letters, order):
    dst = blind / letter
    shutil.copytree(res / "custom" / m / "project", dst, ignore=shutil.ignore_patterns("target"))
    mapping[letter] = m
    h = hashlib.sha256()
    for f in sorted(p for p in dst.rglob("*") if p.is_file()):
        h.update(str(f.relative_to(dst)).encode() + b"\0" + f.read_bytes())
        if leak.search(f.read_text(errors="ignore")):
            print(f"warning: {letter}/{f.relative_to(dst)} mentions a model or vendor name; "
                  "edit it by hand before judging if it identifies the author", file=sys.stderr)
    hashes[letter] = h.hexdigest()

for name in ("prompt.md", "judge-prompt.md", "run-checks.sh", "checks.Dockerfile"):
    shutil.copy2(kit / "custom" / name, blind / name)
shutil.copy2(kit / "custom" / "BLIND-README.md", blind / "README.md")
shutil.copytree(kit / "custom" / "hidden-tests", blind / "hidden-tests")
(blind / ".gitignore").write_text("target/\nchecks/work/\n")

mapping_file.write_text(json.dumps({
    "created_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "mapping": mapping,
    "sha256": hashes,
}, indent=2) + "\n")
mapping_file.chmod(0o600)
print(f"blind entries: {', '.join(letters)} in {blind}")
print(f"mapping (do not show the judge): {mapping_file}")
