#!/usr/bin/env python3
"""Etapp 5: bump | (set <-> spike) hit clips via BlendListByInt + TwoWayBlend."""
from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Plugins", "UnrealMCP"))
os.chdir(ROOT)

from unrealmcp._tcp_bridge import _tcp_send_raw  # noqa: E402

ABP = "/Game/Characters/Mannequin/ABP_VolleyballPlayer"
GRAPH = "AnimGraph"
CLIPS = {
    "bump": "/Game/Characters/Mannequins/Anims/Unarmed/Attack/MM_Attack_03",
    "set": "/Game/Characters/Mannequins/Anims/Unarmed/Attack/MM_Attack_02",
    "spike": "/Game/Characters/Mannequins/Anims/Unarmed/Attack/MM_Attack_01",
}
HIT_PICK = "AnimGraphNode_BlendListByInt_1"
HIT_OVERLAY = "AnimGraphNode_TwoWayBlend_2"


def mcp(cmd: str, params: dict | None = None) -> dict:
    resp = _tcp_send_raw(cmd, params or {})
    if resp.get("status") == "error":
        raise RuntimeError(f"{cmd}: {resp.get('error')}")
    inner = resp.get("result", resp)
    if isinstance(inner, dict) and inner.get("success") is False:
        raise RuntimeError(f"{cmd}: {inner.get('error', inner)}")
    return inner


def wait_port(timeout: float = 180.0) -> None:
    import time

    port_file = os.path.join(ROOT, "Saved", "UnrealMCP", "port.txt")
    t0 = time.time()
    while time.time() - t0 < timeout:
        if os.path.isfile(port_file):
            print(f"MCP port {open(port_file).read().strip()}")
            return
        time.sleep(2)
    raise TimeoutError("UnrealMCP port.txt not found")


def node_names() -> set[str]:
    r = mcp(
        "analyze_blueprint_graph",
        {
            "blueprint_path": ABP,
            "graph_name": GRAPH,
            "include_node_details": False,
            "include_pin_connections": False,
            "trace_execution_flow": False,
        },
    )
    return {n.get("name", "") for n in r.get("graph_data", {}).get("nodes", [])}


def connect(src: str, src_pin: str, dst: str, dst_pin: str) -> None:
    mcp(
        "connect_nodes",
        {
            "blueprint_name": ABP,
            "source_node_id": src,
            "source_pin_name": src_pin,
            "target_node_id": dst,
            "target_pin_name": dst_pin,
            "function_name": GRAPH,
        },
    )
    print(f"  connect {src}.{src_pin} -> {dst}.{dst_pin}")


def ensure_node(node_type: str, pos_x: float, pos_y: float, **extra: str) -> str:
    params = {"function_name": GRAPH, "pos_x": pos_x, "pos_y": pos_y, **extra}
    r = mcp(
        "add_blueprint_node",
        {
            "blueprint_name": ABP,
            "node_type": node_type,
            "node_params": params,
        },
    )
    nid = r.get("node_id")
    print(f"  add {node_type} -> {nid}")
    return nid


def set_sequence(seq_node: str, anim_path: str) -> None:
    mcp(
        "execute_python",
        {
            "code": f"""
import unreal
abp = unreal.load_asset('{ABP}')
sn = [n for n in abp.get_nodes_of_class(unreal.AnimGraphNode_SequencePlayer) if n.get_name()=='{seq_node}'][0]
anim = sn.get_editor_property('Node')
anim.set_editor_property('Sequence', unreal.load_asset('{anim_path}'))
sn.set_editor_property('Node', anim)
result = 'ok'
"""
        },
    )


def main() -> int:
    wait_port()
    names = node_names()

    if "K2Node_VariableGet_HitClipBranch" in names:
        print("hit slots already wired")
        return 0

    print("== inner set/spike TwoWayBlend ==")
    bump_ltcs = "AnimGraphNode_LocalToComponentSpace_7"
    set_ltcs = "AnimGraphNode_LocalToComponentSpace_8"
    spike_ltcs = "AnimGraphNode_LocalToComponentSpace_9"
    bump_seq = "AnimGraphNode_SequencePlayer_2"
    set_seq = "AnimGraphNode_SequencePlayer_3"
    spike_seq = "AnimGraphNode_SequencePlayer_4"

    if bump_seq not in names:
        bump_seq = ensure_node(
            "/Script/AnimGraph.AnimGraphNode_SequencePlayer", 300, -320
        )
        bump_ltcs = ensure_node(
            "/Script/AnimGraph.AnimGraphNode_LocalToComponentSpace", 400, -320
        )
        connect(bump_seq, "Pose", bump_ltcs, "LocalPose")
        set_sequence(bump_seq, CLIPS["bump"])

    if set_seq not in names:
        set_seq = ensure_node(
            "/Script/AnimGraph.AnimGraphNode_SequencePlayer", 300, -200
        )
        set_ltcs = ensure_node(
            "/Script/AnimGraph.AnimGraphNode_LocalToComponentSpace", 400, -200
        )
        connect(set_seq, "Pose", set_ltcs, "LocalPose")
        set_sequence(set_seq, CLIPS["set"])

    if spike_seq not in names:
        spike_seq = ensure_node(
            "/Script/AnimGraph.AnimGraphNode_SequencePlayer", 300, -80
        )
        spike_ltcs = ensure_node(
            "/Script/AnimGraph.AnimGraphNode_LocalToComponentSpace", 400, -80
        )
        connect(spike_seq, "Pose", spike_ltcs, "LocalPose")
        set_sequence(spike_seq, CLIPS["spike"])
    else:
        set_sequence(bump_seq, CLIPS["bump"])
        set_sequence(set_seq, CLIPS["set"])
        set_sequence(spike_seq, CLIPS["spike"])

    inner = ensure_node("/Script/AnimGraph.AnimGraphNode_TwoWayBlend", 520, -140)
    connect(set_ltcs, "ComponentPose", inner, "A")
    connect(spike_ltcs, "ComponentPose", inner, "B")
    blend_get = ensure_node("VariableGet", 560, -40, variable_name="HitSetSpikeBlend")
    connect(blend_get, "HitSetSpikeBlend", inner, "Alpha")

    print("== outer bump | upper BlendListByInt ==")
    if HIT_PICK not in names:
        raise RuntimeError(f"missing {HIT_PICK}")
    connect(bump_ltcs, "ComponentPose", HIT_PICK, "BlendPose_0")
    connect(inner, "Pose", HIT_PICK, "BlendPose_1")
    branch_get = ensure_node("VariableGet", 600, -40, variable_name="HitClipBranch")
    connect(branch_get, "HitClipBranch", HIT_PICK, "ActiveChildIndex")
    connect(HIT_PICK, "Pose", HIT_OVERLAY, "B")

    print("== compile + save ==")
    mcp("compile_blueprint", {"blueprint_name": ABP})
    mcp(
        "execute_python",
        {
            "code": """
import unreal
abp = unreal.load_asset('/Game/Characters/Mannequin/ABP_VolleyballPlayer')
unreal.EditorAssetLibrary.save_loaded_asset(abp, only_if_is_dirty=False)
result = 'saved'
"""
        },
    )
    print("OK — bump | set/spike hit slots wired")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
