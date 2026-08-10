#!/usr/bin/env python3
"""Exercise Calla's screenshot-only teaching path against a running TutorHost.

This walks the same operations the Gateway model calls — observe, guide,
narrate — for any application, not just one with an authored pack. Nothing here
reads the Accessibility tree, and nothing here can click.

    python3 tools/calla_guide_probe.py --bundle-id org.blenderfoundation.blender

Pass --capture-out to write the observed window JPEG somewhere you can look at
it; that image is exactly what would cross the tailnet to the model.
"""
import argparse
import base64
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tutor_host_probe import req, send  # noqa: E402


def frontmost_bundle_id():
    result = subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to get bundle identifier of first application process whose frontmost is true'],
        capture_output=True, text=True)
    return result.stdout.strip()


def focus(bundle_id, timeout=20):
    """`activate` loses the focus race often enough to be worth waiting out."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        subprocess.run(["osascript", "-e", f'tell application id "{bundle_id}" to activate'],
                       capture_output=True)
        time.sleep(1.0)
        if frontmost_bundle_id() == bundle_id:
            return True
    return False


def step(number, title):
    print(f"\n--- {number}. {title} " + "-" * max(0, 54 - len(title)))


def show(response):
    body = response.get("payload") if response.get("ok") else response.get("error")
    print("   ", json.dumps(body))
    return response.get("ok", False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", default="org.blenderfoundation.blender")
    parser.add_argument("--capture-out", type=Path,
                        help="Write the observed window JPEG here for inspection")
    parser.add_argument("--region", default="0.82,0.20,0.03,0.03",
                        help="left,top,width,height normalized to the observed window")
    parser.add_argument("--no-focus", action="store_true",
                        help="Use whatever is already focused")
    arguments = parser.parse_args()

    if not arguments.no_focus and not focus(arguments.bundle_id):
        print(f"Could not focus {arguments.bundle_id}; frontmost is {frontmost_bundle_id()}")
        return 2

    allowed = {"allowed_bundle_ids": [arguments.bundle_id]}

    step(1, "observe the focused window, with a capture")
    response = send(req("observe", {**allowed, "include_capture": True}), timeout=60)
    if not response.get("ok"):
        show(response)
        return 1
    payload = response["payload"]
    snapshot_id = payload["snapshot_id"]
    capture = payload.get("capture") or {}
    jpeg = base64.b64decode(capture["base64"]) if capture.get("base64") else b""
    print(f"   snapshot : {snapshot_id}")
    print(f"   app      : {payload.get('app_bundle_id')} {payload.get('app_version', '')}")
    print(f"   capture  : {len(jpeg)} bytes, jpeg={jpeg[:3] == bytes([0xFF, 0xD8, 0xFF])}")
    if arguments.capture_out and jpeg:
        arguments.capture_out.write_bytes(jpeg)
        print(f"   wrote    : {arguments.capture_out}")

    left, top, width, height = (float(part) for part in arguments.region.split(","))
    step(2, "guide: point at a region the model read off that capture")
    ok = show(send(req("guide", {
        **allowed,
        "snapshot_id": snapshot_id,
        "region": {"left": left, "top": top, "width": width, "height": height},
        "step": "Step 1 of 2",
        "text": "This is the control the lesson is about. Nothing was clicked.",
        "status": "Calla — teaching",
    }), timeout=30))
    if not ok:
        return 1

    step(3, "narrate: change the tooltip without moving the cursor")
    time.sleep(2.5)
    show(send(req("narrate", {
        "step": "Step 2 of 2",
        "text": "Same cursor, new words. This is how a lesson keeps talking.",
        "status": "Calla — narrating",
        "thinking": True,
    }), timeout=30))

    step(4, "the boundary still holds")
    checks = [
        ("pixel region on guide", req("guide", {
            **allowed, "snapshot_id": snapshot_id,
            "region": {"left": 1420, "top": 377, "width": 24, "height": 24}, "text": "x"})),
        ("raw click(x,y)", req("click", {"x": 100, "y": 200})),
        ("region on an action", req("propose_action", {
            "action": "click", "snapshot_id": snapshot_id,
            "region": {"left": 0.5, "top": 0.5, "width": 0.1, "height": 0.1},
            "expected_state": {}, "rationale": "nope"})),
    ]
    for name, request in checks:
        result = send(request, timeout=20)
        print(f"   {name:24} -> {(result.get('error') or {}).get('code', 'ok')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
