from __future__ import annotations

import importlib.util
import io
import json
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from contextlib import redirect_stdout


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def load_script(name: str):
    path = REPOSITORY_ROOT / "tools" / name
    spec = importlib.util.spec_from_file_location(path.stem, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pack_store = load_script("calla_pack_store.py")
gateway_setup = load_script("calla_openclaw_setup.py")
cloudflare = load_script("calla_cloudflare.py")


class CallaToolTests(unittest.TestCase):
    def test_compiled_pack_is_copied_to_server_local_index(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            source = temporary / "blender.otpack"
            manifest = {
                "format": "open-desktop-tutor-pack",
                "format_version": 1,
                "entity_count": 1,
                "pack": {
                    "id": "org.open-desktop-tutor.blender",
                    "pack_version": "0.1.0",
                    "apps": [{"platform": "macos", "bundle_ids": ["org.blenderfoundation.blender"], "versions": ">=4.3 <4.6", "locales": ["en"]}],
                },
            }
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("manifest.json", json.dumps(manifest))
                archive.writestr("entities.json", json.dumps([{"id": "blender.lesson.bevel", "kind": "lesson", "title": "Bevel"}]))
            result = pack_store.install_pack(source, temporary / "calla")
            index_path = Path(result["index_path"])
            self.assertTrue(Path(result["pack_path"]).is_file())
            self.assertEqual(stat.S_IMODE(index_path.stat().st_mode), 0o600)
            index = json.loads(index_path.read_text())
            self.assertEqual(index["format"], "calla-local-pack-index")
            self.assertEqual(index["entities"][0]["id"], "blender.lesson.bevel")

    def test_gateway_patch_is_additive_and_records_ownership(self) -> None:
        patch, ownership = gateway_setup.build_gateway_patch(
            plugin_allow=["existing-plugin"],
            allowed_origins=["https://private.nomonlab.com"],
            node_id="paired-mac-node",
            state_directory=Path("/safe/calla"),
        )
        self.assertEqual(patch["plugins"]["allow"], ["existing-plugin", "desktop-tutor"])
        self.assertEqual(
            patch["gateway"]["controlUi"]["allowedOrigins"],
            ["https://private.nomonlab.com", "https://calla.nomonlab.com"],
        )
        self.assertEqual(patch["plugins"]["entries"]["desktop-tutor"]["config"]["nodeId"], "paired-mac-node")
        self.assertEqual(ownership, {"plugin_allow_added": True, "origin_added": True})

    def test_gateway_patch_does_not_create_an_allowlist_when_none_exists(self) -> None:
        patch, ownership = gateway_setup.build_gateway_patch(
            plugin_allow=None,
            allowed_origins=None,
            node_id=None,
            state_directory=Path("/safe/calla"),
        )
        self.assertNotIn("allow", patch["plugins"])
        self.assertTrue(ownership["origin_added"])

    def test_nested_certificate_must_be_active_and_cover_the_deep_hostname(self) -> None:
        self.assertFalse(cloudflare.covers_nested_hostname([{"certificates": [{"status": "active", "hosts": ["*.nomonlab.com"]}]}]))
        self.assertTrue(cloudflare.covers_nested_hostname([{"certificates": [{"status": "active", "hosts": ["*.calla.nomonlab.com"]}]}]))
        self.assertFalse(cloudflare.covers_nested_hostname([{"certificates": [{"status": "pending_deployment", "hosts": ["node.calla.nomonlab.com"]}]}]))

    def test_gateway_installer_is_idempotent_and_removal_stays_in_calla_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            state_directory = root / "calla"
            unrelated = root / "unrelated"
            unrelated.mkdir()
            (unrelated / "keep.txt").write_text("keep", encoding="utf-8")
            arguments = SimpleNamespace(
                yes=True,
                openclaw_bin="fake-openclaw",
                state_directory=state_directory,
                repository=REPOSITORY_ROOT,
                node_id=None,
                app_pack=None,
                restart=False,
            )
            calls: list[tuple[str, bool]] = []

            def patch_config(_binary, _patch, *, dry_run):
                calls.append((json.dumps(_patch, sort_keys=True), dry_run))
                return SimpleNamespace(stdout="preview" if dry_run else "")

            def backup_config(_binary, state):
                backup = state / "backups" / "openclaw-test.json5"
                backup.parent.mkdir(parents=True, exist_ok=True)
                backup.write_text("{}", encoding="utf-8")
                return backup

            def read_for_install(_binary, path):
                return ["existing-plugin"] if path == "plugins.allow" else ["https://private.nomonlab.com"]

            with redirect_stdout(io.StringIO()):
                with (
                    patch.object(gateway_setup, "ensure_openclaw", return_value="OpenClaw test"),
                    patch.object(gateway_setup, "read_json_config", side_effect=read_for_install),
                    patch.object(gateway_setup, "patch_config", side_effect=patch_config),
                    patch.object(gateway_setup, "backup_config", side_effect=backup_config),
                    patch.object(gateway_setup, "install_plugin", side_effect=[True, False]),
                    patch.object(gateway_setup, "validate_config"),
                    patch.object(gateway_setup, "run", return_value=SimpleNamespace(stdout="", returncode=0)),
                ):
                    self.assertEqual(gateway_setup.install(arguments), 0)
                    self.assertEqual(gateway_setup.install(arguments), 0)
            receipt = json.loads((state_directory / "install-receipt.json").read_text())
            self.assertTrue(receipt["plugin_installed_by_calla"])
            self.assertTrue(receipt["origin_added"])
            self.assertEqual(len([dry_run for _patch, dry_run in calls if dry_run]), 2)

            removal_calls: list[dict] = []

            def read_for_removal(_binary, path):
                return ["desktop-tutor", "existing-plugin"] if path == "plugins.allow" else [gateway_setup.CALLA_ORIGIN, "https://private.nomonlab.com"]

            def capture_removal(_binary, removal_patch, *, dry_run):
                removal_calls.append(removal_patch)
                return SimpleNamespace(stdout="")

            with redirect_stdout(io.StringIO()):
                with (
                    patch.object(gateway_setup, "ensure_openclaw", return_value="OpenClaw test"),
                    patch.object(gateway_setup, "read_json_config", side_effect=read_for_removal),
                    patch.object(gateway_setup, "patch_config", side_effect=capture_removal),
                    patch.object(gateway_setup, "backup_config", side_effect=backup_config),
                    patch.object(gateway_setup, "validate_config"),
                    patch.object(gateway_setup, "run", return_value=SimpleNamespace(stdout="", returncode=0)),
                ):
                    self.assertEqual(gateway_setup.remove(arguments), 0)
            self.assertFalse(state_directory.exists())
            self.assertEqual((unrelated / "keep.txt").read_text(), "keep")
            final_patch = removal_calls[-1]
            self.assertEqual(final_patch["plugins"]["entries"]["desktop-tutor"], None)
            self.assertEqual(final_patch["plugins"]["allow"], ["existing-plugin"])
            self.assertEqual(final_patch["gateway"]["controlUi"]["allowedOrigins"], ["https://private.nomonlab.com"])


if __name__ == "__main__":
    unittest.main()
