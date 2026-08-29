#!/usr/bin/env python3
"""Etapp 5: wire BS_VolleyballLocomotion + LookAt into ABP_VolleyballPlayer via MCP."""
from __future__ import annotations

import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Plugins", "UnrealMCP"))
os.chdir(ROOT)

from unrealmcp._tcp_bridge import _tcp_send_raw  # noqa: E402

ABP = "/Game/Characters/Mannequin/ABP_VolleyballPlayer"
GRAPH = "AnimGraph"


def mcp(cmd: str, params: dict | None = None) -> dict:
    resp = _tcp_send_raw(cmd, params or {})
    if resp.get("status") == "error":
        raise RuntimeError(f"{cmd}: {resp.get('error')}")
    inner = resp.get("result", resp)
    if isinstance(inner, dict) and inner.get("success") is False:
        raise RuntimeError(f"{cmd}: {inner.get('error', inner)}")
    return inner


def py(code: str) -> dict:
    resp = _tcp_send_raw("execute_python", {"code": code})
    if resp.get("status") == "error":
        raise RuntimeError(resp.get("error"))
    inner = resp.get("result", {})
    if isinstance(inner, dict) and inner.get("success") is False:
        raise RuntimeError(inner.get("error", inner))
    return inner.get("result", inner)


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


def delete(node_id: str) -> None:
    mcp(
        "delete_node",
        {
            "blueprint_name": ABP,
            "node_id": node_id,
            "function_name": GRAPH,
        },
    )
    print(f"  delete {node_id}")


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
    if not nid:
        raise RuntimeError(f"add {node_type} returned no node_id: {r}")
    print(f"  add {node_type} -> {nid}")
    return nid


def wait_port(timeout: float = 120.0) -> None:
    port_file = os.path.join(ROOT, "Saved", "UnrealMCP", "port.txt")
    t0 = time.time()
    while time.time() - t0 < timeout:
        if os.path.isfile(port_file):
            print(f"MCP port {open(port_file).read().strip()}")
            return
        time.sleep(2)
    raise TimeoutError("UnrealMCP port.txt not found — is the editor running?")


def node_exists(name: str) -> bool:
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
    nodes = r.get("graph_data", {}).get("nodes", [])
    return any(n.get("name") == name for n in nodes)


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--wait":
        wait_port()
        return 0

    wait_port()

    print("== ensure anim graph nodes ==")
    if not node_exists("AnimGraphNode_BlendSpacePlayer_0"):
        ensure_node("/Script/AnimGraph.AnimGraphNode_BlendSpacePlayer", -400, -500)
    if not node_exists("AnimGraphNode_LookAt_0"):
        ensure_node("/Script/AnimGraph.AnimGraphNode_LookAt", 520, 160)

    print("== configure blendspace + look-at bone ==")
    py(
        """
import unreal
abp = unreal.load_asset('/Game/Characters/Mannequin/ABP_VolleyballPlayer')
bs_nodes = abp.get_nodes_of_class(unreal.AnimGraphNode_BlendSpacePlayer)
if not bs_nodes:
    raise RuntimeError('BlendSpacePlayer missing')
bs_node = bs_nodes[0]
anim = bs_node.get_editor_property('Node')
anim.set_editor_property('BlendSpace', unreal.load_asset('/Game/Characters/Mannequin/Animations/BS_VolleyballLocomotion'))
bs_node.set_editor_property('Node', anim)
look_nodes = abp.get_nodes_of_class(unreal.AnimGraphNode_LookAt)
if look_nodes:
    ln = look_nodes[0]
    an = ln.get_editor_property('Node')
    br = unreal.BoneReference()
    br.set_editor_property('bone_name', 'head')
    an.set_editor_property('BoneToModify', br)
    ln.set_editor_property('Node', an)
result = {'blendspace': True, 'lookat_bone': bool(look_nodes)}
"""
    )

    print("== wire locomotion ==")
    if not node_exists("K2Node_VariableGet_21"):
        speed_get = ensure_node("VariableGet", -320, -420, variable_name="Speed")
        connect(speed_get, "Speed", "AnimGraphNode_BlendSpacePlayer_0", "X")
    connect("AnimGraphNode_BlendSpacePlayer_0", "Pose", "AnimGraphNode_LocalToComponentSpace_0", "LocalPose")

    print("== remove old binary locomotion ==")
    for nid in [
        "AnimGraphNode_BlendListByBool_0",
        "AnimGraphNode_SequencePlayer_0",
        "AnimGraphNode_SequencePlayer_1",
        "AnimGraphNode_SequencePlayer_2",
        "K2Node_VariableGet_0",
    ]:
        if node_exists(nid):
            delete(nid)

    print("== wire look-at chain + alpha ==")
    look_alpha = ensure_node("VariableGet", 480, 140, variable_name="LookAlpha")
    connect(look_alpha, "LookAlpha", "AnimGraphNode_LookAt_0", "Alpha")
    connect("AnimGraphNode_IKRig_0", "Pose", "AnimGraphNode_LookAt_0", "ComponentPose")
    connect("AnimGraphNode_LookAt_0", "Pose", "AnimGraphNode_Root_0", "Result")

    # Expose LookAtLocation via MCP show_pin (ReconstructNode) then wire LookTarget.
    mcp(
        "set_node_property",
        {
            "blueprint_name": ABP,
            "node_id": "AnimGraphNode_LookAt_0",
            "property_name": "show_pin",
            "property_value": "LookAtLocation",
            "function_name": GRAPH,
        },
    )
    look_target = ensure_node("VariableGet", 480, 80, variable_name="LookTarget")
    connect(look_target, "LookTarget", "AnimGraphNode_LookAt_0", "LookAtLocation")

    print("== compile + save ==")
    mcp("compile_blueprint", {"blueprint_name": ABP})
    py(
        """
import unreal
abp = unreal.load_asset('/Game/Characters/Mannequin/ABP_VolleyballPlayer')
unreal.EditorAssetLibrary.save_loaded_asset(abp, only_if_is_dirty=False)
result = 'saved'
"""
    )
    print("OK — ABP rewired")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
