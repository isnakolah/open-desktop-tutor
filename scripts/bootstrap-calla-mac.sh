#!/usr/bin/env bash
# Configure only the Mac-side Calla node transport and node-role plugin.
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
ACCESS_PROXY_LABEL="com.calla.openclaw-access-proxy"
NODE_HOST_LABEL="com.calla.openclaw-node-host"
KEYCHAIN_SERVICE="com.calla.openclaw"
CLOUDFLARE_HOSTNAME="node.calla.nomonlab.com"
TAILSCALE_GATEWAY_HOST="nomonhomelab.tailec0dca.ts.net"
LISTENER="127.0.0.1:18790"
MODE="check"
TRANSPORT="tailscale"
GATEWAY_HOST=""
GATEWAY_PORT=""
DISPLAY_NAME="Calla Mac"
YES=0

usage() {
  cat <<'EOF'
Usage: ./scripts/bootstrap-calla-mac.sh [--check|--install|--remove] [options]

Install stores the OpenClaw Gateway token in the login Keychain and starts a
Calla node host. Cloudflare mode additionally stores a Cloudflare service token
and runs a local Access TCP proxy. Tailscale mode is a private test transport:
it connects directly over WSS to the tailnet-only Gateway Serve URL and needs
no Cloudflare resources or credentials.

Options:
  --check                       Inspect prerequisites and local Calla state (default)
  --install                     Prompt for required secrets and install Calla
  --remove                      Remove only Calla LaunchAgents and Keychain items
  --yes                         Confirm --install or --remove
  --transport cloudflare|tailscale
                                Defaults to tailscale private test mode; Cloudflare is explicit
  --hostname HOST               Cloudflare Access hostname; default node.calla.nomonlab.com
  --gateway-host HOST           Tailscale Gateway host; default nomonhomelab.tailec0dca.ts.net
  --gateway-port PORT           Tailscale Gateway TLS port; default 443
  --listener HOST:PORT          Cloudflare local proxy listener; default 127.0.0.1:18790
  --display-name NAME           Node display name; default "Calla Mac"
  -h, --help                    Show this help
EOF
}

fail() { echo "ERROR: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check" ;;
    --install) MODE="install" ;;
    --remove) MODE="remove" ;;
    --yes) YES=1 ;;
    --transport) shift; [[ $# -gt 0 ]] || fail "--transport needs a value"; TRANSPORT="$1" ;;
    --hostname) shift; [[ $# -gt 0 ]] || fail "--hostname needs a value"; CLOUDFLARE_HOSTNAME="$1" ;;
    --gateway-host) shift; [[ $# -gt 0 ]] || fail "--gateway-host needs a value"; GATEWAY_HOST="$1" ;;
    --gateway-port) shift; [[ $# -gt 0 ]] || fail "--gateway-port needs a value"; GATEWAY_PORT="$1" ;;
    --listener) shift; [[ $# -gt 0 ]] || fail "--listener needs a value"; LISTENER="$1" ;;
    --display-name) shift; [[ $# -gt 0 ]] || fail "--display-name needs a value"; DISPLAY_NAME="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

[[ "$TRANSPORT" == "cloudflare" || "$TRANSPORT" == "tailscale" ]] || fail "--transport must be cloudflare or tailscale"
if [[ -z "$GATEWAY_HOST" ]]; then
  GATEWAY_HOST="$TAILSCALE_GATEWAY_HOST"
fi
if [[ -z "$GATEWAY_PORT" ]]; then
  GATEWAY_PORT="443"
fi
if [[ "$TRANSPORT" == "tailscale" ]]; then
  [[ "$GATEWAY_HOST" == *.ts.net ]] || fail "Tailscale test transport requires a *.ts.net Gateway hostname"
  [[ "$GATEWAY_PORT" == "443" ]] || fail "Tailscale test transport requires TLS port 443"
fi

[[ "$(uname -s)" == "Darwin" ]] || fail "Calla Mac bootstrap must run on macOS"
ACCESS_PROXY_PLIST="$HOME/Library/LaunchAgents/$ACCESS_PROXY_LABEL.plist"
NODE_HOST_PLIST="$HOME/Library/LaunchAgents/$NODE_HOST_LABEL.plist"
LOG_DIRECTORY="$HOME/Library/Logs/Calla"

check_prerequisites() {
  local missing=0
  local required=(security launchctl openclaw python3)
  if [[ "$TRANSPORT" == "cloudflare" ]]; then
    required+=(cloudflared)
  else
    required+=(tailscale)
  fi
  for command in "${required[@]}"; do
    if command -v "$command" >/dev/null 2>&1; then
      printf '  %-14s available\n' "$command"
    else
      printf '  %-14s missing\n' "$command" >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || fail "install the missing Calla prerequisites"
  if [[ "$TRANSPORT" == "tailscale" ]]; then
    tailscale status --json >/dev/null || fail "Tailscale is not connected"
  fi
}

launchagent_status() {
  local path="$1"
  [[ -f "$path" ]] && echo installed || echo absent
}

if [[ "$MODE" == "check" ]]; then
  check_prerequisites
  printf '  %-14s %s\n' "transport" "$TRANSPORT"
  printf '  %-14s %s\n' "node host" "$(launchagent_status "$NODE_HOST_PLIST")"
  if [[ "$TRANSPORT" == "cloudflare" ]]; then
    printf '  %-14s %s\n' "Access proxy" "$(launchagent_status "$ACCESS_PROXY_PLIST")"
    printf '  %-14s %s\n' "service token" "$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a service-token-id >/dev/null 2>&1 && echo present || echo absent)"
  else
    printf '  %-14s %s\n' "Gateway URL" "wss://$GATEWAY_HOST:$GATEWAY_PORT"
  fi
  printf '  %-14s %s\n' "gateway token" "$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a openclaw-gateway-token >/dev/null 2>&1 && echo present || echo absent)"
  exit 0
fi

[[ "$YES" -eq 1 ]] || fail "$MODE requires --yes"
check_prerequisites

if [[ "$MODE" == "remove" ]]; then
  launchctl bootout "gui/$(id -u)" "$ACCESS_PROXY_PLIST" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)" "$NODE_HOST_PLIST" >/dev/null 2>&1 || true
  rm -f "$ACCESS_PROXY_PLIST" "$NODE_HOST_PLIST"
  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a service-token-id >/dev/null 2>&1 || true
  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a service-token-secret >/dev/null 2>&1 || true
  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a openclaw-gateway-token >/dev/null 2>&1 || true
  echo "Removed only Calla's LaunchAgents and Keychain entries. The paired node is retained for explicit server-side removal."
  exit 0
fi

if [[ "$TRANSPORT" == "cloudflare" ]]; then
  read -r -p "Cloudflare service-token ID: " SERVICE_TOKEN_ID
  read -r -s -p "Cloudflare service-token secret: " SERVICE_TOKEN_SECRET; echo
  [[ -n "$SERVICE_TOKEN_ID" && -n "$SERVICE_TOKEN_SECRET" ]] || fail "Cloudflare service-token credentials are required"
  security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a service-token-id -w "$SERVICE_TOKEN_ID" >/dev/null
  security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a service-token-secret -w "$SERVICE_TOKEN_SECRET" >/dev/null
  unset SERVICE_TOKEN_ID SERVICE_TOKEN_SECRET
fi
read -r -s -p "OpenClaw Gateway token: " GATEWAY_TOKEN; echo
[[ -n "$GATEWAY_TOKEN" ]] || fail "an OpenClaw Gateway token is required"
security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a openclaw-gateway-token -w "$GATEWAY_TOKEN" >/dev/null
unset GATEWAY_TOKEN

plugin_path="$REPOSITORY_ROOT/integrations/openclaw"
openclaw plugins inspect desktop-tutor --runtime --json >/dev/null 2>&1 || openclaw plugins install "$plugin_path"
node_config='{"role":"node","stateDirectory":"~/.openclaw/calla","requireOwnerIdentity":true}'
patch="{\"plugins\":{\"entries\":{\"desktop-tutor\":{\"enabled\":true,\"config\":$node_config}}}}"
printf '%s' "$patch" | openclaw config patch --stdin --dry-run >/dev/null
printf '%s' "$patch" | openclaw config patch --stdin >/dev/null
openclaw config validate

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIRECTORY"
chmod 700 "$LOG_DIRECTORY"
if [[ "$TRANSPORT" == "cloudflare" ]]; then
  cat >"$ACCESS_PROXY_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$ACCESS_PROXY_LABEL</string>
  <key>ProgramArguments</key><array><string>$SCRIPT_DIRECTORY/calla-access-proxy.sh</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>CALLA_KEYCHAIN_SERVICE</key><string>$KEYCHAIN_SERVICE</string>
    <key>CALLA_PROXY_HOSTNAME</key><string>$CLOUDFLARE_HOSTNAME</string>
    <key>CALLA_PROXY_LISTENER</key><string>$LISTENER</string>
  </dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIRECTORY/access-proxy.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIRECTORY/access-proxy.log</string>
</dict></plist>
EOF
  chmod 600 "$ACCESS_PROXY_PLIST"
  launchctl bootout "gui/$(id -u)" "$ACCESS_PROXY_PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$ACCESS_PROXY_PLIST"
  NODE_GATEWAY_HOST="127.0.0.1"
  NODE_GATEWAY_PORT="18790"
  NODE_GATEWAY_TLS="false"
else
  launchctl bootout "gui/$(id -u)" "$ACCESS_PROXY_PLIST" >/dev/null 2>&1 || true
  NODE_GATEWAY_HOST="$GATEWAY_HOST"
  NODE_GATEWAY_PORT="$GATEWAY_PORT"
  NODE_GATEWAY_TLS="true"
fi

cat >"$NODE_HOST_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$NODE_HOST_LABEL</string>
  <key>ProgramArguments</key><array><string>$SCRIPT_DIRECTORY/calla-node-host.sh</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>CALLA_KEYCHAIN_SERVICE</key><string>$KEYCHAIN_SERVICE</string>
    <key>CALLA_NODE_GATEWAY_HOST</key><string>$NODE_GATEWAY_HOST</string>
    <key>CALLA_NODE_GATEWAY_PORT</key><string>$NODE_GATEWAY_PORT</string>
    <key>CALLA_NODE_GATEWAY_TLS</key><string>$NODE_GATEWAY_TLS</string>
    <key>CALLA_NODE_DISPLAY_NAME</key><string>$DISPLAY_NAME</string>
  </dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIRECTORY/node-host.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIRECTORY/node-host.log</string>
</dict></plist>
EOF
chmod 600 "$NODE_HOST_PLIST"
launchctl bootout "gui/$(id -u)" "$NODE_HOST_PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$NODE_HOST_PLIST"

if [[ "$TRANSPORT" == "tailscale" ]]; then
  echo "Calla private test node is connecting to wss://$NODE_GATEWAY_HOST:$NODE_GATEWAY_PORT. On the Gateway, approve its exact pending device and node command request; no Cloudflare resource is used."
else
  echo "Calla proxy is configured at $LISTENER and the node host is connecting through it. Approve its exact pending identity on the Gateway."
fi
