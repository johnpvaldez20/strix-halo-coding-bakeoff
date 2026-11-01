#!/usr/bin/env python3
"""Timing charts for one model's Aider Polyglot run.

Usage:
    python3 lib/timing_charts.py results/<model>/per_exercise.csv [--out DIR] [--title NAME]

Reads per_exercise.csv (columns include language, exercise, passed,
passed_on_try, exhausted_context_windows, duration_s, completion_tokens)
and writes PNGs to results/<model>/charts/ (or --out):

    hours_by_language.png      total hours per language
    slowest_exercises.png      20 slowest exercises, coloured by outcome
    minutes_by_language.png    box plot of minutes per exercise by language
    duration_vs_tokens.png     duration against completion tokens

It also prints a short JSON summary (totals, top language, slowest
exercise, token/time correlation) to stdout. Requires matplotlib.
The CSV has no start times, so these charts show where time went,
not the order exercises ran in.
"""
import argparse
import csv
import json
import os
import statistics
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import Patch  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402

C_TRY1 = "#2e7d32"
C_TRY2 = "#f9a825"
C_FAIL = "#c62828"
C_BAR = "#1565c0"
DPI = 150


def load(path):
    rows = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            try:
                dur = float(r["duration_s"])
            except (KeyError, ValueError):
                continue
            rows.append({
                "language": r["language"],
                "exercise": r["exercise"],
                "passed": r.get("passed", "0") in ("1", "True", "true"),
                "try": int(float(r.get("passed_on_try") or 0)),
                "exhausted": int(float(r.get("exhausted_context_windows") or 0)),
                "minutes": dur / 60.0,
                "tokens": int(float(r.get("completion_tokens") or 0)),
            })
    if not rows:
        sys.exit(f"no usable rows in {path}")
    return rows


def outcome(r):
    if not r["passed"]:
        return "failed", C_FAIL
    if r["try"] == 1:
        return "passed on try 1", C_TRY1
    return "passed on try 2", C_TRY2


def style():
    plt.style.use("default")
    plt.rcParams.update({
        "figure.facecolor": "white",
        "axes.facecolor": "white",
        "axes.grid": True,
        "grid.color": "#e0e0e0",
        "axes.axisbelow": True,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "font.size": 11,
        "axes.titlesize": 14,
        "axes.titleweight": "bold",
    })


def by_language(rows):
    langs = {}
    for r in rows:
        langs.setdefault(r["language"], []).append(r)
    return langs


def chart_hours(rows, name, out):
    langs = by_language(rows)
    total_h = sum(r["minutes"] for r in rows) / 60
    order = sorted(langs, key=lambda l: sum(r["minutes"] for r in langs[l]), reverse=True)
    hours = [sum(r["minutes"] for r in langs[l]) / 60 for l in order]
    fig, ax = plt.subplots(figsize=(10, 5.5))
    bars = ax.bar(order, hours, color=C_BAR)
    top = max(hours)
    for b, l, h in zip(bars, order, hours):
        med = statistics.median(r["minutes"] for r in langs[l])
        ax.text(b.get_x() + b.get_width() / 2, h + top * 0.015,
                f"{h:.1f} h ({h / total_h:.0%})\n{len(langs[l])} exercises\nmedian {med:.0f} min",
                ha="center", va="bottom", fontsize=9.5)
    ax.set_ylim(0, top * 1.3)
    ax.set_ylabel("Total hours")
    ax.set_title(f"{name}: total time per language ({total_h:.1f} h, {len(rows)} exercises)")
    ax.grid(axis="x", visible=False)
    fig.tight_layout()
    fig.savefig(os.path.join(out, "hours_by_language.png"), dpi=DPI)
    plt.close(fig)


def chart_slowest(rows, name, out, n=20):
    top = sorted(rows, key=lambda r: r["minutes"], reverse=True)[:n][::-1]
    labels = [f'{r["language"]}/{r["exercise"]}' for r in top]
    fig, ax = plt.subplots(figsize=(10, 0.36 * len(top) + 1.8))
    colors = [outcome(r)[1] for r in top]
    ax.barh(labels, [r["minutes"] for r in top], color=colors)
    xmax = max(r["minutes"] for r in top)
    any_ex = False
    for i, r in enumerate(top):
        txt = f'{r["minutes"]:.0f} min'
        if r["exhausted"]:
            txt += "  ⚠ context exhausted"
            any_ex = True
        ax.text(r["minutes"] + xmax * 0.01, i, txt, va="center", fontsize=9)
    ax.set_xlim(0, xmax * 1.35)
    ax.set_xlabel("Minutes")
    ax.set_title(f"{name}: {len(top)} slowest exercises")
    ax.grid(axis="y", visible=False)
    handles = [Patch(color=C_TRY1, label="passed on try 1"),
               Patch(color=C_TRY2, label="passed on try 2"),
               Patch(color=C_FAIL, label="failed")]
    if any_ex:
        handles.append(Line2D([], [], linestyle="none", marker="$⚠$", color="black",
                              markersize=10, label="exhausted the context window"))
    ax.legend(handles=handles, loc="lower right", frameon=True)
    fig.tight_layout()
    fig.savefig(os.path.join(out, "slowest_exercises.png"), dpi=DPI)
    plt.close(fig)


def chart_box(rows, name, out):
    langs = by_language(rows)
    order = sorted(langs, key=lambda l: statistics.median(r["minutes"] for r in langs[l]),
                   reverse=True)
    data = [[r["minutes"] for r in langs[l]] for l in order]
    fig, ax = plt.subplots(figsize=(10, 5.5))
    bp = ax.boxplot(data, patch_artist=True, widths=0.6,
                    medianprops={"color": "black", "linewidth": 1.5},
                    flierprops={"marker": "o", "markersize": 4, "markerfacecolor": "#90a4ae",
                                "markeredgecolor": "#607d8b"})
    ax.set_xticks(range(1, len(order) + 1), [f"{l}\n(n={len(langs[l])})" for l in order])
    for p in bp["boxes"]:
        p.set_facecolor("#bbdefb")
        p.set_edgecolor(C_BAR)
    ax.set_ylabel("Minutes per exercise")
    ax.set_title(f"{name}: minutes per exercise by language")
    ax.grid(axis="x", visible=False)
    fig.tight_layout()
    fig.savefig(os.path.join(out, "minutes_by_language.png"), dpi=DPI)
    plt.close(fig)


def pearson(xs, ys):
    if len(xs) < 2:
        return float("nan")
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    return sxy / (sxx * syy) ** 0.5 if sxx and syy else float("nan")


def chart_scatter(rows, name, out):
    """Scatter of minutes vs completion tokens. Exercises that exhausted the
    context window are drawn as hollow markers and left out of the fit."""
    xs = [r["tokens"] / 1000 for r in rows]
    ys = [r["minutes"] for r in rows]
    ok = [i for i, r in enumerate(rows) if not r["exhausted"]]
    r_all = pearson(xs, ys)
    r_ok = pearson([xs[i] for i in ok], [ys[i] for i in ok])
    fig, ax = plt.subplots(figsize=(10, 6))
    for label, color in (("passed on try 1", C_TRY1), ("passed on try 2", C_TRY2),
                         ("failed", C_FAIL)):
        for exh in (False, True):
            pts = [(x, y) for x, y, row in zip(xs, ys, rows)
                   if outcome(row)[0] == label and bool(row["exhausted"]) == exh]
            if not pts:
                continue
            if exh:
                ax.scatter(*zip(*pts), s=46, facecolors="none", edgecolors=color,
                           linewidths=1.6)
            else:
                ax.scatter(*zip(*pts), s=22, alpha=0.8, color=color, label=label,
                           edgecolors="white", linewidths=0.4)
    if len(ok) >= 2:
        fx = [xs[i] for i in ok]
        fy = [ys[i] for i in ok]
        mx, my = statistics.fmean(fx), statistics.fmean(fy)
        sxx = sum((x - mx) ** 2 for x in fx)
        if sxx:
            slope = sum((x - mx) * (y - my) for x, y in zip(fx, fy)) / sxx
            x0, x1 = min(xs), max(xs)
            ax.plot([x0, x1], [my + slope * (x0 - mx), my + slope * (x1 - mx)],
                    color="#455a64", linestyle="--", linewidth=1.2,
                    label=f"linear fit, context not exhausted (r = {r_ok:.2f})")
    n_ex = len(rows) - len(ok)
    if n_ex:
        ax.scatter([], [], s=46, facecolors="none", edgecolors="#455a64", linewidths=1.6,
                   label=f"hollow = exhausted the context window ({n_ex})")
    ax.set_xlabel("Completion tokens generated (thousands)")
    ax.set_ylabel("Minutes")
    ax.set_title(f"{name}: time per exercise vs tokens generated")
    ax.legend(loc="upper left")
    fig.tight_layout()
    fig.savefig(os.path.join(out, "duration_vs_tokens.png"), dpi=DPI)
    plt.close(fig)
    return r_all, r_ok


def summary(rows, rs):
    r, r_ok = rs
    langs = by_language(rows)
    total_min = sum(x["minutes"] for x in rows)
    lang_h = {l: sum(x["minutes"] for x in v) / 60 for l, v in langs.items()}
    top_lang = max(lang_h, key=lang_h.get)
    slow = max(rows, key=lambda x: x["minutes"])
    tok = sum(x["tokens"] for x in rows)
    return {
        "exercises": len(rows),
        "total_hours": round(total_min / 60, 2),
        "median_minutes": round(statistics.median(x["minutes"] for x in rows), 1),
        "hours_by_language": {l: round(h, 2) for l, h in sorted(lang_h.items(), key=lambda kv: -kv[1])},
        "median_minutes_by_language": {l: round(statistics.median(x["minutes"] for x in v), 1)
                                       for l, v in langs.items()},
        "count_by_language": {l: len(v) for l, v in langs.items()},
        "top_language": top_lang,
        "top_language_share": round(lang_h[top_lang] * 60 / total_min, 3),
        "slowest": {"exercise": f'{slow["language"]}/{slow["exercise"]}',
                    "minutes": round(slow["minutes"], 1),
                    "outcome": outcome(slow)[0], "exhausted": slow["exhausted"]},
        "tokens_per_second_overall": round(tok / (total_min * 60), 2) if total_min else None,
        "exhausted_exercises": sum(1 for x in rows if x["exhausted"]),
        "exhausted_hours": round(sum(x["minutes"] for x in rows if x["exhausted"]) / 60, 2),
        "pearson_r_minutes_vs_tokens": round(r, 3),
        "pearson_r_minutes_vs_tokens_not_exhausted": round(r_ok, 3),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("csv", help="path to results/<model>/per_exercise.csv")
    ap.add_argument("--out", help="output dir (default: <csv dir>/charts)")
    ap.add_argument("--title", help="model name for chart titles (default: dir name)")
    a = ap.parse_args()
    base = os.path.dirname(os.path.abspath(a.csv))
    out = a.out or os.path.join(base, "charts")
    name = a.title or os.path.basename(base).capitalize()
    os.makedirs(out, exist_ok=True)
    rows = load(a.csv)
    style()
    chart_hours(rows, name, out)
    chart_slowest(rows, name, out)
    chart_box(rows, name, out)
    rs = chart_scatter(rows, name, out)
    print(json.dumps(summary(rows, rs), indent=2))


if __name__ == "__main__":
    main()
