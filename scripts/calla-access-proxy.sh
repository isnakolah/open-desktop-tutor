#!/usr/bin/env bash
# LaunchAgent entrypoint. Secrets are read from Keychain only into cloudflared's
# child environment; neither this script nor the plist receives secret arguments.
set -euo pipefail

KEYCHAIN_SERVICE="${CALLA_KEYCHAIN_SERVICE:-com.calla.openclaw}"
HOSTNAME="${CALLA_PROXY_HOSTNAME:-node.calla.nomonlab.com}"
LISTENER="${CALLA_PROXY_LISTENER:-127.0.0.1:18790}"

service_token_id="$(/usr/bin/security find-generic-password -s "$KEYCHAIN_SERVICE" -a service-token-id -w)"
service_token_secret="$(/usr/bin/security find-generic-password -s "$KEYCHAIN_SERVICE" -a service-token-secret -w)"

if [[ -z "$service_token_id" || -z "$service_token_secret" ]]; then
  echo "Calla access proxy credentials are missing from the login Keychain." >&2
  exit 78
fi

exec /usr/bin/env \
  TUNNEL_SERVICE_TOKEN_ID="$service_token_id" \
  TUNNEL_SERVICE_TOKEN_SECRET="$service_token_secret" \
  cloudflared access tcp --hostname "$HOSTNAME" --url "$LISTENER" --loglevel info
