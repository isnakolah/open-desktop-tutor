from __future__ import annotations

import json
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path

from open_tutor_pack import PackError, compile_pack, search_pack, validate_pack


REPO_ROOT = Path(__file__).resolve().parents[3]
BLENDER_PACK = REPO_ROOT / "packs" / "blender"


class PackCompilerTests(unittest.TestCase):
    def test_blender_pack_validates_with_semantic_references(self) -> None:
        result = validate_pack(BLENDER_PACK)
        self.assertEqual(result.manifest["id"], "org.open-desktop-tutor.blender")
        ids = {entity["id"] for entity in result.entities}
        self.assertIn("blender.lesson.bevel_basics", ids)
        self.assertIn("blender.ui.properties.modifiers_tab", ids)
        self.assertGreaterEqual(len(ids), 10)

    def test_compile_builds_manifest_entities_and_fts_index(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "blender.otpack"
            result = compile_pack(BLENDER_PACK, output)
            self.assertEqual(result.pack_id, "org.open-desktop-tutor.blender")
            self.assertTrue(output.is_file())
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(
                    sorted(archive.namelist()),
                    ["entities.json", "index.sqlite3", "manifest.json"],
                )
                manifest = json.loads(archive.read("manifest.json"))
                self.assertEqual(manifest["entity_count"], result.entity_count)

            matches = search_pack(output, "bevel", limit=10)
            self.assertTrue(matches)
            self.assertIn("blender.lesson.bevel_basics", {match["id"] for match in matches})

    def test_duplicate_entity_ids_fail_closed(self) -> None:
        with self._pack_copy() as pack:
            duplicate = pack / "ui" / "duplicate.yaml"
            duplicate.write_text(
                "id: blender.ui.properties.modifiers_tab\n"
                "title: Duplicate\n"
                "source_refs: [open-tutor-authored]\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PackError, "duplicate entity id"):
                validate_pack(pack)

    def test_raw_action_coordinates_are_forbidden(self) -> None:
        with self._pack_copy() as pack:
            unsafe = pack / "lessons" / "unsafe.yaml"
            unsafe.write_text(
                "id: blender.lesson.unsafe\n"
                "title: Unsafe coordinate lesson\n"
                "source_refs: [open-tutor-authored]\n"
                "action:\n"
                "  coordinates: [847, 291]\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PackError, "raw coordinate field"):
                validate_pack(pack)

    def test_unknown_semantic_target_fails(self) -> None:
        with self._pack_copy() as pack:
            broken = pack / "workflows" / "broken.yaml"
            broken.write_text(
                "id: blender.workflow.broken\n"
                "title: Broken workflow\n"
                "source_refs: [open-tutor-authored]\n"
                "steps:\n"
                "  - instruction: Do something\n"
                "    target: blender.ui.does_not_exist\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PackError, "references unknown id"):
                validate_pack(pack)

    def _pack_copy(self):
        class CopyContext:
            def __init__(self) -> None:
                self.temporary_directory = tempfile.TemporaryDirectory()
                self.path = Path(self.temporary_directory.name) / "blender"

            def __enter__(inner_self) -> Path:
                shutil.copytree(BLENDER_PACK, inner_self.path)
                return inner_self.path

            def __exit__(inner_self, exc_type, exc, traceback) -> None:
                inner_self.temporary_directory.cleanup()

        return CopyContext()


if __name__ == "__main__":
    unittest.main()
