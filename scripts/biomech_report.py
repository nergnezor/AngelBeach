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
import glob
import os
import sys
from collections import defaultdict

# name -> (low, high, unit, why this band)
TARGETS = {
    "accel": (0, 10, "m/s^2", "sprint first-step peak"),
    "decel": (0, 12, "m/s^2", "hard controlled stop"),
    "plant": (0, 45, "m/s^2", "spike-approach gather, 3-5x bodyweight"),
    # The TYPICAL stride window, not the worst of several hundred. bob is a
    # claim about human gait, and the worst window read 9, 25 and 34 across
    # three runs of IDENTICAL code — one window setting the number, not a body
    # that changed. The worst is still printed below as context.
    "bobMean": (3, 8, "cm", "running COM oscillation 4-6, typical stride"),
    "airErr": (0, 60, "cm/s^2", "pure ballistic once airborne"),
    "jump": (40, 95, "cm", "elite spike jump 60-90"),
    # No speed row existed until 2026-09-05, and a dive was travelling at 10.2
    # m/s — faster than a sprint record, through sand — with every acceleration
    # row green, because the dive assigned its velocity instead of building it.
    # 8 is generous: a sprint on dry sand is well short of a track sprint.
    "topSpeed": (0, 8, "m/s", "ground speed; a sand sprint is under a track one"),
}


# Counters that are already an extreme or a ratio, so dividing them by the
# rally's motion time would be meaningless. wasteWorst is the worst single
# window, not an accumulation.
RAW_KEYS = {"wasteWorst", "goalJumps", "kneeWalk", "kneeWalkMin", "kneeWalkMax",
            "kneeStill", "kneeStillMax", "yawRateMean", "yawRateMax", "legAlpha",
            "yawRevisit", "yawWasteDeg", "yawWasteRate", "crouchRevisit",
            "yawRockWindows", "crouchRockWindows", "rockWindows",
            "pelvSlideX", "pelvSlideY", "pelvSlideZ", "planBookings", "planInfeas"}


def parse(path):
    bio, motion, raw, rallies = defaultdict(list), defaultdict(list), defaultdict(list), 0
    seqs = []
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
                m = re.search(r"seq=\[([^\]]*)\]", line)
                if m:
                    seqs.append(m.group(1).split())
    return bio, motion, raw, rallies, seqs


# Ballistic integrators are allowlisted. There were four — Ball's, the
# planner's, the pawn's and the AI's — all answering "where does the ball next
# descend through height Z", and two of them returned the first sample past the
# crossing instead of interpolating. The defect was fixed in two copies months
# apart while the other two kept it, and the pawn's fed the dig platform whose
# jitter the full-body IK wrote into the pelvis. Days went into finding that.
#
# The copies existed because Angelscript will not share a global across script
# modules, so anyone needing this from another file wrote their own. This makes
# a fifth one a failed run instead of a discovery in six months.
# Ball::PredictLanding solves the FLOOR crossing and stays separate on purpose.
# Merging it into the shared helper was tried on 2026-09-03 and measured a real
# regression — contacts/rally 2.88-3.17 -> 2.23-2.36, ranges not overlapping —
# because the shared version early-outs with the CURRENT position for a ball
# already below the target and descending, while PredictLanding integrates on.
# That changes the landing estimate for low balls and with it AmIHitter. It
# already interpolates its own crossing correctly. Two, not one, and the second
# is here by measurement rather than by neglect.
# AIPlayer::PredictBallTimeToHeight is the third, and also stays by measurement:
# it returns the sample PAST the crossing, and routing it through the accurate
# shared version cost contacts 2.88-3.17 -> 2.42-2.73 with builds 100% -> 85-95%.
# The jump and dive timing is calibrated against that lateness. Fix the pair or
# neither. Three exemptions, each with a number behind it — and the point of the
# check is that a FOURTH cannot appear without someone arguing for it.
CANON_INTEGRATORS = ("Script/World/Prediction.as", "Script/World/Ball.as",
                     "Script/AI/AIPlayer.as")


def check_one_integrator(root):
    pat = re.compile(r"while\s*\(\s*[Tt]\s*<")
    offenders = []
    for path in glob.glob(os.path.join(root, "Script", "**", "*.as"), recursive=True):
        rel = os.path.relpath(path, root)
        if rel.replace(os.sep, "/") in CANON_INTEGRATORS:
            continue
        for n, line in enumerate(open(path, errors="replace"), 1):
            if pat.search(line):
                offenders.append(f"{rel}:{n}")
    return offenders


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/run.log"
    bio, motion, raw, rallies, seqs = parse(path)

    if not bio and not motion:
        print(f"no BIOMECH or MOTIONSTATS lines in {path}")
        return 1

    print(f"\n=== {path}   rallies={rallies} ===\n")
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    dupes = check_one_integrator(root)
    if dupes:
        print("FAIL  a ballistic integrator exists outside the allowlist. Do not fork one:")
        print(f"      in {CANON_INTEGRATORS[0]}. Add a parameter there instead of forking it.")
        for d in dupes:
            print(f"        {d}")
        print()

    if bio:
        # Derived from monotone counters for the same reason as the rocking rate:
        # a mean emitted per report would be judged by max() below, which picks
        # whichever report period happened to be worst.
        if bio.get("bobWindows") and max(bio["bobWindows"]) > 0:
            bio["bobMean"] = [round(max(bio["bobSum"]) / 10.0 / max(bio["bobWindows"]), 1)]
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
            if key == "bobMean" and bio.get("bob"):
                print(f"       {'':<10} {max(bio['bob']):>6} {'cm':<8} "
                      f"{'':<12} (worst single stride window, context only)")
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
        # Derived here rather than in the game: the three counters are monotone
        # over a run, so the max of each IS its final value, while a ratio
        # emitted per report would hand this loop an early-run sample as the
        # run's worst.
        if raw.get("rockWindows"):
            wins = max(raw["rockWindows"])
            if wins > 0:
                for src_key, out_key in (("yawRockWindows", "yawRockPermille"),
                                         ("crouchRockWindows", "crouchRockPermille")):
                    if raw.get(src_key):
                        raw[out_key] = [1000.0 * max(raw[src_key]) / wins]
        jit_fail = 0
        for key, limit, unit, src in (
                ("wasteWorst", 250.0, "path/extent x100 in one 0.7s window", raw),
                # HOW OFTEN THE BODY ROCKS, not how bad its worst moment was.
                # yawRevisit/crouchRevisit are the worst single 0.7s window in
                # the run — an extreme gated at a fixed number, which can only
                # get worse the longer you measure. A 330s match is ~450
                # eligible windows per player, and the worst of 1800 was
                # reporting 430 while 98% of windows were clean. They are still
                # on the MOTIONSTATS line as context; what is gated is the rate.
                #
                # These two limits are RATCHETS in the sense the section below
                # describes — set from the measured spread (yaw 17-21, crouch
                # 36-68 per mille over three runs) with room for noise, so a
                # regression trips them and ordinary variation does not. They
                # are not a claim about human bodies.
                ("yawRockPermille", 30.0, "windows per 1000 where yaw rocks (>250)", raw),
                ("yawWasteRate", 100.0, "deg of yaw taken back per standing-second, x10", raw),
                ("crouchRockPermille", 90.0, "windows per 1000 where the knee flaps (>250)", raw),
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

        # COMPENSATION — how much work one layer is doing to cover another's
        # error. Every motion bug found on 2026-09-02/03 was a silent
        # absorption like this, and each one only became visible when someone
        # went looking. Measured, they cannot grow unnoticed.
        #
        # pelvSlide* are the 90th percentile per rally, not the maximum. As a
        # max this flagged a comment-only change as a regression and read
        # "unchanged" through a real one — a maximum over a rally is one frame.
        #
        # These are RATCHETS, not targets. The limits are today's measured
        # values rounded up: the debt is known and disclosed, and the gate
        # exists so it cannot get worse without saying so. Lower the limit when
        # the underlying cause is fixed; never raise it to make a run pass.
        print("COMPENSATION — one layer covering another (ratchets on known debt)")
        comp_fail = 0
        for key, limit, unit, why in (
                ("pelvSlideX", 95.0, "cm", "solver drags the pelvis off the script's target, p90"),
                ("pelvSlideY", 60.0, "cm", "same, sideways — the axis a one-axis gauge missed"),
                ("pelvSlideZ", 20.0, "cm", "same, vertical (pre-pull Z is off since a2cb71b)"),
                ("planInfeas", 60.0, "%", "bookings whose travel budget < ball flight time")):
            if key not in raw:
                continue
            if key == "planInfeas":
                # Summed over the whole run. As a per-rally percentage this read
                # 100 every time — one or two bookings per rally means a single
                # unmakeable one pins the ratio, and max() then always finds one.
                total = sum(raw.get("planBookings", [0]))
                v = 100.0 * sum(raw[key]) / total if total else 0.0
            else:
                v = max(raw[key])
            ok = v <= limit
            comp_fail += 0 if ok else 1
            print(f"  {'ok  ' if ok else 'FAIL'} {key:<14} {v:>7.1f}  limit {limit:<6} ({unit}: {why})")
        print(f"\n  {comp_fail} compensation metric(s) over the ratchet\n")

        # RALLY QUALITY — is it still volleyball? The motion rows above cannot
        # see this at all: on 2026-09-03 a change took the median rally from
        # three touches to ONE, and every metric in this report stayed happy.
        # A team that only returns single balls is not playing the game, however
        # smoothly it moves.
        if seqs:
            lens = sorted(len(q) for q in seqs)
            med_len = lens[len(lens) // 2]
            builds = sum(1 for q in seqs
                         if any(q[i][0] == q[i - 1][0] for i in range(1, len(q))))
            spikes = sum(1 for q in seqs if any("Spike" in tok for tok in q))
            one = sum(1 for L in lens if L <= 1)
            build_pct = 100.0 * builds / len(seqs)
            one_pct = 100.0 * one / len(seqs)
            print("RALLY QUALITY — is a team still building an attack?")
            rq_fail = 0
            for label, val, ok, unit in (
                    ("seqLenMed", med_len, med_len >= 2, "touches in the median rally, want >= 2"),
                    ("buildPct", build_pct, build_pct >= 60.0, "% of rallies with two touches by one team, want >= 60"),
                    ("oneTouchPct", one_pct, one_pct <= 25.0, "% of rallies dead after one touch, want <= 25"),
                    ("spikes", spikes, True, "attacks in this run (no gate, watch the trend)")):
                rq_fail += 0 if ok else 1
                print(f"  {'ok  ' if ok else 'FAIL'} {label:<14} {val:>7.1f}  ({unit})")
            print(f"\n  {rq_fail} rally-quality metric(s) failing\n")

        print("RELATIVE — per second of motion (compare against the last run)")
        for key in ("footSlide", "kneeWalkTravel", "kneeOpp", "pelvisFlips", "ikTeleports",
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
