#!/usr/bin/env bash
# LaunchAgent entrypoint. The Gateway token is read from Keychain only into the
# node-host child environment, never a plist, log, or command argument.
set -euo pipefail

KEYCHAIN_SERVICE="${CALLA_KEYCHAIN_SERVICE:-com.calla.openclaw}"
GATEWAY_HOST="${CALLA_NODE_GATEWAY_HOST:-127.0.0.1}"
GATEWAY_PORT="${CALLA_NODE_GATEWAY_PORT:-18790}"
GATEWAY_TLS="${CALLA_NODE_GATEWAY_TLS:-false}"
DISPLAY_NAME="${CALLA_NODE_DISPLAY_NAME:-Calla Mac}"

gateway_token="$(/usr/bin/security find-generic-password -s "$KEYCHAIN_SERVICE" -a openclaw-gateway-token -w)"
if [[ -z "$gateway_token" ]]; then
  echo "Calla Gateway token is missing from the login Keychain." >&2
  exit 78
fi

arguments=(node run --host "$GATEWAY_HOST" --port "$GATEWAY_PORT" --display-name "$DISPLAY_NAME")
if [[ "$GATEWAY_TLS" == "true" ]]; then
  arguments+=(--tls)
fi
exec /usr/bin/env OPENCLAW_GATEWAY_TOKEN="$gateway_token" openclaw "${arguments[@]}"
