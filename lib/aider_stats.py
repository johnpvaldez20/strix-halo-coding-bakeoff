#!/usr/bin/env python3
"""Aider Polyglot result collection.

  aider_stats.py run RUN_DIR --model NAME --out DIR [--languages rust,java] [--num-tests N] [--meta k=v ...]
      Reads RUN_DIR/*/exercises/practice/*/.aider.results.json, writes DIR/stats.json and
      DIR/per_exercise.csv. Exit 0 if every expected exercise finished, 3 if not.

  aider_stats.py summary RESULTS_DIR
      Combines RESULTS_DIR/*/stats.json into RESULTS_DIR/summary.md and summary.csv.

Pass-rate math follows aider's benchmark.py summarize_results(): an exercise that
passes on try k counts as passed for pass_rate_k and every later try. Denominator
is the number of finished exercises (crash records excluded); a run with
finished < expected is flagged INCOMPLETE.
"""
import argparse
import csv
import json
import sys
from collections import defaultdict
from pathlib import Path

COUNTERS = [
    ("error_outputs", "num_error_outputs"),
    ("num_malformed_responses", "num_malformed_responses"),
    ("user_asks", "num_user_asks"),
    ("exhausted_context_windows", "num_exhausted_context_windows"),
    ("test_timeouts", "test_timeouts"),
    ("lazy_comments", "lazy_comments"),
    ("syntax_errors", "syntax_errors"),
    ("indentation_errors", "indentation_errors"),
    ("prompt_tokens", "prompt_tokens"),
    ("completion_tokens", "completion_tokens"),
]


def langs_of(arg):
    return [x.strip().lower() for x in arg.split(",") if x.strip()] if arg else []


def collect(run_dir: Path, languages, num_tests):
    all_ex = sorted(p for p in run_dir.glob("*/exercises/practice/*") if p.is_dir())
    if languages:
        all_ex = [p for p in all_ex if p.parts[-4].lower() in languages]
    expected = len(all_ex)
    if num_tests and num_tests > 0:
        expected = min(expected, num_tests)
    rows, crashed = [], []
    for ex in all_ex:
        f = ex / ".aider.results.json"
        if not f.exists():
            continue
        try:
            r = json.loads(f.read_text())
        except (json.JSONDecodeError, OSError):
            crashed.append(f"{ex.parts[-4]}/{ex.name}")
            continue
        if not r or "tests_outcomes" not in r:
            crashed.append(f"{ex.parts[-4]}/{ex.name}")
            continue
        r["_lang"] = ex.parts[-4]
        r["_name"] = ex.name
        rows.append(r)
    return expected, rows, crashed


def stats_for(rows, tries):
    s = {"completed": len(rows)}
    passed = [0] * tries
    for r in rows:
        outc = r.get("tests_outcomes") or []
        if outc and outc[-1]:
            for i in range(len(outc) - 1, tries):
                passed[i] += 1
    n = len(rows) or 1
    for i in range(tries):
        s[f"pass_num_{i+1}"] = passed[i]
        s[f"pass_rate_{i+1}"] = round(100.0 * passed[i] / n, 1) if rows else None
    malformed_cases = sum(1 for r in rows if r.get("num_malformed_responses"))
    s["num_with_malformed_responses"] = malformed_cases
    s["percent_cases_well_formed"] = round(100.0 * (1 - malformed_cases / n), 1) if rows else None
    for out_key, in_key in COUNTERS:
        s[out_key] = sum(int(r.get(in_key, 0) or 0) for r in rows)
    dur = sum(float(r.get("duration", 0) or 0) for r in rows)
    s["total_hours"] = round(dur / 3600, 2)
    s["seconds_per_case"] = round(dur / n, 1) if rows else None
    return s


def cmd_run(a):
    run_dir = Path(a.run_dir)
    languages = langs_of(a.languages)
    expected, rows, crashed = collect(run_dir, languages, a.num_tests)
    tries = max([len(r.get("tests_outcomes") or []) for r in rows] + [a.tries])
    s = {
        "model": a.model,
        "run_dir": run_dir.name,
        "languages": ",".join(languages) or "all",
        "expected": expected,
        "crashed": len(crashed),
        "crashed_exercises": crashed,
        "tries": tries,
    }
    s.update(stats_for(rows, tries))
    s["complete"] = s["completed"] >= expected and expected > 0
    by_lang = defaultdict(list)
    for r in rows:
        by_lang[r["_lang"]].append(r)
    s["by_language"] = {
        lang: {k: v for k, v in stats_for(rs, tries).items()
               if k in ("completed",) or k.startswith("pass_rate") or k == "percent_cases_well_formed"}
        for lang, rs in sorted(by_lang.items())
    }
    variants = defaultdict(set)
    for r in rows:
        for k in ("model", "edit_format", "commit_hash"):
            if r.get(k):
                variants[k].add(str(r[k]))
    s["aider_variants"] = {k: sorted(v) for k, v in variants.items()}
    for kv in a.meta or []:
        k, _, v = kv.partition("=")
        s[k] = v
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "stats.json").write_text(json.dumps(s, indent=2) + "\n")
    with open(out / "per_exercise.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["language", "exercise", "passed", "passed_on_try", "tests_outcomes",
                    "malformed_responses", "error_outputs", "exhausted_context_windows",
                    "test_timeouts", "duration_s", "completion_tokens"])
        for r in sorted(rows, key=lambda r: (r["_lang"], r["_name"])):
            outc = r.get("tests_outcomes") or []
            ok = bool(outc and outc[-1])
            w.writerow([r["_lang"], r["_name"], int(ok), len(outc) if ok else "",
                        "".join("P" if o else "F" for o in outc),
                        r.get("num_malformed_responses", 0), r.get("num_error_outputs", 0),
                        r.get("num_exhausted_context_windows", 0), r.get("test_timeouts", 0),
                        round(float(r.get("duration", 0) or 0), 1), r.get("completion_tokens", 0)])
        for c in crashed:
            lang, name = c.split("/", 1)
            w.writerow([lang, name, "", "", "CRASH", "", "", "", "", "", ""])
    pr = " ".join(f"pass_rate_{i+1}={s.get(f'pass_rate_{i+1}')}" for i in range(tries))
    print(f"{a.model}: {s['completed']}/{expected} finished, {len(crashed)} crashed, {pr}, "
          f"well_formed={s['percent_cases_well_formed']}")
    return 0 if s["complete"] else 3


SUMMARY_COLS = [
    ("model", "model"), ("desc", "build"), ("languages", "languages"),
    ("completed", "finished"), ("expected", "expected"), ("crashed", "crashed"),
    ("pass_rate_1", "pass_rate_1 %"), ("pass_rate_2", "pass_rate_2 %"),
    ("pass_num_1", "pass_num_1"), ("pass_num_2", "pass_num_2"),
    ("percent_cases_well_formed", "well_formed %"),
    ("error_outputs", "error_outputs"), ("num_malformed_responses", "malformed_responses"),
    ("exhausted_context_windows", "context_exhausted"), ("test_timeouts", "test_timeouts"),
    ("user_asks", "user_asks"), ("lazy_comments", "lazy_comments"),
    ("seconds_per_case", "s/exercise"), ("total_hours", "hours"),
    ("completion_tokens", "completion_tokens"), ("sampling", "sampling"),
    ("edit_format", "edit_format"), ("ctx", "ctx"),
]


def cmd_summary(a):
    root = Path(a.results_dir)
    stats = []
    for f in sorted(root.glob("*/stats.json")):
        stats.append(json.loads(f.read_text()))
    if not stats:
        print("no results/*/stats.json found", file=sys.stderr)
        return 1
    stats.sort(key=lambda s: -(s.get("pass_rate_2") or s.get("pass_rate_1") or 0))
    with open(root / "summary.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow([k for k, _ in SUMMARY_COLS] + ["complete"])
        for s in stats:
            w.writerow([s.get(k, "") for k, _ in SUMMARY_COLS] + [s.get("complete")])
    langs = sorted({lang for s in stats for lang in s.get("by_language", {})})
    lines = ["# Aider Polyglot results", ""]
    lines.append("| " + " | ".join(h for _, h in SUMMARY_COLS) + " |")
    lines.append("|" + "---|" * len(SUMMARY_COLS))
    for s in stats:
        cells = []
        for k, _ in SUMMARY_COLS:
            v = s.get(k, "")
            if k == "model" and not s.get("complete"):
                v = f"{v} (INCOMPLETE)"
            cells.append(str(v))
        lines.append("| " + " | ".join(cells) + " |")
    if langs:
        lines += ["", "## pass_rate_2 by language (finished exercises)", ""]
        lines.append("| model | " + " | ".join(langs) + " |")
        lines.append("|---|" + "---|" * len(langs))
        for s in stats:
            bl = s.get("by_language", {})
            row = []
            for lang in langs:
                d = bl.get(lang)
                last = f"pass_rate_{s.get('tries', 2)}"
                row.append(f"{d.get(last)} ({d.get('completed')})" if d else "-")
            lines.append(f"| {s['model']} | " + " | ".join(row) + " |")
    lines += [
        "",
        "pass_rate_1: solved on the first attempt. pass_rate_2: solved after seeing the failing",
        "test output once. Rows marked INCOMPLETE did not finish every expected exercise and are",
        "not directly comparable. Each model ran with its vendor-recommended sampling (column",
        "`sampling`), same edit format, same context, same tries.",
    ]
    (root / "summary.md").write_text("\n".join(lines) + "\n")
    print((root / "summary.md").read_text())
    return 0


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("run_dir")
    r.add_argument("--model", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--languages", default="")
    r.add_argument("--num-tests", type=int, default=0)
    r.add_argument("--tries", type=int, default=2)
    r.add_argument("--meta", action="append")
    s = sub.add_parser("summary")
    s.add_argument("results_dir")
    a = p.parse_args()
    return cmd_run(a) if a.cmd == "run" else cmd_summary(a)


if __name__ == "__main__":
    sys.exit(main())
