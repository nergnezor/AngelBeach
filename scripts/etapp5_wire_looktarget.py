#!/usr/bin/env python3
"""Expose LookAtLocation pin and wire LookTarget into ABP_VolleyballPlayer."""
from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Plugins", "UnrealMCP"))
os.chdir(ROOT)

from unrealmcp._tcp_bridge import _tcp_send_raw  # noqa: E402

ABP = "/Game/Characters/Mannequin/ABP_VolleyballPlayer"
GRAPH = "AnimGraph"
LOOK_NODE = "AnimGraphNode_LookAt_0"


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


def node_pins(name: str) -> list[str]:
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
        if n.get("name") == name:
            return [p.get("name", "") for p in n.get("pins", [])]
    return []


def node_exists(name: str) -> bool:
    return bool(node_pins(name) or mcp(
        "analyze_blueprint_graph",
        {
            "blueprint_path": ABP,
            "graph_name": GRAPH,
            "include_node_details": False,
            "include_pin_connections": False,
            "trace_execution_flow": False,
        },
    ).get("graph_data", {}).get("nodes"))


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


def main() -> int:
    wait_port()

    print("== expose LookAtLocation pin ==")
    mcp(
        "set_node_property",
        {
            "blueprint_name": ABP,
            "node_id": LOOK_NODE,
            "property_name": "show_pin",
            "property_value": "LookAtLocation",
            "function_name": GRAPH,
        },
    )

    pins = node_pins(LOOK_NODE)
    print(f"  LookAt pins: {pins}")
    if "LookAtLocation" not in pins:
        raise RuntimeError("LookAtLocation pin missing after show_pin")

    print("== wire LookTarget ==")
    target_get = "K2Node_VariableGet_LookTarget"
    if not any(
        n.get("name") == target_get
        for n in mcp(
            "analyze_blueprint_graph",
            {
                "blueprint_path": ABP,
                "graph_name": GRAPH,
                "include_node_details": False,
                "include_pin_connections": False,
                "trace_execution_flow": False,
            },
        ).get("graph_data", {}).get("nodes", [])
    ):
        target_get = ensure_node("VariableGet", 480, 80, variable_name="LookTarget")

    connect(target_get, "LookTarget", LOOK_NODE, "LookAtLocation")

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
    print("OK — LookTarget wired")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
