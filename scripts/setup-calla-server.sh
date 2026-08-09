#!/usr/bin/env bash
# Prepare the Calla Gateway and its dedicated cf-dns manifest. This script never
# publishes public DNS; Cloudflare Access and nested TLS are mandatory gates.
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
CF_DNS_BIN="${CALLA_CF_DNS_BIN:-cf-dns}"
CF_DNS_ROOT="${CALLA_CF_DNS_ROOT:-/srv/app/cloudflare-dns}"
MANIFEST="${CALLA_CF_DNS_MANIFEST:-$CF_DNS_ROOT/calla-control.toml}"
MODE="check"
YES=0
RESTART=1

usage() {
  cat <<'EOF'
Usage: ./scripts/setup-calla-server.sh [--check|--install|--status] [options]

Prepare the existing OpenClaw Gateway and Calla's dedicated cf-dns manifest.
The default is --check and never writes state. --install --yes builds the
default Blender App Pack, installs the gateway role, and creates or validates
the private calla-control manifest. It never publishes public DNS.

Options:
  --check                 Validate current prerequisites and manifest (default)
  --install               Install the Calla gateway defaults and manifest
  --status                Show the current Calla and cf-dns state
  --yes                   Confirm --install
  --no-restart            Do not restart the Gateway during --install
  --cf-dns-bin PATH       Defaults to cf-dns (or CALLA_CF_DNS_BIN)
  --cf-dns-root PATH      Defaults to /srv/app/cloudflare-dns
  --manifest PATH         Defaults to <cf-dns-root>/calla-control.toml
  -h, --help              Show this help

After Zero Trust Access, the account-member and Service Auth policies, and a
nested TLS certificate are active, publish only with the reviewed command:
  cf-dns --manifest <manifest> reconcile
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check" ;;
    --install) MODE="install" ;;
    --status) MODE="status" ;;
    --yes) YES=1 ;;
    --no-restart) RESTART=0 ;;
    --cf-dns-bin) shift; [[ $# -gt 0 ]] || fail "--cf-dns-bin needs a value"; CF_DNS_BIN="$1" ;;
    --cf-dns-root) shift; [[ $# -gt 0 ]] || fail "--cf-dns-root needs a value"; CF_DNS_ROOT="$1"; MANIFEST="${CALLA_CF_DNS_MANIFEST:-$CF_DNS_ROOT/calla-control.toml}" ;;
    --manifest) shift; [[ $# -gt 0 ]] || fail "--manifest needs a value"; MANIFEST="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

require_cf_dns() {
  command -v "$CF_DNS_BIN" >/dev/null 2>&1 || fail "cf-dns is required; set CALLA_CF_DNS_BIN or use --cf-dns-bin"
}

show_cf_dns_state() {
  "$CF_DNS_BIN" --manifest "$MANIFEST" doctor
  if [[ -f "$MANIFEST" ]]; then
    "$CF_DNS_BIN" --manifest "$MANIFEST" plan
    "$CF_DNS_BIN" --manifest "$MANIFEST" published
  else
    printf 'Calla cf-dns manifest: absent (%s)\n' "$MANIFEST"
  fi
}

write_default_manifest() {
  if [[ ! -f "$MANIFEST" ]]; then
    mkdir -p "$(dirname "$MANIFEST")"
    "$CF_DNS_BIN" --manifest "$MANIFEST" init --tunnel-name calla-control
  fi
  python3 - "$MANIFEST" <<'PY'
import os
import sys
import tempfile
import tomllib
from pathlib import Path

path = Path(sys.argv[1])
try:
    document = tomllib.loads(path.read_text(encoding="utf-8"))
except (OSError, tomllib.TOMLDecodeError) as error:
    raise SystemExit(f"ERROR: cannot read Calla cf-dns manifest {path}: {error}")

cloudflare = document.get("cloudflare")
if not isinstance(cloudflare, dict):
    raise SystemExit("ERROR: Calla cf-dns manifest requires a [cloudflare] table")
if cloudflare.get("zone") != "nomonlab.com":
    raise SystemExit("ERROR: Calla cf-dns manifest must target nomonlab.com")
if cloudflare.get("tunnel_name") != "calla-control":
    raise SystemExit("ERROR: Calla cf-dns manifest must use the dedicated calla-control tunnel")
if cloudflare.get("tunnel_mode", "remote") != "remote":
    raise SystemExit("ERROR: Calla must use its dedicated remote tunnel; local tunnel adoption is forbidden")

desired_hosts = {
    "calla": "http://127.0.0.1:18789",
    "node.calla": "tcp://127.0.0.1:18789",
}
hosts = document.get("hosts", {})
if not isinstance(hosts, dict):
    raise SystemExit("ERROR: Calla cf-dns manifest has an invalid [hosts] table")
unexpected = sorted(set(hosts) - set(desired_hosts))
if unexpected:
    raise SystemExit(f"ERROR: refusing to mix non-Calla hosts into {path}: {', '.join(unexpected)}")
for name, service in hosts.items():
    if service != desired_hosts[name]:
        raise SystemExit(f"ERROR: refusing to replace existing Calla origin {name} -> {service}")

account_id = cloudflare.get("account_id")
if not isinstance(account_id, str) or not account_id:
    raise SystemExit("ERROR: Calla cf-dns manifest requires a Cloudflare account_id")
lines = [
    "# Managed by Calla setup through cf-dns. Keep this file private.",
    "[cloudflare]",
    'zone = "nomonlab.com"',
    f'account_id = "{account_id}"',
    'tunnel_name = "calla-control"',
]
zone_id = cloudflare.get("zone_id")
if isinstance(zone_id, str) and zone_id:
    lines.append(f'zone_id = "{zone_id}"')
lines.extend(("", "[hosts]"))
for name, service in desired_hosts.items():
    lines.append(f'"{name}" = "{service}"')
content = "\n".join(lines) + "\n"
descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
temporary = Path(temporary_name)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
finally:
    temporary.unlink(missing_ok=True)
PY
}

require_cf_dns

case "$MODE" in
  check)
    python3 "$REPOSITORY_ROOT/tools/calla_openclaw_setup.py" --check
    show_cf_dns_state
    ;;
  status)
    python3 "$REPOSITORY_ROOT/tools/calla_openclaw_setup.py" --status
    show_cf_dns_state
    ;;
  install)
    [[ "$YES" -eq 1 ]] || fail "--install requires --yes; no state was changed"
    python3 "$REPOSITORY_ROOT/tools/calla_openclaw_setup.py" --check
    write_default_manifest
    "$CF_DNS_BIN" --manifest "$MANIFEST" plan
    make -C "$REPOSITORY_ROOT" pack-build
    install_arguments=(--install --yes --app-pack "$REPOSITORY_ROOT/build/packs/blender.otpack")
    if [[ "$RESTART" -eq 1 ]]; then
      install_arguments+=(--restart)
    fi
    python3 "$REPOSITORY_ROOT/tools/calla_openclaw_setup.py" "${install_arguments[@]}"
    printf '\nCalla defaults are installed. No public CNAME was created.\n'
    printf 'Complete Zero Trust Access and nested TLS, then review and run:\n'
    printf '  %s --manifest %q reconcile\n' "$CF_DNS_BIN" "$MANIFEST"
    show_cf_dns_state
    ;;
esac
