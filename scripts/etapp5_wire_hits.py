#!/usr/bin/env python3
"""Etapp 5: blend attack clips over locomotion when bIsHitting / HitAlpha > 0."""
from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Plugins", "UnrealMCP"))
os.chdir(ROOT)

from unrealmcp._tcp_bridge import _tcp_send_raw  # noqa: E402

ABP = "/Game/Characters/Mannequin/ABP_VolleyballPlayer"
GRAPH = "AnimGraph"
# Unarmed attack clips — spike/set/bump until dedicated volleyball mocap lands.
HIT_ANIMS = {
    "spike": "/Game/Characters/Mannequins/Anims/Unarmed/Attack/MM_Attack_01",
    "set": "/Game/Characters/Mannequins/Anims/Unarmed/Attack/MM_Attack_02",
    "bump": "/Game/Characters/Mannequins/Anims/Unarmed/HitReact/Front/MM_HitReact_Front_Lgt_01",
}


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


def node_pins(name: str) -> list[str]:
    r = mcp(
        "analyze_blueprint_graph",
        {
            "blueprint_path": ABP,
            "graph_name": GRAPH,
            "include_node_details": True,
            "include_pin_connections": False,
            "trace_execution_flow": False,
        },
    )
    for n in r.get("graph_data", {}).get("nodes", []):
        if n.get("name") == name:
            return [p.get("name", "") for p in n.get("pins", [])]
    return []


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


def find_look_node(names: set[str]) -> str:
    for n in ("AnimGraphNode_LookAt_3", "AnimGraphNode_LookAt_0"):
        if n in names:
            return n
    for n in sorted(names):
        if n.startswith("AnimGraphNode_LookAt_"):
            return n
    raise RuntimeError("no LookAt node")


def main() -> int:
    wait_port()
    names = node_names()
    look_node = find_look_node(names)

    # Idempotent: skip if HitAlpha already feeds a TwoWayBlend.
    r = mcp(
        "analyze_blueprint_graph",
        {
            "blueprint_path": ABP,
            "graph_name": GRAPH,
            "include_node_details": True,
            "include_pin_connections": True,
            "trace_execution_flow": False,
        },
    )
    for n in r.get("graph_data", {}).get("nodes", []):
        if "TwoWayBlend" in n.get("name", ""):
            for p in n.get("pins", []):
                if p.get("name") == "Alpha" and p.get("linked_to"):
                    print("hit blend already wired")
                    return 0

    print("== hit overlay: TwoWayBlend between IKRig and LookAt ==")
    hit_blend = ensure_node(
        "/Script/AnimGraph.AnimGraphNode_TwoWayBlend", 640, 80
    )
    hit_seq = ensure_node(
        "/Script/AnimGraph.AnimGraphNode_SequencePlayer", 480, -80
    )
    hit_ltcs = ensure_node(
        "/Script/AnimGraph.AnimGraphNode_LocalToComponentSpace", 560, -80
    )

    mcp(
        "execute_python",
        {
            "code": f"""
import unreal
abp = unreal.load_asset('{ABP}')
sn = [n for n in abp.get_nodes_of_class(unreal.AnimGraphNode_SequencePlayer) if n.get_name()=='{hit_seq}'][0]
anim = sn.get_editor_property('Node')
anim.set_editor_property('Sequence', unreal.load_asset('{HIT_ANIMS["spike"]}'))
sn.set_editor_property('Node', anim)
result = 'seq ok'
"""
        },
    )

    connect(hit_seq, "Pose", hit_ltcs, "LocalPose")
    connect("AnimGraphNode_IKRig_0", "Pose", hit_blend, "A")
    connect(hit_ltcs, "ComponentPose", hit_blend, "B")
    hit_alpha = ensure_node("VariableGet", 600, 200, variable_name="HitAlpha")
    connect(hit_alpha, "HitAlpha", hit_blend, "Alpha")
    connect(hit_blend, "Pose", look_node, "ComponentPose")

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
    print("OK — hit overlay wired")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
