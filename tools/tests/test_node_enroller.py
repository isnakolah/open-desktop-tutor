from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPOSITORY_ROOT / "tools" / "calla_node_enroller.py"
SPEC = importlib.util.spec_from_file_location(MODULE_PATH.stem, MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load Calla node enroller")
node_enroller = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(node_enroller)


class CallaNodeEnrollerTests(unittest.TestCase):
    def test_ignores_unrelated_pending_nodes(self) -> None:
        with patch.object(node_enroller, "run", return_value=json.dumps([
            {"requestId": "other-request", "nodeId": "other-node", "displayName": "Other Mac"},
            {"requestId": "calla-request", "nodeId": "calla-node", "displayName": "Calla Mac"},
        ])):
            self.assertEqual(node_enroller.pending_calla_nodes("openclaw", "Calla Mac"), [
                {"requestId": "calla-request", "nodeId": "calla-node", "displayName": "Calla Mac"},
            ])

    def test_enrolls_exactly_one_matching_private_mac_and_patches_node_id(self) -> None:
        calls: list[tuple[list[str], str | None]] = []

        def fake_run(command: list[str], *, input_text: str | None = None) -> str:
            calls.append((command, input_text))
            if command[1:3] == ["nodes", "pending"]:
                return json.dumps([{"requestId": "calla-request", "nodeId": "calla-node", "displayName": "Calla Mac"}])
            return "{}"

        with patch.object(node_enroller, "run", side_effect=fake_run):
            self.assertTrue(node_enroller.enroll_one("openclaw", "Calla Mac"))

        self.assertEqual(calls[1][0], ["openclaw", "nodes", "approve", "calla-request", "--json"])
        self.assertEqual(
            json.loads(calls[2][1] or "{}"),
            {"plugins": {"entries": {"desktop-tutor": {"enabled": True, "config": {"nodeId": "calla-node"}}}}},
        )

    def test_refuses_multiple_matching_macs(self) -> None:
        with patch.object(node_enroller, "run", return_value=json.dumps([
            {"requestId": "one", "nodeId": "one", "displayName": "Calla Mac"},
            {"requestId": "two", "nodeId": "two", "displayName": "Calla Mac"},
        ])):
            with self.assertRaisesRegex(RuntimeError, "refusing to auto-enroll"):
                node_enroller.enroll_one("openclaw", "Calla Mac")


if __name__ == "__main__":
    unittest.main()
