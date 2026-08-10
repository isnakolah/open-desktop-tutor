#!/usr/bin/env python3
"""Bind the single private Calla Mac node after its first OpenClaw connection."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from typing import Any


def run(command: list[str], *, input_text: str | None = None) -> str:
    result = subprocess.run(command, input=input_text, capture_output=True, text=True, check=False)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or "no diagnostic output"
        raise RuntimeError(f"{' '.join(command[:3])} failed: {detail}")
    return result.stdout


def pending_calla_nodes(binary: str, display_name: str) -> list[dict[str, Any]]:
    raw = run([binary, "nodes", "pending", "--json"])
    parsed = json.loads(raw)
    if not isinstance(parsed, list):
        raise RuntimeError("OpenClaw returned an invalid pending-node response")
    return [
        node
        for node in parsed
        if isinstance(node, dict)
        and node.get("displayName") == display_name
        and isinstance(node.get("requestId"), str)
        and isinstance(node.get("nodeId"), str)
    ]


def enroll_one(binary: str, display_name: str) -> bool:
    pending = pending_calla_nodes(binary, display_name)
    if not pending:
        return False
    if len(pending) != 1:
        raise RuntimeError(f"refusing to auto-enroll {len(pending)} pending nodes named {display_name!r}")
    node = pending[0]
    run([binary, "nodes", "approve", node["requestId"], "--json"])
    patch = {"plugins": {"entries": {"desktop-tutor": {"enabled": True, "config": {"nodeId": node["nodeId"]}}}}}
    run([binary, "config", "patch", "--stdin"], input_text=json.dumps(patch))
    run([binary, "config", "validate"])
    print(f"Enrolled Calla Mac node {node['nodeId']}.")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openclaw-bin", default="openclaw")
    parser.add_argument("--display-name", default="Calla Mac")
    parser.add_argument("--watch", action="store_true", help="poll until a matching Mac connects")
    parser.add_argument("--interval", type=float, default=3.0)
    arguments = parser.parse_args()
    if arguments.interval <= 0:
        parser.error("--interval must be positive")
    try:
        while True:
            if enroll_one(arguments.openclaw_bin, arguments.display_name):
                return 0
            if not arguments.watch:
                print("No pending Calla Mac node yet.")
                return 0
            time.sleep(arguments.interval)
    except (RuntimeError, json.JSONDecodeError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
