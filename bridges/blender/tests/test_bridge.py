from __future__ import annotations

import json
import socket
import stat
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace


BRIDGE_ROOT = Path(__file__).resolve().parents[1]
import sys

sys.path.insert(0, str(BRIDGE_ROOT))

from open_desktop_tutor_blender.observer import observe_state
from open_desktop_tutor_blender.protocol import BridgeProtocolError, dispatch_request
from open_desktop_tutor_blender.server import BlenderBridgeRuntime


class ImmediateTimers:
    def register(self, callback, first_interval=0.0):
        self.first_interval = first_interval
        return callback()


class FakeObject:
    def __init__(self, name: str, object_type: str, modifiers=()):
        self.name = name
        self.type = object_type
        self.modifiers = list(modifiers)
        self.location = [1.0, 2.0, 3.0]
        self.rotation_euler = [0.0, 0.25, 0.5]
        self.scale = [1.0, 1.0, 1.0]
        self.data = SimpleNamespace(vertices=range(8), edges=range(12), polygons=range(6))

    def select_get(self):
        return True

    def visible_get(self):
        return True


def fake_bpy():
    bevel = SimpleNamespace(name="Bevel", type="BEVEL", show_viewport=True, show_render=True)
    cube = FakeObject("Cube", "MESH", [bevel])
    properties_space = SimpleNamespace(context="MODIFIER")
    properties_area = SimpleNamespace(
        type="PROPERTIES", width=320, height=900, ui_type="PROPERTIES", spaces=SimpleNamespace(active=properties_space)
    )
    viewport_area = SimpleNamespace(type="VIEW_3D", width=1200, height=900, ui_type="VIEW_3D", spaces=None)
    scene = SimpleNamespace(name="Scene", objects=[cube])
    context = SimpleNamespace(
        scene=scene,
        mode="OBJECT",
        active_object=cube,
        view_layer=SimpleNamespace(objects=SimpleNamespace(active=cube)),
        screen=SimpleNamespace(areas=[viewport_area, properties_area]),
    )
    return SimpleNamespace(
        context=context,
        app=SimpleNamespace(version=(5, 2, 0), version_string="5.2.0", timers=ImmediateTimers()),
    )


def request(token: str, operation: str, payload=None):
    return {
        "protocol_version": 1,
        "request_id": "request-1234",
        "token": token,
        "operation": operation,
        "payload": payload or {},
    }


class BlenderBridgeTests(unittest.TestCase):
    def test_observer_returns_bounded_semantic_state(self):
        state = observe_state(fake_bpy())
        self.assertEqual(state["blender"]["version_string"], "5.2.0")
        self.assertEqual(state["mode"], "OBJECT")
        self.assertEqual(state["active_object"]["type"], "MESH")
        self.assertEqual(state["active_object"]["modifiers"][0]["type"], "BEVEL")
        self.assertEqual(state["properties_contexts"], ["MODIFIER"])

    def test_protocol_denies_wrong_token(self):
        with self.assertRaisesRegex(BridgeProtocolError, "invalid bridge session token") as raised:
            dispatch_request(request("x" * 32, "ping"), expected_token="y" * 32, bpy_module=fake_bpy())
        self.assertEqual(raised.exception.code, "UNAUTHORIZED")

    def test_protocol_denies_arbitrary_code(self):
        token = "t" * 32
        with self.assertRaisesRegex(BridgeProtocolError, "not allowlisted") as raised:
            dispatch_request(
                request(token, "execute_code", {"code": "import os"}),
                expected_token=token,
                bpy_module=fake_bpy(),
            )
        self.assertEqual(raised.exception.code, "OPERATION_DENIED")

    def test_loopback_server_uses_owner_only_descriptor_and_main_thread_dispatch(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            runtime = BlenderBridgeRuntime(fake_bpy(), descriptor_directory=temporary_directory)
            descriptor_path = runtime.start()
            try:
                descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
                mode = stat.S_IMODE(descriptor_path.stat().st_mode)
                self.assertEqual(mode, 0o600)
                self.assertEqual(descriptor["host"], "127.0.0.1")
                self.assertTrue(descriptor["read_only"])

                with socket.create_connection((descriptor["host"], descriptor["port"]), timeout=2.0) as client:
                    payload = json.dumps(request(descriptor["token"], "observe_state")).encode("utf-8") + b"\n"
                    client.sendall(payload)
                    response = b""
                    while not response.endswith(b"\n"):
                        response += client.recv(65536)
                decoded = json.loads(response)
                self.assertTrue(decoded["ok"])
                self.assertEqual(decoded["result"]["properties_contexts"], ["MODIFIER"])
            finally:
                runtime.stop()
            self.assertFalse(descriptor_path.exists())


if __name__ == "__main__":
    unittest.main()
