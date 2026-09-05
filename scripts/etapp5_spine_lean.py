#!/usr/bin/env python3
"""Add the trunk-lean correction to ABP_VolleyballPlayer's AnimGraph.

The locomotion blendspace leans the trunk 28 degrees off vertical while running
against 8-9 standing — measured, and identical on every player to the degree,
which is what an authored pose looks like rather than anything the script does.
A human at the pace these players keep (53% of top speed) leans 5-10.

No bone setter is bound in this fork, so the correction has to be a graph node:
a Transform (Modify) Bone on spine_02, additive, in COMPONENT space, whose Alpha
is driven by SpineLeanAlpha (the pace, 0..1). Component space on purpose — a
pitch about the component Y axis is a clean forward/back trunk lean, where bone
space on the spine would be the same guessing game the arms were.

The ANGLE is the node's own Rotation default, so it can be swept from here and
graded against the tiltRun telemetry without touching the script.

IT DOES NOT WORK YET, and the two reasons found while proving that are worth
more than the node is:

NO BONE-NAME SKELETAL CONTROL IN THIS GRAPH DOES ANYTHING. Every node is
reachable from Output Pose — checked with scripts/etapp5_reachability.py, which
walks the pose graph using real pin DIRECTIONS — so this is not a wiring
problem. It is that the controls have no effect:

  spine_02, additive, component space, 13 deg   trunk lean 28
  the same at 60 deg                            trunk lean 28
  the same with alpha forced to 1, pin broken   trunk lean 28
  pointed at PELVIS, the bone the existing
  Modify Bone already drives, at 60 deg         trunk lean 28

The likely cause is the mismatch VolleyballPlayer.as already warns about: the
ABP targets /MoverExamples/.../SK_Mannequin while the mesh references
/Game/Characters/Mannequins/Meshes/SK_Mannequin. Bone-name controls resolve
against the ABP's skeleton; the IK Rig node keeps working because it resolves
through its own rig asset, which is why the hands reach the ball and nothing
else moves.

What that costs, beyond this node: the pelvis plant, both foot Two Bone IKs and
the head LookAt are all bone-name controls. And CrouchAmount has no consumer in
the graph at all — it reaches the skeleton only through PelvisTarget, which the
inert pelvis node reads. So every knee bend, hip sink, split-step dip and
leg-drive-through-the-ball the script computes is measured and thrown away.

So: fix the skeleton before trusting any Modify Bone in this graph.

    ./scripts/etapp5_spine_lean.py            install at the default angle
    ./scripts/etapp5_spine_lean.py 9          install/retune to 9 degrees
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
SPINE_BONE = "spine_02"
DEFAULT_PITCH = 13.0


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


def graph_nodes() -> list:
    r = mcp("analyze_blueprint_graph", {
        "blueprint_path": ABP, "graph_name": GRAPH,
        "include_node_details": False, "include_pin_connections": False,
        "trace_execution_flow": False,
    })
    return r.get("graph_data", {}).get("nodes", [])


def find_spine_node() -> str | None:
    for n in graph_nodes():
        if n.get("class") == "AnimGraphNode_ModifyBone" and SPINE_BONE in (n.get("title") or ""):
            return n.get("name")
    return None


def configure(node_id: str, pitch: float) -> None:
    py(f"""
import unreal
abp = unreal.load_asset('{ABP}')
gn = [n for n in abp.get_nodes_of_class(unreal.AnimGraphNode_ModifyBone)
      if n.get_name() == '{node_id}'][0]
an = gn.get_editor_property('Node')
br = unreal.BoneReference()
br.set_editor_property('bone_name', '{SPINE_BONE}')
an.set_editor_property('BoneToModify', br)
an.set_editor_property('TranslationMode', unreal.BoneModificationMode.BMM_IGNORE)
an.set_editor_property('ScaleMode', unreal.BoneModificationMode.BMM_IGNORE)
an.set_editor_property('RotationMode', unreal.BoneModificationMode.BMM_ADDITIVE)
an.set_editor_property('RotationSpace', unreal.BoneControlSpace.BCS_COMPONENT_SPACE)
# unreal.Rotator(a, b, c) is (ROLL, PITCH, YAW), not the pitch-first order the
# struct prints in. Passing the angle positionally set Roll and left Pitch at
# zero, which is a sideways tilt: the correction measured as no correction.
rot = unreal.Rotator()
rot.set_editor_property('pitch', {pitch})
an.set_editor_property('Rotation', rot)
gn.set_editor_property('Node', an)
result = 'configured'
""")


def main() -> int:
    pitch = float(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PITCH

    node_id = find_spine_node()
    if node_id:
        print(f"== retune existing {node_id} to pitch {pitch} ==")
        configure(node_id, pitch)
    else:
        print("== install spine lean correction ==")
        r = mcp("add_blueprint_node", {
            "blueprint_name": ABP,
            "node_type": "/Script/AnimGraph.AnimGraphNode_ModifyBone",
            "node_params": {"function_name": GRAPH, "pos_x": 1600, "pos_y": 240},
        })
        node_id = r.get("node_id")
        print(f"  node {node_id}")
        configure(node_id, pitch)

        alpha_get = mcp("add_blueprint_node", {
            "blueprint_name": ABP, "node_type": "VariableGet",
            "node_params": {"function_name": GRAPH, "pos_x": 1560, "pos_y": 400,
                            "variable_name": "SpineLeanAlpha"},
        }).get("node_id")
        print(f"  alpha {alpha_get}")

        # ON THE LIVE CHAIN, which is not the one the bone modifiers sit on.
        # Traced from the output backwards, the pose that reaches Root is
        #   TwoWayBlend_2 -> IKRig_0 -> LocalToComponentSpace_6 -> LookAt_3
        #     -> ComponentToLocalSpace_3 -> BlendListByBool_0.BlendPose_1 -> Root
        # while the pelvis Modify Bone and both Two Bone IKs hang off
        # LocalToComponentSpace_0 / ComponentToLocalSpace_0, which nothing
        # downstream reads. The first version of this script spliced in there and
        # measured no change at all — tiltRun 28 before and after — which is what
        # a node on a dead branch looks like.
        #
        # So: after the head LookAt, inside the same component-space segment.
        for src, src_pin, dst, dst_pin in (
            ("AnimGraphNode_LookAt_3", "Pose", node_id, "ComponentPose"),
            (node_id, "Pose", "AnimGraphNode_ComponentToLocalSpace_3", "ComponentPose"),
            (alpha_get, "SpineLeanAlpha", node_id, "Alpha"),
        ):
            mcp("connect_nodes", {
                "blueprint_name": ABP, "source_node_id": src, "source_pin_name": src_pin,
                "target_node_id": dst, "target_pin_name": dst_pin, "function_name": GRAPH,
            })
            print(f"  connect {src}.{src_pin} -> {dst}.{dst_pin}")

    mcp("compile_blueprint", {"blueprint_name": ABP})
    py(f"""
import unreal
unreal.EditorAssetLibrary.save_asset('{ABP}')
result = 'saved'
""")
    print("compiled and saved")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
