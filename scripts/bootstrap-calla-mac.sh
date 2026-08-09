#!/usr/bin/env bash
# Configure only the Mac-side Calla Access proxy and node-role plugin.
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
LABEL="com.calla.openclaw-access-proxy"
KEYCHAIN_SERVICE="com.calla.openclaw"
HOSTNAME="node.calla.nomonlab.com"
LISTENER="127.0.0.1:18790"
MODE="check"
YES=0

usage() {
  cat <<'EOF'
Usage: ./scripts/bootstrap-calla-mac.sh [--check|--install|--remove] [options]

Install stores the Cloudflare service-token ID/secret and the separate OpenClaw
Gateway token in the login Keychain. It writes a LaunchAgent with only public
configuration; the proxy wrapper reads the two Cloudflare secrets from Keychain
into cloudflared's child environment.

Options:
  --check              Inspect prerequisites and local Calla proxy state (default)
  --install             Prompt for secrets and install the node role and proxy
  --remove              Remove only the Calla LaunchAgent and its Keychain items
  --yes                 Confirm --install or --remove
  --hostname HOST       Defaults to node.calla.nomonlab.com
  --listener HOST:PORT  Defaults to 127.0.0.1:18790
  -h, --help            Show this help
EOF
}

fail() { echo "ERROR: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check" ;;
    --install) MODE="install" ;;
    --remove) MODE="remove" ;;
    --yes) YES=1 ;;
    --hostname) shift; [[ $# -gt 0 ]] || fail "--hostname needs a value"; HOSTNAME="$1" ;;
    --listener) shift; [[ $# -gt 0 ]] || fail "--listener needs a value"; LISTENER="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || fail "Calla Mac bootstrap must run on macOS"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIRECTORY="$HOME/Library/Logs/Calla"

check_prerequisites() {
  local missing=0
  for command in security launchctl cloudflared openclaw python3; do
    if command -v "$command" >/dev/null 2>&1; then
      printf '  %-14s available\n' "$command"
    else
      printf '  %-14s missing\n' "$command" >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || fail "install the missing Calla prerequisites"
}

if [[ "$MODE" == "check" ]]; then
  check_prerequisites
  printf '  %-14s %s\n' "LaunchAgent" "$([[ -f "$PLIST" ]] && echo installed || echo absent)"
  printf '  %-14s %s\n' "service token" "$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a service-token-id >/dev/null 2>&1 && echo present || echo absent)"
  printf '  %-14s %s\n' "gateway token" "$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a openclaw-gateway-token >/dev/null 2>&1 && echo present || echo absent)"
  exit 0
fi

[[ "$YES" -eq 1 ]] || fail "$MODE requires --yes"
check_prerequisites

if [[ "$MODE" == "remove" ]]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a service-token-id >/dev/null 2>&1 || true
  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a service-token-secret >/dev/null 2>&1 || true
  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a openclaw-gateway-token >/dev/null 2>&1 || true
  echo "Removed only Calla's LaunchAgent and Keychain entries. The paired node is retained for explicit server-side removal."
  exit 0
fi

read -r -p "Cloudflare service-token ID: " SERVICE_TOKEN_ID
read -r -s -p "Cloudflare service-token secret: " SERVICE_TOKEN_SECRET; echo
read -r -s -p "OpenClaw Gateway token: " GATEWAY_TOKEN; echo
[[ -n "$SERVICE_TOKEN_ID" && -n "$SERVICE_TOKEN_SECRET" && -n "$GATEWAY_TOKEN" ]] || fail "all three credentials are required"

# `security` has no stdin secret API; -w is used only during this interactive
# invocation. The secret is never written to the plist, logs, or proxy argv.
security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a service-token-id -w "$SERVICE_TOKEN_ID" >/dev/null
security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a service-token-secret -w "$SERVICE_TOKEN_SECRET" >/dev/null
security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a openclaw-gateway-token -w "$GATEWAY_TOKEN" >/dev/null
unset SERVICE_TOKEN_ID SERVICE_TOKEN_SECRET GATEWAY_TOKEN

plugin_path="$REPOSITORY_ROOT/integrations/openclaw"
openclaw plugins inspect desktop-tutor --runtime --json >/dev/null 2>&1 || openclaw plugins install "$plugin_path"
node_config="{\"role\":\"node\",\"stateDirectory\":\"~/.openclaw/calla\",\"requireOwnerIdentity\":true}"
patch="{\"plugins\":{\"entries\":{\"desktop-tutor\":{\"enabled\":true,\"config\":$node_config}}}}"
printf '%s' "$patch" | openclaw config patch --stdin --dry-run >/dev/null
printf '%s' "$patch" | openclaw config patch --stdin >/dev/null
openclaw config validate

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIRECTORY"
chmod 700 "$LOG_DIRECTORY"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$SCRIPT_DIRECTORY/calla-access-proxy.sh</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>CALLA_KEYCHAIN_SERVICE</key><string>$KEYCHAIN_SERVICE</string>
    <key>CALLA_PROXY_HOSTNAME</key><string>$HOSTNAME</string>
    <key>CALLA_PROXY_LISTENER</key><string>$LISTENER</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIRECTORY/access-proxy.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIRECTORY/access-proxy.log</string>
</dict></plist>
EOF
chmod 600 "$PLIST"
launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Calla proxy is configured at $LISTENER. Configure the Mac OpenClaw node to connect to ws://$LISTENER and request pairing; approve its exact node ID on the server."
