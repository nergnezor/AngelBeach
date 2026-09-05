#!/usr/bin/env python3
"""Wire BS_VolleyballLocomotion into the AnimGraph, replacing the idle/run switch.

Locomotion was a BINARY choice: Blend Poses by bool on bIsMoving, picking
MM_Idle when still and MM_Run_Fwd when not. A player moving at any speed above
the threshold played a full run, so the pose never had a pace — which is why
the trunk lean measured a constant 28 degrees off vertical whether the player
was jogging into position or sprinting for a dig, and why nothing done in
script could make the movement read as relaxed.

The blend space this should have been using already exists, built and never
connected: MM_Idle at 0, MM_Walk_Fwd at 240, MM_Run_Fwd at 532 cm/s, on the
ABP's own skeleton. Players average 320 cm/s while moving, i.e. squarely
between walk and run, so most of the match should be playing a pose that until
now was never sampled at all.

Idempotent: run it again to re-point or re-wire.
"""
from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Plugins", "UnrealMCP"))
os.chdir(ROOT)

from unrealmcp._tcp_bridge import _tcp_send_raw  # noqa: E402

ABP = "/Game/Characters/Mannequin/ABP_VolleyballPlayer"
GRAPH = "AnimGraph"
BLENDSPACE = "/Game/Characters/Mannequin/Animations/BS_VolleyballLocomotion"
# The node the locomotion pose has to arrive at: the entry to the component-space
# chain that carries the bone controls and the IK rig.
LOCOMOTION_SINK = ("AnimGraphNode_LocalToComponentSpace_0", "LocalPose")


def mcp(cmd: str, params: dict | None = None) -> dict:
    resp = _tcp_send_raw(cmd, params or {})
    if resp.get("status") == "error":
        raise RuntimeError(f"{cmd}: {resp.get('error')}")
    inner = resp.get("result", resp)
    if isinstance(inner, dict) and inner.get("success") is False:
        raise RuntimeError(f"{cmd}: {inner.get('error', inner)}")
    return inner


def py(code: str):
    resp = _tcp_send_raw("execute_python", {"code": code})
    if resp.get("status") == "error":
        raise RuntimeError(resp.get("error"))
    inner = resp.get("result", {})
    if isinstance(inner, dict) and inner.get("success") is False:
        raise RuntimeError(inner.get("error", inner))
    return inner.get("result", inner)


def existing_blendspace_node() -> str | None:
    r = mcp("analyze_blueprint_graph", {
        "blueprint_path": ABP, "graph_name": GRAPH,
        "include_node_details": False, "include_pin_connections": False,
        "trace_execution_flow": False,
    })
    for n in r.get("graph_data", {}).get("nodes", []):
        if n.get("class") == "AnimGraphNode_BlendSpacePlayer":
            return n.get("name")
    return None


def main() -> int:
    node_id = existing_blendspace_node()
    if node_id:
        print(f"== reusing {node_id} ==")
    else:
        node_id = mcp("add_blueprint_node", {
            "blueprint_name": ABP,
            "node_type": "/Script/AnimGraph.AnimGraphNode_BlendSpacePlayer",
            "node_params": {"function_name": GRAPH, "pos_x": -640, "pos_y": -420},
        }).get("node_id")
        print(f"== added {node_id} ==")

    py(f"""
import unreal
abp = unreal.load_asset('{ABP}')
gn = [n for n in abp.get_nodes_of_class(unreal.AnimGraphNode_BlendSpacePlayer)
      if n.get_name() == '{node_id}'][0]
an = gn.get_editor_property('Node')
an.set_editor_property('BlendSpace', unreal.load_asset('{BLENDSPACE}'))
gn.set_editor_property('Node', an)
result = 'blendspace set'
""")
    print(f"  blendspace = {BLENDSPACE}")

    speed_get = mcp("add_blueprint_node", {
        "blueprint_name": ABP, "node_type": "VariableGet",
        "node_params": {"function_name": GRAPH, "pos_x": -900, "pos_y": -380,
                        "variable_name": "Speed"},
    }).get("node_id")

    for src, src_pin, dst, dst_pin in (
        (speed_get, "Speed", node_id, "X"),
        (node_id, "Pose", LOCOMOTION_SINK[0], LOCOMOTION_SINK[1]),
    ):
        mcp("connect_nodes", {
            "blueprint_name": ABP, "source_node_id": src, "source_pin_name": src_pin,
            "target_node_id": dst, "target_pin_name": dst_pin, "function_name": GRAPH,
        })
        print(f"  connect {src}.{src_pin} -> {dst}.{dst_pin}")

    mcp("compile_blueprint", {"blueprint_name": ABP})
    py(f"import unreal\nunreal.EditorAssetLibrary.save_asset('{ABP}')\nresult='saved'")
    print("compiled and saved")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
