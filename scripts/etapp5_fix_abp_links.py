#!/usr/bin/env python3
"""Fix inverted/cyclic AnimGraph links from incremental MCP wiring."""
from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Plugins", "UnrealMCP"))
sys.path.insert(0, ROOT)
os.chdir(ROOT)

from unrealmcp._tcp_bridge import _tcp_send_raw  # noqa: E402

ABP = "/Game/Characters/Mannequin/ABP_VolleyballPlayer"
GRAPH = "AnimGraph"


def mcp(cmd, params=None):
    resp = _tcp_send_raw(cmd, params or {})
    if resp.get("status") == "error":
        raise RuntimeError(f"{cmd}: {resp.get('error')}")
    inner = resp.get("result", resp)
    if isinstance(inner, dict) and inner.get("success") is False:
        raise RuntimeError(f"{cmd}: {inner.get('error', inner)}")
    return inner


def py(code):
    resp = _tcp_send_raw("execute_python", {"code": code})
    if resp.get("status") == "error":
        raise RuntimeError(resp.get("error"))
    inner = resp.get("result", {})
    if isinstance(inner, dict) and inner.get("success") is False:
        raise RuntimeError(inner.get("error", inner))


def connect(src, src_pin, dst, dst_pin):
    mcp("connect_nodes", {
        "blueprint_name": ABP,
        "source_node_id": src,
        "source_pin_name": src_pin,
        "target_node_id": dst,
        "target_pin_name": dst_pin,
        "function_name": GRAPH,
    })
    print(f"  connect {src}.{src_pin} -> {dst}.{dst_pin}")


def delete(node_id):
    mcp("delete_node", {"blueprint_name": ABP, "node_id": node_id, "function_name": GRAPH})
    print(f"  delete {node_id}")


def ensure_node(node_type, pos_x, pos_y, **extra):
    params = {"function_name": GRAPH, "pos_x": pos_x, "pos_y": pos_y, **extra}
    r = mcp("add_blueprint_node", {"blueprint_name": ABP, "node_type": node_type, "node_params": params})
    nid = r.get("node_id")
    print(f"  add {node_type} -> {nid}")
    return nid


def node_exists(name):
    r = mcp("analyze_blueprint_graph", {
        "blueprint_path": ABP, "graph_name": GRAPH,
        "include_node_details": False, "include_pin_connections": False, "trace_execution_flow": False,
    })
    return any(n.get("name") == name for n in r.get("graph_data", {}).get("nodes", []))


def wait_port(timeout=120.0):
    import time
    port_file = os.path.join(ROOT, "Saved", "UnrealMCP", "port.txt")
    t0 = time.time()
    while time.time() - t0 < timeout:
        if os.path.isfile(port_file):
            print(f"MCP port {open(port_file).read().strip()}")
            return
        time.sleep(2)
    raise TimeoutError("no MCP port")


def main() -> int:
    wait_port()

    print("== reset LookAt node (clears bad links) ==")
    if node_exists("AnimGraphNode_LookAt_0"):
        delete("AnimGraphNode_LookAt_0")
    for orphan in [f"K2Node_VariableGet_{i}" for i in range(15, 30)]:
        if node_exists(orphan):
            delete(orphan)

    print("== recreate LookAt ==")
    look_id = ensure_node("/Script/AnimGraph.AnimGraphNode_LookAt", 520, 160)
    py(
        f"""
import unreal
abp = unreal.load_asset('/Game/Characters/Mannequin/ABP_VolleyballPlayer')
ln = [n for n in abp.get_nodes_of_class(unreal.AnimGraphNode_LookAt) if n.get_name()=='{look_id}'][0]
an = ln.get_editor_property('Node')
br = unreal.BoneReference()
br.set_editor_property('bone_name', 'head')
an.set_editor_property('BoneToModify', br)
ln.set_editor_property('Node', an)
result = 'ok'
"""
    )

    look_alpha = ensure_node("VariableGet", 480, 140, variable_name="LookAlpha")
    speed_get = ensure_node("VariableGet", -320, -420, variable_name="Speed")
    connect(speed_get, "Speed", "AnimGraphNode_BlendSpacePlayer_0", "X")
    connect("AnimGraphNode_BlendSpacePlayer_0", "Pose", "AnimGraphNode_LocalToComponentSpace_0", "LocalPose")

    print("== chain: IKRig -> LookAt -> Root ==")
    connect("AnimGraphNode_IKRig_0", "Pose", look_id, "ComponentPose")
    connect(look_alpha, "LookAlpha", look_id, "Alpha")
    connect(look_id, "Pose", "AnimGraphNode_Root_0", "Result")

    mcp("compile_blueprint", {"blueprint_name": ABP})
    py(
        """
import unreal
abp = unreal.load_asset('/Game/Characters/Mannequin/ABP_VolleyballPlayer')
unreal.EditorAssetLibrary.save_loaded_asset(abp, only_if_is_dirty=False)
result = 'saved'
"""
    )
    print("OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
