#!/usr/bin/env python3
"""Safely configure Calla on an existing user-owned OpenClaw Gateway."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
PLUGIN_ID = "desktop-tutor"
DEFAULT_STATE_DIRECTORY = Path.home() / ".openclaw" / "calla"
# This was the earlier workspace prototype. The standalone rewrite is now the
# configured source of truth on this host, so never leave both IDs loadable.
LEGACY_TUTOR_PLUGIN_PATHS = {"/srv/app/.openclaw/apps/desktop-tutor"}
# The previous public setup added this browser-control origin. The private
# one-user route does not need it, so remove only this exact obsolete value.
LEGACY_CALLA_ORIGINS = {"https://calla.nomonlab.com"}


class SetupError(RuntimeError):
    """A safe setup operation could not be completed."""


def run(command: list[str], *, input_text: str | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, input=input_text, capture_output=True, text=True, check=False)
    if check and result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or "no diagnostic output"
        raise SetupError(f"{' '.join(command[:3])} failed: {detail}")
    return result


def ensure_openclaw(binary: str) -> str:
    if shutil.which(binary) is None:
        raise SetupError(f"OpenClaw CLI not found: {binary}")
    return run([binary, "--version"]).stdout.strip()


def read_json_config(binary: str, path: str) -> Any | None:
    result = run([binary, "config", "get", path, "--json"], check=False)
    if result.returncode or not result.stdout.strip():
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def unique_append(values: Any, value: str) -> tuple[list[str] | None, bool]:
    if values is None:
        return None, False
    if not isinstance(values, list) or not all(isinstance(item, str) for item in values):
        raise SetupError("existing OpenClaw allowlist/origin configuration is not a string array")
    return values if value in values else [*values, value], value not in values


def remove_known(values: Any, known_values: set[str]) -> tuple[list[str] | None, bool]:
    if values is None:
        return None, False
    if not isinstance(values, list) or not all(isinstance(item, str) for item in values):
        raise SetupError("existing OpenClaw allowlist/origin configuration is not a string array")
    remaining = [item for item in values if item not in known_values]
    return remaining, len(remaining) != len(values)


def build_gateway_patch(
    *,
    plugin_allow: Any,
    plugin_paths: Any,
    allowed_origins: Any,
    node_id: str | None,
    state_directory: Path,
    plugin_path: Path,
) -> tuple[dict[str, Any], dict[str, bool]]:
    allow, allow_added = unique_append(plugin_allow, PLUGIN_ID)
    paths, path_added = unique_append(plugin_paths, str(plugin_path))
    legacy_paths_removed = False
    if paths is not None:
        legacy_paths_removed = any(path in LEGACY_TUTOR_PLUGIN_PATHS for path in paths)
        paths = [path for path in paths if path not in LEGACY_TUTOR_PLUGIN_PATHS]
    origins, legacy_origin_removed = remove_known(allowed_origins, LEGACY_CALLA_ORIGINS)
    plugin_config: dict[str, Any] = {
        "role": "gateway",
        "stateDirectory": str(state_directory),
        # This is a private, single-user installation. The local Mac still
        # owns every Accessibility permission and action approval.
        "requireOwnerIdentity": False,
    }
    if node_id:
        plugin_config["nodeId"] = node_id
    patch: dict[str, Any] = {
        "plugins": {
            "entries": {PLUGIN_ID: {"enabled": True, "config": plugin_config}},
            "load": {"paths": paths or [str(plugin_path)]},
        },
        "gateway": {
            "mode": "local",
            "bind": "loopback",
            "auth": {"mode": "none", "token": None},
            # OpenClaw disallows auth:none for its own tailnet listener. The
            # server setup therefore owns an external Tailscale HTTPS proxy to
            # this loopback listener; the Gateway itself remains unexposed.
            "tailscale": {"mode": "off", "resetOnExit": False},
        },
    }
    if legacy_origin_removed:
        patch["gateway"]["controlUi"] = {"allowedOrigins": origins}
    if allow is not None:
        patch["plugins"]["allow"] = allow
    return patch, {
        "plugin_allow_added": allow_added,
        "plugin_path_added": path_added,
        "legacy_plugin_paths_removed": legacy_paths_removed,
        "legacy_origin_removed": legacy_origin_removed,
    }


def prepare_state_directory(state_directory: Path) -> None:
    state_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(state_directory, 0o700)
    for name in ("packs", "indexes", "lessons", "learners", "audit", "backups"):
        directory = state_directory / name
        directory.mkdir(mode=0o700, exist_ok=True)
        os.chmod(directory, 0o700)


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def active_config_path(binary: str) -> Path:
    result = run([binary, "config", "file"])
    # OpenClaw can emit a boxed plugin warning before the final config path.
    # Select an existing path from the output instead of treating the complete
    # warning-and-path transcript as a filesystem name.
    for line in reversed(result.stdout.splitlines()):
        config_path = Path(line.strip()).expanduser()
        if config_path.is_file():
            return config_path
    raise SetupError("OpenClaw config file path was not present in `openclaw config file` output")


def backup_config(binary: str, state_directory: Path) -> Path:
    source = active_config_path(binary)
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    destination = state_directory / "backups" / f"openclaw-{timestamp}.json5"
    shutil.copy2(source, destination)
    os.chmod(destination, 0o600)
    return destination


def patch_config(binary: str, patch: dict[str, Any], *, dry_run: bool) -> subprocess.CompletedProcess[str]:
    command = [binary, "config", "patch", "--stdin"]
    if dry_run:
        command.extend(["--dry-run", "--json"])
    return run(command, input_text=json.dumps(patch))


def validate_config(binary: str) -> None:
    run([binary, "config", "validate"])


def install(arguments: argparse.Namespace) -> int:
    binary = arguments.openclaw_bin
    ensure_openclaw(binary)
    state_directory = arguments.state_directory.expanduser().resolve()
    prior_receipt_path = state_directory / "install-receipt.json"
    prior_receipt = json.loads(prior_receipt_path.read_text(encoding="utf-8")) if prior_receipt_path.is_file() else {}
    plugin_allow = read_json_config(binary, "plugins.allow")
    plugin_paths = read_json_config(binary, "plugins.load.paths")
    allowed_origins = read_json_config(binary, "gateway.controlUi.allowedOrigins")
    patch, ownership = build_gateway_patch(
        plugin_allow=plugin_allow,
        plugin_paths=plugin_paths,
        allowed_origins=allowed_origins,
        node_id=arguments.node_id,
        state_directory=state_directory,
        plugin_path=arguments.repository.resolve() / "integrations" / "openclaw",
    )
    print("Calla additive OpenClaw patch:")
    print(json.dumps(patch, indent=2, sort_keys=True))
    print("Validating the patch without writing OpenClaw configuration...")
    preview = patch_config(binary, patch, dry_run=True)
    if preview.stdout.strip():
        print(preview.stdout.strip())
    if not arguments.yes:
        print("Preview complete. Add --yes to install; no files or OpenClaw configuration were changed.")
        return 0
    prepare_state_directory(state_directory)
    backup = backup_config(binary, state_directory)
    try:
        patch_config(binary, patch, dry_run=False)
        run([binary, "plugins", "enable", PLUGIN_ID])
        validate_config(binary)
    except Exception:
        shutil.copy2(backup, active_config_path(binary))
        raise
    receipt = {
        "format": "calla-openclaw-install-receipt",
        "format_version": 1,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "state_directory": str(state_directory),
        "config_backup": str(backup),
        "plugin_allow_added": prior_receipt.get("plugin_allow_added", False) or ownership["plugin_allow_added"],
        "plugin_path_added": prior_receipt.get("plugin_path_added", False) or ownership["plugin_path_added"],
        "legacy_plugin_paths_removed": prior_receipt.get("legacy_plugin_paths_removed", False) or ownership["legacy_plugin_paths_removed"],
        "legacy_origin_removed": prior_receipt.get("legacy_origin_removed", False) or ownership["legacy_origin_removed"],
    }
    atomic_json(state_directory / "install-receipt.json", receipt)
    if arguments.app_pack:
        command = [sys.executable, str(REPOSITORY_ROOT / "tools" / "calla_pack_store.py"), str(arguments.app_pack), "--state-directory", str(state_directory)]
        run(command)
    if arguments.restart:
        run([binary, "gateway", "restart"])
    print(f"Calla Gateway configuration installed. Backup: {backup}")
    print("The private Tailscale endpoint is ready for the bundled Mac bootstrap. The local enroller will bind the first pending node named Calla Mac.")
    return 0


def status(arguments: argparse.Namespace) -> int:
    binary = arguments.openclaw_bin
    version = ensure_openclaw(binary)
    state_directory = arguments.state_directory.expanduser().resolve()
    configuration = read_json_config(binary, f"plugins.entries.{PLUGIN_ID}.config")
    print(json.dumps({
        "openclaw": version,
        "plugin_config": configuration,
        "calla_state_directory": str(state_directory),
        "state_exists": state_directory.is_dir(),
        "installed_packs": len(list((state_directory / "indexes").glob("*.json"))) if (state_directory / "indexes").is_dir() else 0,
        "install_receipt": (state_directory / "install-receipt.json").is_file(),
    }, indent=2, sort_keys=True))
    return 0


def check(arguments: argparse.Namespace) -> int:
    binary = arguments.openclaw_bin
    version = ensure_openclaw(binary)
    validate_config(binary)
    state_directory = arguments.state_directory.expanduser().resolve()
    print(json.dumps({
        "ok": True,
        "openclaw": version,
        "plugin_source": str(arguments.repository.resolve() / "integrations" / "openclaw"),
        "state_directory": str(state_directory),
        "state_exists": state_directory.is_dir(),
        "gateway_auth": read_json_config(binary, "gateway.auth.mode"),
        "gateway_bind": read_json_config(binary, "gateway.bind"),
        "gateway_tailscale": read_json_config(binary, "gateway.tailscale.mode"),
    }, indent=2, sort_keys=True))
    return 0


def remove(arguments: argparse.Namespace) -> int:
    if not arguments.yes:
        raise SetupError("--remove requires --yes because it removes Calla configuration and state")
    binary = arguments.openclaw_bin
    ensure_openclaw(binary)
    state_directory = arguments.state_directory.expanduser().resolve()
    receipt_path = state_directory / "install-receipt.json"
    if not receipt_path.is_file():
        raise SetupError(f"refusing to remove {state_directory}: no Calla install receipt exists")
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    if receipt.get("format") != "calla-openclaw-install-receipt" or receipt.get("state_directory") != str(state_directory):
        raise SetupError("refusing to remove state that was not created by this Calla installer")
    plugin_allow = read_json_config(binary, "plugins.allow")
    plugin_paths = read_json_config(binary, "plugins.load.paths")
    plugins: dict[str, Any] = {"entries": {PLUGIN_ID: None}}
    if receipt.get("plugin_allow_added") and isinstance(plugin_allow, list):
        plugins["allow"] = [item for item in plugin_allow if item != PLUGIN_ID]
    if receipt.get("plugin_path_added") and isinstance(plugin_paths, list):
        plugins["load"] = {"paths": [item for item in plugin_paths if item != str(arguments.repository.resolve() / "integrations" / "openclaw")]}
    patch: dict[str, Any] = {"plugins": plugins}
    print("Calla removal patch:")
    print(json.dumps(patch, indent=2, sort_keys=True))
    patch_config(binary, patch, dry_run=True)
    backup = backup_config(binary, state_directory)
    try:
        patch_config(binary, patch, dry_run=False)
        validate_config(binary)
    except Exception:
        shutil.copy2(backup, active_config_path(binary))
        raise
    if arguments.restart:
        run([binary, "gateway", "restart"])
    shutil.rmtree(state_directory)
    print("Removed only Calla-owned OpenClaw configuration and state.")
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    mode = result.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="validate prerequisites without writing")
    mode.add_argument("--install", action="store_true", help="install Calla Gateway configuration")
    mode.add_argument("--status", action="store_true", help="show Calla configuration and local state")
    mode.add_argument("--remove", action="store_true", help="remove only state created by this installer")
    result.add_argument("--yes", action="store_true", help="confirm an install or removal")
    result.add_argument("--restart", action="store_true", help="perform one Gateway restart after successful validation")
    result.add_argument("--node-id", help="optional existing Mac node id; normally set by the local auto-enroller")
    result.add_argument("--app-pack", type=Path, help="compiled .otpack to install in Calla server-local retrieval")
    result.add_argument("--state-directory", type=Path, default=DEFAULT_STATE_DIRECTORY)
    result.add_argument("--repository", type=Path, default=REPOSITORY_ROOT)
    result.add_argument("--openclaw-bin", default="openclaw")
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        if arguments.check:
            return check(arguments)
        if arguments.status:
            return status(arguments)
        if arguments.install:
            return install(arguments)
        return remove(arguments)
    except (SetupError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
