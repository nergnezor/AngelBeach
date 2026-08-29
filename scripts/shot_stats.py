#!/usr/bin/env python3
"""Measure the Vista reference series — the numeric half of the fidelity pass.

Vista (Script/Debug/Vista.as) guarantees the framing never moves, so a fixed
rectangle always lands on the same surface and a before/after is a subtraction
rather than an argument. This reads those PNGs and prints what the project's
comments have always cited by hand: sand mid-tone, sky zenith/horizon, body lit
vs shadow, clipping.

    python3 scripts/shot_stats.py                      # measure the current shots
    python3 scripts/shot_stats.py --save baseline      # remember them as a baseline
    python3 scripts/shot_stats.py --against baseline   # print the delta vs that baseline
    python3 scripts/shot_stats.py --overlay            # draw the rectangles, to check aim

WHY DELTAS AND NOT ABSOLUTES. Nearly every measured value quoted in GameMode.as,
Court.as and Environment.as was taken with local scalability pinned to LOW
(sg.ShadowQuality/PostProcess/Effects = 0). They are historical. Re-baseline
rather than comparing against them.
"""

import argparse
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

SHOT_DIR = os.path.join(os.path.dirname(__file__), "..", "Saved", "Screenshots", "LinuxEditor")
STATE_DIR = os.path.join(os.path.dirname(__file__), "..", "Saved", "ShotStats")

# Rectangles are (x0, y0, x1, y1) at 1280x720 and are scaled if the capture is
# a different size. They are aimed at SURFACES, not at objects that move: Vista
# parks every player and the ball on a fixed mark before it shoots.
REGIONS = {
    "Vista_1_wide": {
        # Re-aimed once SkyAtmosphere replaced the dome: what these used to call
        # "zenith" and "horizon" were the cloud layer and the sea.
        "sky_zenith":  (560, 60, 720, 100),
        "sky_horizon": (560, 130, 720, 150),
        "sand_far":    (540, 296, 740, 326),
        "sand_near":   (260, 600, 420, 660),
        "sea":         (560, 185, 720, 240),
    },
    "Vista_2_two_shot": {
        "body":        (686, 300, 726, 430),
        "sand_lit":    (300, 560, 420, 620),
        # The BALL's cast shadow: an isolated ellipse on clean sand, where the
        # net's shadow stripes would have made the reading half lit, half dark.
        # Re-aimed when the sun moved from the zenith to (-45, 70) — a cast
        # shadow's position is a function of the sun angle, so this rectangle
        # has to move whenever the sun does.
        "sand_shadow": (620, 522, 662, 542),
    },
    "Vista_3_ball": {
        "ball":        (600, 320, 690, 400),
    },
    "Vista_4_sand": {
        "sand_fg":     (300, 480, 700, 620),
        "sand_mid":    (200, 400, 500, 430),
    },
    "Vista_5_horizon": {
        "sky_top":     (500, 10, 780, 60),
        "sky_mid":     (500, 300, 780, 340),
        "sea_band":    (300, 540, 560, 565),
        "sand_fg":     (300, 620, 900, 700),
    },
    "Vista_6_skin": {
        # One box wholly INSIDE the body rather than two hand-placed patches.
        # Hand patches drift onto a seam or a gap the moment the pose or the
        # material changes; a spread taken across the whole torso does not.
        "body":        (580, 300, 700, 620),
    },
}

# Which regions get a texture reading. Local standard deviation over a flat
# surface is "does this have any detail at all" as a number: a solid-colour
# material scores ~0 no matter how good the lighting is.
TEXTURE_REGIONS = {("Vista_4_sand", "sand_fg"), ("Vista_1_wide", "sand_near")}

# The sky banding check: sample a column of the dome and count how many
# neighbouring samples jump. A real gradient steps by ~1; a 40-band dome steps
# by a lot at 39 places.
BAND_SCAN = {"Vista_5_horizon": (300, 10, 560), "Vista_1_wide": (640, 6, 230)}


def scaled(rect, w, h):
    sx, sy = w / 1280.0, h / 720.0
    return (int(rect[0] * sx), int(rect[1] * sy), int(rect[2] * sx), int(rect[3] * sy))


def measure(path):
    img = Image.open(path).convert("RGB")
    a = np.asarray(img).astype(np.float32)
    h, w = a.shape[:2]
    name = os.path.splitext(os.path.basename(path))[0]
    out = {"_size": [w, h]}

    lum = 0.2126 * a[:, :, 0] + 0.7152 * a[:, :, 1] + 0.0722 * a[:, :, 2]
    out["_frame"] = {
        "mean": [round(float(a[:, :, c].mean()), 1) for c in range(3)],
        "p50": round(float(np.percentile(lum, 50)), 1),
        "p99": round(float(np.percentile(lum, 99)), 1),
        "p999": round(float(np.percentile(lum, 99.9)), 1),
        # Clipping is the failure this project has hit repeatedly: albedo stops
        # being a lever once a surface is pinned at 255 and only the light helps.
        "clip_pct": round(float((a.max(axis=2) >= 254).mean() * 100), 3),
    }

    for rname, rect in REGIONS.get(name, {}).items():
        x0, y0, x1, y1 = scaled(rect, w, h)
        patch = a[y0:y1, x0:x1]
        if patch.size == 0:
            continue
        rec = {"rgb": [round(float(patch[:, :, c].mean()), 1) for c in range(3)]}
        plum = 0.2126 * patch[:, :, 0] + 0.7152 * patch[:, :, 1] + 0.0722 * patch[:, :, 2]
        rec["lum"] = round(float(plum.mean()), 1)
        rec["min"] = round(float(plum.min()), 1)
        rec["max"] = round(float(plum.max()), 1)
        if (name, rname) in TEXTURE_REGIONS:
            rec["texture_sd"] = round(float(plum.std()), 2)
        if rname == "body":
            # p90 - p25 across the torso. A flat zenith sun leaves a body almost
            # uniformly lit and this collapses; a sun with an angle to it opens
            # a lit side and a shadow side and this is how much.
            rec["p90"] = round(float(np.percentile(plum, 90)), 1)
            rec["p25"] = round(float(np.percentile(plum, 25)), 1)
        out[rname] = rec

    if name in BAND_SCAN:
        x, ytop, ybot = BAND_SCAN[name]
        x = int(x * w / 1280.0)
        col = a[int(ytop * h / 720.0):int(ybot * h / 720.0), x, :].mean(axis=1)
        steps = np.abs(np.diff(col))
        out["_sky_banding"] = {
            "max_step": round(float(steps.max()), 2),
            "steps_over_3": int((steps > 3).sum()),
        }

    # Derived readings that say more than either half alone.
    if name == "Vista_2_two_shot" and "sand_lit" in out and "sand_shadow" in out:
        out["_shadow_delta"] = round(out["sand_lit"]["lum"] - out["sand_shadow"]["lum"], 1)
    for shot in ("Vista_6_skin", "Vista_2_two_shot"):
        if name == shot and "body" in out:
            out["_form_delta"] = round(out["body"]["p90"] - out["body"]["p25"], 1)
    if name == "Vista_3_ball" and "ball" in out:
        out["_ball_gradient"] = round(out["ball"]["max"] - out["ball"]["min"], 1)
    return out


def collect():
    shots = {}
    for name in sorted(REGIONS):
        p = os.path.join(SHOT_DIR, name + ".png")
        if os.path.exists(p):
            shots[name] = measure(p)
        else:
            print(f"  (missing {name}.png)", file=sys.stderr)
    return shots


def fmt(rec):
    if "rgb" in rec:
        r, g, b = rec["rgb"]
        s = f"({r:5.1f},{g:5.1f},{b:5.1f}) lum {rec['lum']:5.1f}  min {rec['min']:5.1f} max {rec['max']:5.1f}"
        if "texture_sd" in rec:
            s += f"  texture_sd {rec['texture_sd']:5.2f}"
        if "p90" in rec:
            s += f"  p25 {rec['p25']:5.1f} p90 {rec['p90']:5.1f}"
        return s
    return json.dumps(rec)


def show(shots, base=None):
    for name, rec in shots.items():
        print(f"\n=== {name} ===")
        f = rec["_frame"]
        print(f"  frame        mean {f['mean']}  p50 {f['p50']:5.1f}  p99 {f['p99']:5.1f}  "
              f"p99.9 {f['p999']:5.1f}  clipped {f['clip_pct']}%")
        for k, v in rec.items():
            if k.startswith("_"):
                continue
            line = f"  {k:<12} {fmt(v)}"
            if base and name in base and k in base[name]:
                d = v["lum"] - base[name][k]["lum"]
                line += f"   [{d:+6.1f}]"
            print(line)
        for k, v in rec.items():
            if k.startswith("_") and k not in ("_frame", "_size"):
                extra = ""
                if base and name in base and k in base[name] and isinstance(v, (int, float)):
                    extra = f"   [{v - base[name][k]:+.1f}]"
                print(f"  {k:<12} {v}{extra}")


def overlay(outdir):
    os.makedirs(outdir, exist_ok=True)
    for name, regions in REGIONS.items():
        p = os.path.join(SHOT_DIR, name + ".png")
        if not os.path.exists(p):
            continue
        img = Image.open(p).convert("RGB")
        d = ImageDraw.Draw(img)
        for rname, rect in regions.items():
            r = scaled(rect, img.width, img.height)
            d.rectangle(r, outline=(255, 0, 255), width=3)
            d.text((r[0] + 4, r[1] + 4), rname, fill=(255, 0, 255))
        if name in BAND_SCAN:
            x, ytop, ybot = BAND_SCAN[name]
            x = int(x * img.width / 1280.0)
            d.line([(x, int(ytop * img.height / 720.0)), (x, int(ybot * img.height / 720.0))],
                   fill=(0, 255, 0), width=3)
        img.save(os.path.join(outdir, name + "_regions.png"))
    print(f"overlays written to {outdir}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--save", metavar="NAME", help="store these numbers as a named baseline")
    ap.add_argument("--against", metavar="NAME", help="print deltas against a named baseline")
    ap.add_argument("--overlay", action="store_true", help="write region-annotated copies")
    args = ap.parse_args()

    if args.overlay:
        overlay(os.path.join(STATE_DIR, "overlay"))
        return

    shots = collect()
    base = None
    if args.against:
        bp = os.path.join(STATE_DIR, args.against + ".json")
        if not os.path.exists(bp):
            sys.exit(f"no baseline named {args.against} at {bp}")
        base = json.load(open(bp))
    show(shots, base)

    if args.save:
        os.makedirs(STATE_DIR, exist_ok=True)
        sp = os.path.join(STATE_DIR, args.save + ".json")
        json.dump(shots, open(sp, "w"), indent=1)
        print(f"\nsaved baseline -> {sp}")


if __name__ == "__main__":
    main()
