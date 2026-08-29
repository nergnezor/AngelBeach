#!/usr/bin/env python3
"""Etapp 5: wire MM_Death dive clip into ABP when bDiving is true."""
from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Plugins", "UnrealMCP"))
os.chdir(ROOT)

from unrealmcp._tcp_bridge import _tcp_send_raw  # noqa: E402

ABP = "/Game/Characters/Mannequin/ABP_VolleyballPlayer"
GRAPH = "AnimGraph"
DIVE_ANIM = "/Game/Characters/Mannequins/Anims/Death/MM_Death_Front_01"


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


def find_look_at_node(names: set[str]) -> str:
    # Prefer the node wired into the output chain (fix script creates _3).
    for n in ("AnimGraphNode_LookAt_3", "AnimGraphNode_LookAt_0"):
        if n in names:
            return n
    for n in sorted(names):
        if n.startswith("AnimGraphNode_LookAt_"):
            return n
    raise RuntimeError("no LookAt node in AnimGraph")


def main() -> int:
    wait_port()
    names = node_names()
    look_node = find_look_at_node(names)

    print(f"== LookAt node: {look_node} ==")

    # LookTarget while we're here (LookAt was recreated as _3 by fix script).
    print("== wire LookTarget ==")
    mcp(
        "set_node_property",
        {
            "blueprint_name": ABP,
            "node_id": look_node,
            "property_name": "show_pin",
            "property_value": "LookAtLocation",
            "function_name": GRAPH,
        },
    )
    look_pins = node_pins(look_node)
    print(f"  pins: {look_pins}")
    if "LookAtLocation" in look_pins and "K2Node_VariableGet_LookTarget" not in names:
        tgt = ensure_node("VariableGet", 480, 80, variable_name="LookTarget")
        connect(tgt, "LookTarget", look_node, "LookAtLocation")

    print("== dive blend (skip if already wired) ==")
    if "AnimGraphNode_BlendListByBool_Dive" in names:
        print("  already wired")
    else:
        dive_seq = ensure_node(
            "/Script/AnimGraph.AnimGraphNode_SequencePlayer", 720, -200
        )
        dive_ltcs = ensure_node(
            "/Script/AnimGraph.AnimGraphNode_LocalToComponentSpace", 900, -200
        )
        dive_blend = ensure_node(
            "/Script/AnimGraph.AnimGraphNode_BlendListByBool", 1080, 80
        )

        mcp(
            "execute_python",
            {
                "code": f"""
import unreal
abp = unreal.load_asset('{ABP}')
seq_nodes = [n for n in abp.get_nodes_of_class(unreal.AnimGraphNode_SequencePlayer) if n.get_name()=='{dive_seq}']
if not seq_nodes:
    raise RuntimeError('dive seq missing')
sn = seq_nodes[0]
anim = sn.get_editor_property('Node')
anim.set_editor_property('Sequence', unreal.load_asset('{DIVE_ANIM}'))
sn.set_editor_property('Node', anim)
result = 'seq ok'
"""
            },
        )

        connect(dive_seq, "Pose", dive_ltcs, "LocalPose")
        connect(look_node, "Pose", dive_blend, "BlendPose_0")
        connect(dive_ltcs, "ComponentPose", dive_blend, "BlendPose_1")
        dive_get = ensure_node("VariableGet", 1040, 180, variable_name="bDiving")
        connect(dive_get, "bDiving", dive_blend, "bActiveValue")
        connect(dive_blend, "Pose", "AnimGraphNode_Root_0", "Result")

        # Rename for idempotency marker via comment isn't possible; use execute_python rename
        mcp(
            "execute_python",
            {
                "code": f"""
import unreal
abp = unreal.load_asset('{ABP}')
for n in abp.get_nodes_of_class(unreal.AnimGraphNode_BlendListByBool):
    if n.get_name() == '{dive_blend}':
        n.set_editor_property('NodeComment', 'DiveBlend')
        break
result = 'marked'
"""
            },
        )

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
    print("OK — dive wired")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
