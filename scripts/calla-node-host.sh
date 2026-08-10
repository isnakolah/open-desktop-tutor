#!/usr/bin/env bash
# LaunchAgent entrypoint for the private, no-login Calla Gateway.
set -euo pipefail

GATEWAY_HOST="${CALLA_NODE_GATEWAY_HOST:-127.0.0.1}"
GATEWAY_PORT="${CALLA_NODE_GATEWAY_PORT:-18790}"
GATEWAY_TLS="${CALLA_NODE_GATEWAY_TLS:-false}"
DISPLAY_NAME="${CALLA_NODE_DISPLAY_NAME:-Calla Mac}"

arguments=(node run --host "$GATEWAY_HOST" --port "$GATEWAY_PORT" --display-name "$DISPLAY_NAME")
if [[ "$GATEWAY_TLS" == "true" ]]; then
  arguments+=(--tls)
fi
exec openclaw "${arguments[@]}"
