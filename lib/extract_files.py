#!/usr/bin/env python3
"""Extract `=== FILE: path === ... === END FILE ===` blocks from a model answer.

  extract_files.py RESPONSE.md OUT_DIR

Falls back to "path line + fenced code block" if no markers are found.
Rejects absolute paths, '..', build.rs, proc-macro crates and Cargo `build =` keys,
and tests/hidden_suite.rs (reserved for the hidden tests). Writes OUT_DIR/../extract-report.txt.
"""
import re
import sys
from pathlib import Path, PurePosixPath

MARK = re.compile(r"^=== FILE: (?P<path>[^\n=]+?) ===[ \t]*\n(?P<body>.*?)^=== END FILE ===[ \t]*$", re.M | re.S)
FENCE_FALLBACK = re.compile(
    r"^(?:#+\s*|\*\*|`)?(?P<path>(?:Cargo\.toml|DESIGN\.md|README\.md|(?:src|tests|benches|examples)/[\w./-]+\.rs))(?:`|\*\*)?:?[ \t]*\n+"
    r"```[\w-]*[ \t]*\n(?P<body>.*?)^```[ \t]*$",
    re.M | re.S,
)


def safe(path: str):
    p = PurePosixPath(path.strip().strip("`").strip())
    if p.is_absolute() or ".." in p.parts or not p.parts:
        return None, "unsafe path"
    s = str(p)
    if p.name == "build.rs":
        return None, "build.rs not allowed"
    if s == "tests/hidden_suite.rs":
        return None, "reserved file name"
    return s, None


def strip_wrapping_fence(body: str) -> str:
    """Remove one code fence the model wrapped around a whole file despite instructions."""
    lines = body.split("\n")
    while lines and not lines[-1].strip():
        lines.pop()
    if len(lines) >= 2 and lines[0].startswith("```") and lines[-1].strip() == "```":
        lines = lines[1:-1]
    return "\n".join(lines) + "\n"


def main():
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    text = src.read_text(errors="replace")
    matches = list(MARK.finditer(text))
    mode = "markers"
    if not matches:
        matches = list(FENCE_FALLBACK.finditer(text))
        mode = "fallback-fenced"
    report, files = [f"mode: {mode}"], {}
    for m in matches:
        path, why = safe(m.group("path"))
        if not path:
            report.append(f"REJECTED {m.group('path')!r}: {why}")
            continue
        body = strip_wrapping_fence(m.group("body")) if mode == "markers" else m.group("body")
        if path in files:
            report.append(f"duplicate {path}: last one wins")
        files[path] = body
    cargo = files.get("Cargo.toml", "")
    if re.search(r"^\s*build\s*=", cargo, re.M) or re.search(r"proc-macro\s*=\s*true", cargo):
        report.append("REJECTED Cargo.toml: build script or proc-macro not allowed; Cargo.toml dropped")
        files.pop("Cargo.toml")
    out.mkdir(parents=True, exist_ok=True)
    for path, body in sorted(files.items()):
        dest = out / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(body)
        report.append(f"wrote {path} ({len(body.splitlines())} lines)")
    for need in ("Cargo.toml", "src/lib.rs"):
        if need not in files:
            report.append(f"MISSING {need}")
    (out.parent / "extract-report.txt").write_text("\n".join(report) + "\n")
    print("\n".join(report))
    return 0 if files else 2


if __name__ == "__main__":
    sys.exit(main())
