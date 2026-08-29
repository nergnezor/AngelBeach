#!/usr/bin/env python3
"""Turn a headless run log into a movement scorecard.

    UnrealEditor ... -abslog=/tmp/run.log
    python3 scripts/biomech_report.py /tmp/run.log

Two kinds of number come out, and the difference matters:

  ABSOLUTE (BIOMECH lines) carry a target taken from sports-biomechanics
  literature, so they answer "could a human body do this?" on their own terms.
  A red row is wrong even if it is the best we have ever measured.

  RELATIVE (MOTIONSTATS lines) only compare against previous runs. They are
  normalised per second of motion here because rally length varies a lot and
  raw per-rally totals make a long rally look worse than a short one — a trap
  that has already produced one wrong conclusion in this project.

Gameplay guards come last: realism that stops the AI reaching balls is a
regression, not an improvement, so a change has to hold these too.
"""

import re
import sys
from collections import defaultdict

# name -> (low, high, unit, why this band)
TARGETS = {
    "accel": (0, 10, "m/s^2", "sprint first-step peak"),
    "decel": (0, 12, "m/s^2", "hard controlled stop"),
    "plant": (0, 45, "m/s^2", "spike-approach gather, 3-5x bodyweight"),
    "bob": (3, 8, "cm", "running COM oscillation 4-6"),
    "airErr": (0, 60, "cm/s^2", "pure ballistic once airborne"),
    "jump": (40, 95, "cm", "elite spike jump 60-90"),
}


# Counters that are already an extreme or a ratio, so dividing them by the
# rally's motion time would be meaningless. wasteWorst is the worst single
# window, not an accumulation.
RAW_KEYS = {"wasteWorst", "goalJumps", "kneeWalk", "kneeWalkMin", "kneeWalkMax",
            "kneeStill", "kneeStillMax", "yawRateMean", "yawRateMax", "legAlpha",
            "yawRevisit", "crouchRevisit"}


def parse(path):
    bio, motion, raw, rallies = defaultdict(list), defaultdict(list), defaultdict(list), 0
    line_re = re.compile(r"\b(\w+)=(-?\d+)")
    with open(path, errors="replace") as fh:
        for line in fh:
            if "BIOMECH " in line:
                who = line.split("BIOMECH ", 1)[1].split()[0]
                for k, v in line_re.findall(line):
                    bio[k].append(int(v))
                bio["_who"].append(who)
            elif "MOTIONSTATS " in line:
                vals = dict((k, int(v)) for k, v in line_re.findall(line))
                moving = vals.get("moving", 0) / 100.0
                if moving > 0.5:          # ignore slivers; they divide badly
                    for k, v in vals.items():
                        if k == "moving":
                            continue
                        if k in RAW_KEYS:
                            raw[k].append(float(v))
                        else:
                            motion[k].append(v / moving)
            elif "RALLY " in line:
                rallies += 1
    return bio, motion, raw, rallies


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/run.log"
    bio, motion, raw, rallies = parse(path)

    if not bio and not motion:
        print(f"no BIOMECH or MOTIONSTATS lines in {path}")
        return 1

    print(f"\n=== {path}   rallies={rallies} ===\n")

    if bio:
        print("ABSOLUTE — human plausibility (worst player per metric)")
        worst_fail = 0
        for key, (lo, hi, unit, why) in TARGETS.items():
            if key not in bio:
                continue
            vals = bio[key]
            if key == "jump":
                # Most rallies contain no jump at all for most players, and a
                # player who never left the ground reports 0. Judge only rallies
                # where someone actually left the ground, and judge the BEST
                # jump: a block, a step-in and a full spike approach are all
                # legitimate and differ by tens of centimetres, so the minimum
                # measures "the smallest hop anyone made", not jumping ability.
                vals = [v for v in vals if v > 20]
                if not vals:
                    print(f"  --   {key:<10} {'n/a':>6} {unit:<8} "
                          f"target {lo}-{hi:<4} (nobody jumped)")
                    continue
                v = max(vals)
            else:
                # Report the worst case, not the mean: one player moving
                # impossibly is a bug even if the other three are fine.
                v = max(vals)
            ok = lo <= v <= hi
            worst_fail += 0 if ok else 1
            flag = "ok  " if ok else "FAIL"
            print(f"  {flag} {key:<10} {v:>6} {unit:<8} target {lo}-{hi:<4} ({why})")
        over = bio.get("overBudget", [])
        if over:
            cs = max(over)
            print(f"  {'ok  ' if cs == 0 else 'FAIL'} {'overBudget':<10} {cs:>6} "
                  f"{'cs':<8} target 0     (time outside the human accel band)")
            worst_fail += 0 if cs == 0 else 1
        print(f"\n  {worst_fail} metric(s) outside human range\n")

    if motion:
        # JITTER is judged here, not by eye and not by a separate CI job that
        # someone has to remember to dispatch. Wasted travel is walking that
        # arrives nowhere, so a threshold on it is a statement about the motion
        # itself rather than a tuning knob: a run wastes ~0, standing wastes ~0,
        # and only a shuttle scores. See UpdateWastedTravel for why the older
        # derivative-based flip counters cannot see this at all.
        # Three channels, one primitive. wasteWorst watches TRANSLATION only,
        # and a player rocking on the spot walks a path of length zero — it
        # scored a clean 100 through an entire run of visible shaking. yaw and
        # crouch close that: the same path/extent ratio on the two degrees of
        # freedom a planted body can still churn.
        print("JITTER — revisited ground (motion that arrives nowhere)")
        jit_fail = 0
        for key, limit, unit, src in (
                ("wasteWorst", 250.0, "path/extent x100 in one 0.7s window", raw),
                ("yawRevisit", 250.0, "deg turned / deg net, x100 (rocking in place)", raw),
                ("crouchRevisit", 250.0, "crouch travel / net, x100 (knee flapping)", raw),
                ("wasteTotal", 60.0, "cm of reground per second of motion", motion)):
            if key not in src:
                continue
            v = max(src[key])
            ok = v <= limit
            jit_fail += 0 if ok else 1
            print(f"  {'ok  ' if ok else 'FAIL'} {key:<12} {v:>7.1f}  limit {limit:<6} ({unit})")
        if "goalJumps" in raw:
            v = max(raw["goalJumps"])
            ok = v <= 250.0
            jit_fail += 0 if ok else 1
            print(f"  {'ok  ' if ok else 'FAIL'} {'goalChurn':<12} {v:>7.1f}  limit {250.0:<6} "
                  f"(goal path/extent x100; a goal tracking a ball scores ~100)")
        print(f"\n  {jit_fail} jitter metric(s) over limit\n")

        print("RELATIVE — per second of motion (compare against the last run)")
        for key in ("footSlide", "kneeWalkTravel", "pelvisFlips", "ikTeleports",
                    "moveFlips", "yawFlips", "crouchFlips"):
            if key in motion:
                vals = motion[key]
                print(f"       {key:<16} mean {sum(vals)/len(vals):>8.1f}"
                      f"   worst {max(vals):>8.1f}")
        for key in ("kneeWalk", "kneeWalkMax"):
            if key in raw:
                vals = raw[key]
                print(f"       {key:<16} (absolute, not per-second) "
                      f"mean {sum(vals)/len(vals):>6.1f}")
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
