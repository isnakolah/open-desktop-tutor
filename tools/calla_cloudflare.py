#!/usr/bin/env python3
"""Provision only Calla's Cloudflare Tunnel, Access applications, and DNS records.

The API token is read only from CALLA_CLOUDFLARE_API_TOKEN. It is never accepted
as a command-line argument, written to the resource ledger, or printed.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


API_ROOT = "https://api.cloudflare.com/client/v4"
TUNNEL_NAME = "calla-control"
HUMAN_HOSTNAME = "calla.nomonlab.com"
NODE_HOSTNAME = "node.calla.nomonlab.com"
SERVICE_TOKEN_NAME = "calla-mac-node"
DEFAULT_STATE_FILE = Path.home() / ".openclaw" / "calla" / "cloudflare-resources.json"
DEFAULT_TUNNEL_TOKEN_FILE = Path("/etc/calla/calla-control.token")


class CloudflareError(RuntimeError):
    pass


class CloudflareAPI:
    def __init__(self, token: str) -> None:
        if not token:
            raise CloudflareError("CALLA_CLOUDFLARE_API_TOKEN is required for live Cloudflare operations")
        self.token = token

    def request(self, method: str, resource: str, payload: dict[str, Any] | None = None) -> Any:
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        request = urllib.request.Request(
            f"{API_ROOT}{resource}",
            data=data,
            method=method,
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = json.load(response)
        except urllib.error.HTTPError as exc:
            try:
                detail = json.load(exc)
            except Exception:
                detail = {}
            errors = "; ".join(str(item.get("message", item)) for item in detail.get("errors", []))
            raise CloudflareError(f"Cloudflare API {method} {resource} failed ({exc.code}): {errors or exc.reason}") from exc
        except urllib.error.URLError as exc:
            raise CloudflareError(f"Cloudflare API {method} {resource} is unreachable: {exc.reason}") from exc
        if not body.get("success"):
            errors = "; ".join(str(item.get("message", item)) for item in body.get("errors", []))
            raise CloudflareError(f"Cloudflare API {method} {resource} failed: {errors or 'unknown error'}")
        return body.get("result")


def atomic_write(path: Path, content: bytes, *, mode: int = 0o600) -> None:
    path = path.expanduser().resolve()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def load_ledger(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("format") != "calla-cloudflare-resources" or value.get("format_version") != 1:
        raise CloudflareError(f"refusing to use an unrecognized resource ledger: {path}")
    return value


def save_ledger(path: Path, value: dict[str, Any]) -> None:
    value = {"format": "calla-cloudflare-resources", "format_version": 1, **value}
    atomic_write(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8"))


def covers_nested_hostname(packs: list[dict[str, Any]], hostname: str = NODE_HOSTNAME) -> bool:
    """True when an active certificate covers the deep hostname under X.509 wildcard rules."""
    for pack in packs:
        for certificate in pack.get("certificates", []):
            if certificate.get("status") != "active":
                continue
            for covered_name in certificate.get("hosts", []):
                if covered_name == hostname:
                    return True
                if covered_name.startswith("*."):
                    suffix = covered_name[1:]
                    if hostname.endswith(suffix) and hostname.count(".") == suffix.count("."):
                        return True
    return False


def desired_plan(account_id: str, zone_id: str) -> dict[str, Any]:
    return {
        "ownership": "Calla only; does not inspect or reuse nomonlab-public",
        "account_id": account_id,
        "zone_id": zone_id,
        "tunnel": {
            "name": TUNNEL_NAME,
            "ingress": [
                {"hostname": HUMAN_HOSTNAME, "service": "http://127.0.0.1:18789"},
                {"hostname": NODE_HOSTNAME, "service": "tcp://127.0.0.1:18789"},
            ],
        },
        "access": {
            "identity_provider": {"type": "cloudflare", "restrict_to_account_members": True},
            "human": {"hostname": HUMAN_HOSTNAME, "session_duration": "8h", "selector": "cloudflare_account_member"},
            "node": {"hostname": NODE_HOSTNAME, "service_token": SERVICE_TOKEN_NAME, "duration": "2160h"},
        },
        "dns": [
            {"name": HUMAN_HOSTNAME, "type": "CNAME", "content": "<tunnel-id>.cfargotunnel.com", "proxied": True},
            {"name": NODE_HOSTNAME, "type": "CNAME", "content": "<tunnel-id>.cfargotunnel.com", "proxied": True},
        ],
        "preflight": [
            "Zero Trust organization is enabled.",
            f"An active Advanced Certificate Manager or Total TLS certificate explicitly covers {NODE_HOSTNAME}.",
            "A Cloudflare identity provider has restrict_to_account_members=true.",
        ],
    }


def list_named(api: CloudflareAPI, resource: str, name: str) -> dict[str, Any] | None:
    result = api.request("GET", resource)
    values = result if isinstance(result, list) else result.get("result", []) if isinstance(result, dict) else []
    matches = [item for item in values if isinstance(item, dict) and item.get("name") == name]
    if len(matches) > 1:
        raise CloudflareError(f"multiple resources named {name!r}; refuse to adopt any")
    return matches[0] if matches else None


def find_cloudflare_identity_provider(api: CloudflareAPI, account_id: str) -> dict[str, Any]:
    providers = api.request("GET", f"/accounts/{account_id}/access/identity_providers")
    for provider in providers if isinstance(providers, list) else []:
        if provider.get("type") == "cloudflare":
            if provider.get("config", {}).get("restrict_to_account_members") is True:
                return provider
            raise CloudflareError("Cloudflare identity provider exists but restrict_to_account_members is not true")
    raise CloudflareError("Cloudflare identity provider is absent; enable Zero Trust and configure the restricted provider first")


def create_access_app(api: CloudflareAPI, account_id: str, name: str, hostname: str, session_duration: str) -> dict[str, Any]:
    existing = list_named(api, f"/accounts/{account_id}/access/apps", name)
    if existing:
        if existing.get("domain") != hostname:
            raise CloudflareError(f"Access app {name!r} exists for a different domain")
        return existing
    return api.request("POST", f"/accounts/{account_id}/access/apps", {
        "name": name,
        "domain": hostname,
        "type": "self_hosted",
        "session_duration": session_duration,
    })


def create_policy(api: CloudflareAPI, account_id: str, application_id: str, payload: dict[str, Any]) -> str:
    policies = api.request("GET", f"/accounts/{account_id}/access/apps/{application_id}/policies")
    for policy in policies if isinstance(policies, list) else []:
        if policy.get("name") == payload["name"]:
            return str(policy["id"])
    created = api.request("POST", f"/accounts/{account_id}/access/apps/{application_id}/policies", payload)
    return str(created["id"])


def ensure_dns_record(api: CloudflareAPI, zone_id: str, hostname: str, tunnel_id: str) -> str:
    records = api.request("GET", f"/zones/{zone_id}/dns_records?name={hostname}")
    desired = f"{tunnel_id}.cfargotunnel.com"
    values = records if isinstance(records, list) else []
    if values:
        record = values[0]
        if len(values) != 1 or record.get("type") != "CNAME" or record.get("content") != desired or not record.get("proxied"):
            raise CloudflareError(f"DNS hostname {hostname} already exists and is not the Calla tunnel record")
        return str(record["id"])
    record = api.request("POST", f"/zones/{zone_id}/dns_records", {
        "type": "CNAME", "name": hostname, "content": desired, "proxied": True,
    })
    return str(record["id"])


def write_systemd_service(unit_path: Path, tunnel_token_file: Path) -> None:
    binary = shutil.which("cloudflared")
    if not binary:
        raise CloudflareError("cloudflared is required to install the Calla systemd service")
    unit = f"""[Unit]
Description=Calla Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart={binary} tunnel run --token-file {tunnel_token_file}
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadOnlyPaths={tunnel_token_file}

[Install]
WantedBy=multi-user.target
"""
    atomic_write(unit_path, unit.encode("utf-8"), mode=0o644)


def apply(arguments: argparse.Namespace) -> int:
    if not arguments.yes:
        raise CloudflareError("apply requires --yes")
    if load_ledger(arguments.state_file):
        print("Calla resources already have a ledger; run status or destroy instead of adopting/recreating them.")
        return 0
    api = CloudflareAPI(os.environ.get("CALLA_CLOUDFLARE_API_TOKEN", ""))
    # The certificate check deliberately occurs before any DNS record is created.
    packs = api.request("GET", f"/zones/{arguments.zone_id}/ssl/certificate_packs")
    if not covers_nested_hostname(packs if isinstance(packs, list) else []):
        raise CloudflareError(f"no active certificate explicitly covers {NODE_HOSTNAME}; enable ACM/Total TLS before publishing DNS")
    find_cloudflare_identity_provider(api, arguments.account_id)
    tunnel = list_named(api, f"/accounts/{arguments.account_id}/cfd_tunnel", TUNNEL_NAME)
    if tunnel is None:
        tunnel = api.request("POST", f"/accounts/{arguments.account_id}/cfd_tunnel", {"name": TUNNEL_NAME, "config_src": "cloudflare"})
    tunnel_id = str(tunnel["id"])
    api.request("PUT", f"/accounts/{arguments.account_id}/cfd_tunnel/{tunnel_id}/configurations", {
        "config": {"ingress": [
            {"hostname": HUMAN_HOSTNAME, "service": "http://127.0.0.1:18789"},
            {"hostname": NODE_HOSTNAME, "service": "tcp://127.0.0.1:18789"},
            {"service": "http_status:404"},
        ]},
    })
    human_app = create_access_app(api, arguments.account_id, "Calla browser", HUMAN_HOSTNAME, "8h")
    node_app = create_access_app(api, arguments.account_id, "Calla Mac node", NODE_HOSTNAME, "24h")
    human_policy_id = create_policy(api, arguments.account_id, str(human_app["id"]), {
        "name": "Calla account members", "decision": "allow", "precedence": 1,
        "include": [{"cloudflare_account_member": {"account_id": arguments.account_id}}],
    })
    service_token = list_named(api, f"/accounts/{arguments.account_id}/access/service_tokens", SERVICE_TOKEN_NAME)
    if service_token is not None:
        raise CloudflareError("calla-mac-node service token already exists without a Calla ledger; refuse to adopt it")
    service_token = api.request("POST", f"/accounts/{arguments.account_id}/access/service_tokens", {"name": SERVICE_TOKEN_NAME, "duration": "2160h"})
    if not service_token.get("client_secret"):
        raise CloudflareError("Cloudflare did not return a service-token secret")
    atomic_write(arguments.service_token_output, (json.dumps({
        "service_token_id": service_token["client_id"],
        "service_token_secret": service_token["client_secret"],
        "expires_at": service_token.get("expires_at"),
    }) + "\n").encode("utf-8"))
    node_policy_id = create_policy(api, arguments.account_id, str(node_app["id"]), {
        "name": "Calla Mac service token", "decision": "allow", "precedence": 1,
        "include": [{"service_token": {"token_id": service_token["id"]}}],
    })
    token = api.request("GET", f"/accounts/{arguments.account_id}/cfd_tunnel/{tunnel_id}/token")
    atomic_write(arguments.tunnel_token_file, (str(token) + "\n").encode("utf-8"))
    dns_ids = {hostname: ensure_dns_record(api, arguments.zone_id, hostname, tunnel_id) for hostname in (HUMAN_HOSTNAME, NODE_HOSTNAME)}
    ledger = {
        "account_id": arguments.account_id,
        "zone_id": arguments.zone_id,
        "tunnel_id": tunnel_id,
        "access_app_ids": {"human": human_app["id"], "node": node_app["id"]},
        "access_policy_ids": {"human": human_policy_id, "node": node_policy_id},
        "service_token_id": service_token["id"],
        "dns_record_ids": dns_ids,
        "tunnel_token_file": str(arguments.tunnel_token_file.expanduser().resolve()),
        "service_token_output": str(arguments.service_token_output.expanduser().resolve()),
    }
    if arguments.install_service:
        write_systemd_service(arguments.systemd_unit, arguments.tunnel_token_file.expanduser().resolve())
        run_systemctl(["daemon-reload"])
        run_systemctl(["enable", "--now", arguments.systemd_unit.stem])
        ledger["systemd_unit"] = str(arguments.systemd_unit.expanduser().resolve())
    save_ledger(arguments.state_file, ledger)
    print(f"Created Calla-owned tunnel, Access applications, policies, and DNS. Secret handoff: {arguments.service_token_output}")
    return 0


def run_systemctl(arguments: list[str]) -> None:
    result = subprocess.run(["systemctl", *arguments], capture_output=True, text=True, check=False)
    if result.returncode:
        raise CloudflareError(f"systemctl {' '.join(arguments)} failed: {result.stderr.strip() or result.stdout.strip()}")


def status(arguments: argparse.Namespace) -> int:
    ledger = load_ledger(arguments.state_file)
    if not ledger:
        print("No Calla Cloudflare resource ledger exists; no Calla resources are managed from this host.")
        return 0
    output: dict[str, Any] = {key: value for key, value in ledger.items() if key not in {"service_token_output", "tunnel_token_file"}}
    output["credential_files_present"] = {
        "tunnel_token": Path(ledger["tunnel_token_file"]).is_file(),
        "mac_service_token_handoff": Path(ledger["service_token_output"]).is_file(),
    }
    print(json.dumps(output, indent=2, sort_keys=True))
    return 0


def destroy(arguments: argparse.Namespace) -> int:
    if not arguments.yes:
        raise CloudflareError("destroy requires --yes")
    ledger = load_ledger(arguments.state_file)
    if not ledger:
        raise CloudflareError("no Calla ledger found; refuse to discover or delete similarly named resources")
    api = CloudflareAPI(os.environ.get("CALLA_CLOUDFLARE_API_TOKEN", ""))
    for record_id in ledger.get("dns_record_ids", {}).values():
        api.request("DELETE", f"/zones/{ledger['zone_id']}/dns_records/{record_id}")
    for app_id in ledger.get("access_app_ids", {}).values():
        api.request("DELETE", f"/accounts/{ledger['account_id']}/access/apps/{app_id}")
    api.request("DELETE", f"/accounts/{ledger['account_id']}/access/service_tokens/{ledger['service_token_id']}")
    api.request("DELETE", f"/accounts/{ledger['account_id']}/cfd_tunnel/{ledger['tunnel_id']}")
    if ledger.get("systemd_unit"):
        unit = Path(ledger["systemd_unit"])
        run_systemctl(["disable", "--now", unit.stem])
        unit.unlink(missing_ok=True)
        run_systemctl(["daemon-reload"])
    for key in ("tunnel_token_file", "service_token_output"):
        Path(ledger[key]).unlink(missing_ok=True)
    arguments.state_file.unlink(missing_ok=True)
    print("Destroyed only resources recorded in the Calla ledger. The Cloudflare identity provider was retained.")
    return 0


def rotate_service_token(arguments: argparse.Namespace) -> int:
    if not arguments.yes:
        raise CloudflareError("rotate-service-token requires --yes")
    ledger = load_ledger(arguments.state_file)
    if not ledger:
        raise CloudflareError("no Calla ledger found; refuse to rotate an untracked service token")
    api = CloudflareAPI(os.environ.get("CALLA_CLOUDFLARE_API_TOKEN", ""))
    rotated = api.request(
        "POST",
        f"/accounts/{ledger['account_id']}/access/service_tokens/{ledger['service_token_id']}/rotate",
        {
            "duration": "2160h",
            # An incident rotation must prevent fresh uses of the old secret.
            "previous_client_secret_expires_at": datetime.now(timezone.utc).isoformat(),
        },
    )
    if not rotated.get("client_secret"):
        raise CloudflareError("Cloudflare did not return a rotated service-token secret")
    output = arguments.service_token_output or Path(ledger["service_token_output"])
    atomic_write(output, (json.dumps({
        "service_token_id": rotated["client_id"],
        "service_token_secret": rotated["client_secret"],
        "expires_at": rotated.get("expires_at"),
    }) + "\n").encode("utf-8"))
    ledger["service_token_output"] = str(output.expanduser().resolve())
    save_ledger(arguments.state_file, ledger)
    print(f"Rotated the Calla Mac service token without changing OpenClaw pairing. Secure handoff: {output}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    plan = commands.add_parser("plan", help="print the dry-run Calla resource plan")
    plan.add_argument("--account-id", required=True)
    plan.add_argument("--zone-id", required=True)
    apply_parser = commands.add_parser("apply", help="create the planned Calla resources")
    apply_parser.add_argument("--account-id", required=True)
    apply_parser.add_argument("--zone-id", required=True)
    apply_parser.add_argument("--yes", action="store_true")
    apply_parser.add_argument("--service-token-output", type=Path, required=True, help="secure handoff JSON for the Mac; mode 0600")
    apply_parser.add_argument("--tunnel-token-file", type=Path, default=DEFAULT_TUNNEL_TOKEN_FILE)
    apply_parser.add_argument("--install-service", action="store_true")
    apply_parser.add_argument("--systemd-unit", type=Path, default=Path("/etc/systemd/system/calla-control.service"))
    commands.add_parser("status", help="show Calla ledger status without Cloudflare mutation")
    rotate_parser = commands.add_parser("rotate-service-token", help="rotate only the Calla Mac Access secret")
    rotate_parser.add_argument("--yes", action="store_true")
    rotate_parser.add_argument("--service-token-output", type=Path, help="secure replacement handoff JSON")
    destroy_parser = commands.add_parser("destroy", help="destroy only Calla resources recorded in the ledger")
    destroy_parser.add_argument("--yes", action="store_true")
    for subparser in commands.choices.values():
        subparser.add_argument("--state-file", type=Path, default=DEFAULT_STATE_FILE)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        if arguments.command == "plan":
            print(json.dumps(desired_plan(arguments.account_id, arguments.zone_id), indent=2, sort_keys=True))
            return 0
        if arguments.command == "apply":
            return apply(arguments)
        if arguments.command == "status":
            return status(arguments)
        if arguments.command == "rotate-service-token":
            return rotate_service_token(arguments)
        return destroy(arguments)
    except (CloudflareError, OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
