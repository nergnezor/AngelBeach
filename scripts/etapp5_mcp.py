#!/usr/bin/env python3
"""Thin MCP TCP client for Etapp 5 Anim BP work (UnrealMCP C++ bridge)."""
from __future__ import annotations

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Plugins", "UnrealMCP"))

from unrealmcp._tcp_bridge import _tcp_send_raw  # noqa: E402

ABP = "/Game/Characters/Mannequin/ABP_VolleyballPlayer"


def call(cmd: str, params: dict | None = None) -> dict:
    os.chdir(ROOT)
    resp = _tcp_send_raw(cmd, params or {})
    return resp


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: etapp5_mcp.py <command> [json-params]", file=sys.stderr)
        return 2
    cmd = sys.argv[1]
    params = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    out = call(cmd, params)
    print(json.dumps(out, indent=2, default=str))
    return 0 if out.get("status") != "error" and out.get("success") is not False else 1


if __name__ == "__main__":
    raise SystemExit(main())
