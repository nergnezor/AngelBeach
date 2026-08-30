#!/usr/bin/env python3
"""Summarise POSE / MOTIONSTATS movement anomalies from a headless log.

    python3 scripts/pose_report.py /tmp/pose_verify.log
"""
from __future__ import annotations

import re
import sys
from collections import defaultdict


def parse_kv(line: str) -> dict[str, str]:
    return dict(re.findall(r"\b(\w+)=(-?\d+)", line))


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pose_verify.log"
    poses: list[dict[str, str]] = []
    stats: list[tuple[str, dict[str, str]]] = []
    with open(path, errors="replace") as fh:
        for line in fh:
            if "Angelscript: POSE " in line:
                who = line.split("POSE ", 1)[1].split()[0]
                kv = parse_kv(line)
                kv["_who"] = who
                poses.append(kv)
            elif "Angelscript: MOTIONSTATS " in line:
                who = line.split("MOTIONSTATS ", 1)[1].split()[0]
                stats.append((who, parse_kv(line)))

    print(f"\n=== {path} ===")
    print(f"POSE lines={len(poses)}  MOTIONSTATS lines={len(stats)}\n")

    if not poses and not stats:
        print("no POSE or MOTIONSTATS lines found")
        return 1

    if poses:
        under = [p for p in poses if p.get("under") == "1"]
        back = [p for p in poses if p.get("back") == "1"]
        print("--- POSE anomalies ---")
        print(f"  under-sand samples: {len(under)}")
        print(f"  backpedal samples:  {len(back)}")
        if under:
            zs = [int(p["footZ"]) for p in under if "footZ" in p]
            ks = [int(p["kneeZ"]) for p in under if "kneeZ" in p]
            print(f"  footZ while under:  min={min(zs)} median={sorted(zs)[len(zs)//2]} max={max(zs)}")
            if ks:
                print(f"  kneeZ while under:  min={min(ks)} median={sorted(ks)[len(ks)//2]} max={max(ks)}")
            # legA distribution: 0 means ABP ignores FootTarget
            las = [int(p["legA"]) for p in under if "legA" in p]
            if las:
                zero = sum(1 for x in las if x == 0)
                print(f"  legAlpha==0 under sand: {zero}/{len(las)}  (0 => ABP not using FootTarget)")
        if back:
            tr = sum(1 for p in back if p.get("turnRun") == "1")
            print(f"  turnRun ON during backpedal: {tr}/{len(back)}")
            fwds = [int(p["fwd"]) for p in back if "fwd" in p]
            print(f"  ForwardSpeed backpedal: min={min(fwds)} median={sorted(fwds)[len(fwds)//2]}")
        print()

    if stats:
        print("--- MOTIONSTATS (per rally emit) ---")
        by: dict[str, list[dict[str, str]]] = defaultdict(list)
        for who, kv in stats:
            by[who].append(kv)
        for who, rows in sorted(by.items()):
            def avg(key: str) -> float:
                vals = [int(r[key]) for r in rows if key in r]
                return sum(vals) / len(vals) if vals else 0.0

            print(
                f"  {who}: underSand={avg('underSand'):.0f}cs "
                f"backpedal={avg('backpedal'):.0f}cs "
                f"turnRun={avg('turnRun'):.0f}cs "
                f"footZMin={avg('footZMin'):.0f} "
                f"kneeZMin={avg('kneeZMin'):.0f} "
                f"legAlpha={avg('legAlpha'):.0f}"
            )
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
