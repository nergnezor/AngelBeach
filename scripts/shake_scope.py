#!/usr/bin/env python3
"""Look at the shake instead of guessing at it.

    python3 scripts/shake_scope.py /tmp/run.log [PlayerName]

biomech_report.py answers "does something oscillate?" with a path/extent ratio.
It cannot answer "at what frequency, at what amplitude, and driven by what" —
and guessing that from a ratio has already cost one wrong fix, so this exists to
remove the guessing step.

Input is the per-frame TRACE line (VolleyballPlayer.bTraceMotion). For each
channel it reports the reversal rate (how many times per second the signal
changes direction), the median half-amplitude of those reversals, and the same
numbers split by whether the player was standing still or running — a body that
rocks while planted is a different bug from one that wobbles mid-stride.

THE DECISIVE COLUMN IS `target`. yaw is a controller chasing want:

  want steady, yaw reversing  -> the ROTATION CONTROLLER oscillates (gain/limiter)
  want reversing              -> the TARGET oscillates; the bug is upstream in
                                 whatever picked it, and src says which source
                                 was selected at the time

Without that split, "the yaw oscillates" is compatible with a dozen causes and
selects none of them.
"""

import re
import sys
from collections import Counter, defaultdict

STAND_SPEED = 30.0        # cm/s below which the player is "planted"
YAW_NOISE = 0.35          # deg; below this a per-frame step is float noise
CROUCH_NOISE = 0.004


def parse(path):
    rows = defaultdict(list)
    pat = re.compile(r"TRACE (\S+) (.*)$")
    for line in open(path, errors="replace"):
        m = pat.search(line)
        if not m:
            continue
        who, rest = m.group(1), m.group(2)
        d = dict((k, int(v)) for k, v in re.findall(r"\b(\w+)=(-?\d+)", rest))
        if "t" not in d:
            continue
        rows[who].append(d)
    return rows


def unwrap(seq):
    """Angles in degrees -> continuous, so a +-180 wrap is not a 360 deg step."""
    out, off, prev = [], 0.0, None
    for v in seq:
        if prev is not None:
            d = v - prev
            if d > 180.0:
                off -= 360.0
            elif d < -180.0:
                off += 360.0
        out.append(v + off)
        prev = v
    return out


def reversals(sig, noise):
    """(count, list of half-amplitudes) for direction changes above `noise`."""
    amps, n = [], 0
    last_dir, last_ext = 0, sig[0] if sig else 0.0
    for i in range(1, len(sig)):
        step = sig[i] - sig[i - 1]
        if abs(step) < noise:
            continue
        d = 1 if step > 0 else -1
        if last_dir and d != last_dir:
            n += 1
            amps.append(abs(sig[i - 1] - last_ext))
            last_ext = sig[i - 1]
        last_dir = d
    return n, amps


def med(a):
    return sorted(a)[len(a) // 2] if a else 0.0


def channel(name, sig, times, noise, unit):
    if len(sig) < 10:
        return
    span = (times[-1] - times[0]) / 1000.0
    if span <= 0:
        return
    n, amps = reversals(sig, noise)
    print(f"    {name:<8} {n/span:6.2f} rev/s   median half-amp "
          f"{med(amps):7.2f} {unit}   worst {max(amps) if amps else 0:7.2f} {unit}")


def report(who, rows):
    rows.sort(key=lambda d: d["t"])
    # A run has gaps (dead balls, resets); split on any backwards or huge jump.
    segs, cur = [], []
    for d in rows:
        if cur and (d["t"] < cur[-1]["t"] or d["t"] - cur[-1]["t"] > 500):
            segs.append(cur)
            cur = []
        cur.append(d)
    if cur:
        segs.append(cur)

    for label, keep in (("PLANTED (spd<30)", lambda d: d["spd"] < STAND_SPEED),
                        ("MOVING", lambda d: d["spd"] >= STAND_SPEED)):
        yaw, want, cr, ts, srcs = [], [], [], [], Counter()
        for seg in segs:
            sub = [d for d in seg if keep(d)]
            if len(sub) < 20:
                continue
            yaw += unwrap([d["yaw"] / 10.0 for d in sub])
            want += unwrap([d["want"] / 10.0 for d in sub])
            cr += [d["cr"] / 1000.0 for d in sub]
            ts += [d["t"] for d in sub]
            srcs.update(d["src"] for d in sub)
        if len(ts) < 20:
            continue
        secs = (ts[-1] - ts[0]) / 1000.0
        print(f"\n  {who}  {label}   {len(ts)} frames")
        channel("yaw", yaw, ts, YAW_NOISE, "deg")
        channel("target", want, ts, YAW_NOISE, "deg")
        channel("crouch", cr, ts, CROUCH_NOISE, "")
        tot = sum(srcs.values())
        names = {0: "velocity", 1: "held/FaceBall", 2: "turn-and-run", -1: "none"}
        share = "  ".join(f"{names.get(k, k)}={v*100//tot}%"
                          for k, v in srcs.most_common(4))
        print(f"    facing source: {share}")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/run.log"
    rows = parse(path)
    if not rows:
        print(f"no TRACE lines in {path} (is bTraceMotion on?)")
        return 1
    print(f"\n=== {path} ===")
    only = sys.argv[2] if len(sys.argv) > 2 else None
    for who in sorted(rows):
        if only and who != only:
            continue
        report(who, rows[who])
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
