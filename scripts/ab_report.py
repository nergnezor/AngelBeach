#!/usr/bin/env python3
"""Spread across runs, and overlap between two configurations.

Never reports a single run's value on its own: the point of this script is that
rally-level metrics on this project vary 3.00-3.87 across runs of identical
code, so one number means nothing. Two configurations differ only when their
ranges do not overlap.
"""
import glob
import re
import statistics
import sys

# (key, label, is_per_frame, higher_is_better). Per-frame metrics average
# thousands of samples and are trustworthy from a single run; rally-level counts
# are not. The direction is encoded here rather than left to the reader: a
# footnote saying "read it inverted" is exactly the kind of foot-gun that made
# this script necessary.
METRICS = [
    ("touchesPerRally", "contacts / rally", False, True),
    ("seqLenMed",       "median rally length", False, True),
    ("buildPct",        "rallies with a build %", False, True),
    ("oneTouchPct",     "dead after one touch %", False, False),
    ("spikes",          "attacks", False, True),
    ("pelvSlideX",      "pelvis slide X (cm)", True, False),
    ("pelvSlideY",      "pelvis slide Y (cm)", True, False),
    ("pelvSlideZ",      "pelvis slide Z (cm)", True, False),
    ("planInfeasible",  "infeasible bookings %", True, False),
    ("yawWasteRate",    "wasted yaw / standing-s", True, False),
    ("wasteWorst",      "worst wasted travel", True, False),
]


def scrape(path):
    t = open(path, errors="replace").read()
    seqs = [m.split() for m in re.findall(r"seq=\[([^\]]*)\]", t)]
    rallies = len(re.findall(r"RALLY ", t))
    out = {}
    if rallies:
        out["touchesPerRally"] = len(re.findall(r"PLANVA", t)) / rallies
    if seqs:
        lens = sorted(len(q) for q in seqs)
        out["seqLenMed"] = lens[len(lens) // 2]
        out["buildPct"] = 100.0 * sum(
            1 for q in seqs if any(q[i][0] == q[i - 1][0] for i in range(1, len(q)))) / len(seqs)
        out["oneTouchPct"] = 100.0 * sum(1 for L in lens if L <= 1) / len(seqs)
        out["spikes"] = sum(1 for q in seqs if any("Spike" in tok for tok in q))
    for key, _, _, _ in METRICS:
        if key in out:
            continue
        vals = [float(v) for v in re.findall(rf"\b{key}=(-?\d+)", t)]
        if vals:
            out[key] = max(vals)
    return out


def collect(label):
    paths = sorted(glob.glob(f"/tmp/ab-{label}-*.log"))
    if not paths:
        sys.exit(f"no runs found for '{label}' (/tmp/ab-{label}-*.log)")
    runs = [scrape(p) for p in paths]
    return label, runs


def rng(runs, key):
    vals = [r[key] for r in runs if key in r]
    return (min(vals), statistics.median(vals), max(vals)) if vals else None


def show(label, runs):
    print(f"\n=== {label}: {len(runs)} runs ===")
    if len(runs) < 3:
        print("  WARNING: fewer than 3 runs. Rally-level numbers below cannot be")
        print("           trusted — identical code spreads 3.00-3.87 on contacts.")
    print(f"  {'metric':<26} {'min':>8} {'median':>8} {'max':>8}")
    for key, lab, per_frame, _ in METRICS:
        r = rng(runs, key)
        if r is None:
            continue
        tag = "" if per_frame else "  (rally-level: needs 3+)"
        print(f"  {lab:<26} {r[0]:8.2f} {r[1]:8.2f} {r[2]:8.2f}{tag}")


def compare(a, b):
    (la, ra), (lb, rb) = a, b
    show(la, ra)
    show(lb, rb)
    print(f"\n=== {la} vs {lb} ===")
    print("  A difference counts only when the ranges do not overlap.\n")
    for key, lab, per_frame, higher_better in METRICS:
        x, y = rng(ra, key), rng(rb, key)
        if x is None or y is None:
            continue
        if not (x[2] < y[0] or y[2] < x[0]):
            verdict = "same (ranges overlap)"
        else:
            rose = y[1] > x[1]
            verdict = "BETTER" if rose == higher_better else "WORSE"
        print(f"  {lab:<26} {x[0]:6.2f}-{x[2]:<6.2f} -> {y[0]:6.2f}-{y[2]:<6.2f}   {verdict}")


if __name__ == "__main__":
    if len(sys.argv) == 3:
        compare(collect(sys.argv[1]), collect(sys.argv[2]))
    elif len(sys.argv) == 2:
        show(*collect(sys.argv[1]))
    else:
        sys.exit("usage: ab_report.py <label> | ab_report.py <labelA> <labelB>")
