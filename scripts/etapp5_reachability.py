#!/usr/bin/env python3
"""Which script-driven Anim BP inputs actually reach Output Pose?

The AnimGraph has more than one island. Tracing backwards from Root showed the
pelvis Transform (Modify) Bone and both foot Two Bone IK nodes hanging off a
pair of conversion nodes nothing downstream reads — so everything the script
writes for them is computed, logged, measured, and thrown away.

This walks the pose graph from Output Pose, marks every reachable node, and then
reports each Get <property> node by whether the node it feeds is on that set.
Read-only: it changes nothing.
"""
from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Plugins", "UnrealMCP"))
os.chdir(ROOT)

from unrealmcp._tcp_bridge import _tcp_send_raw  # noqa: E402

ABP = "/Game/Characters/Mannequin/ABP_VolleyballPlayer"
# Pins that carry a POSE. Reachability has to follow these and only these: a
# float or a vector feeding a node is what we are classifying, not a path.
POSE_PINS = {"Pose", "ComponentPose", "LocalPose", "Result", "Source", "BasePose",
             "BlendPose_0", "BlendPose_1", "BlendPose_2", "BlendPose_3",
             "A", "B", "Base", "Additive"}


def graph():
    r = _tcp_send_raw("analyze_blueprint_graph", {
        "blueprint_path": ABP, "graph_name": "AnimGraph",
        "include_node_details": True, "include_pin_connections": True,
        "trace_execution_flow": True,
    })
    if r.get("status") == "error":
        raise RuntimeError(r.get("error"))
    return r.get("result", r).get("graph_data", {})


def main() -> int:
    gd = graph()
    nodes = {n["name"]: n for n in gd.get("nodes", [])}
    cons = gd.get("connections", [])

    # DIRECTION COMES FROM THE PINS, NOT FROM PIN NAMES. The dump lists every
    # edge from both endpoints, so matching on names alone floods the whole
    # connected component in both directions and calls all of it reachable —
    # which is exactly how a first version of this "found" a dead branch that
    # was not dead. An edge is upstream only when the pin it is described from
    # is an INPUT.
    direction = {}
    for n in gd.get("nodes", []):
        for p in n.get("pins", []):
            direction[(n["name"], p["name"])] = p.get("direction")

    feeds: dict[str, set] = {}
    for c in cons:
        if direction.get((c["from_node"], c["from_pin"])) == "Input":
            feeds.setdefault(c["from_node"], set()).add(c["to_node"])

    live, stack = set(), ["AnimGraphNode_Root_0"]
    while stack:
        n = stack.pop()
        if n in live:
            continue
        live.add(n)
        stack.extend(feeds.get(n, ()))

    print(f"live pose nodes: {len(live)} of {len(nodes)}\n")

    # Every Get <var> node, and whether what it drives is on the live path.
    rows = []
    for c in cons:
        src = nodes.get(c["from_node"], {})
        if not (src.get("class") or "").startswith("K2Node_VariableGet"):
            continue
        title = (src.get("title") or "").replace("\n", " ")
        var = title.replace("Get ", "").strip()
        target = c["to_node"]
        if target == c["from_node"]:
            continue
        rows.append((var, target, nodes.get(target, {}).get("class", "?"), target in live))

    seen = set()
    for var, target, cls, ok in sorted(rows):
        key = (var, target)
        if key in seen:
            continue
        seen.add(key)
        print(f"  {'LIVE' if ok else 'DEAD'}  {var:18} -> {cls.replace('AnimGraphNode_','')} ({target})")

    dead = sorted({v for v, _, _, ok in rows if not ok} - {v for v, _, _, ok in rows if ok})
    if dead:
        print("\nWritten by the script and reaching nothing: " + ", ".join(dead))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
