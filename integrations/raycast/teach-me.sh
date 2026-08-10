#!/bin/bash
#
# Ask Calla to teach you whatever is on screen, without leaving it.
#
# Raycast overlays the application you are using and hands focus back when it
# closes, so by the time the lesson starts you are already looking at the thing
# being taught. The Mac host remembers the allowlisted application you were last
# in, so the request lands on that one rather than on Raycast.
#
# The turn runs on the Gateway. Nothing here runs a model locally: this Mac has
# no provider credentials and is not supposed to have any.
#
# Install: Raycast > Extensions > Script Commands > Add Directories,
# then pick integrations/raycast in this checkout.
#
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Teach me…
# @raycast.mode compact
#
# Optional parameters:
# @raycast.icon 🎓
# @raycast.packageName Calla
# @raycast.argument1 { "type": "text", "placeholder": "what do you want to learn?", "percentEncoded": false }
#
# Documentation:
# @raycast.description Ask Calla to point at the next thing to do in the app you are using.
# @raycast.author Calla

set -uo pipefail

GOAL="${1:-}"
GATEWAY_HOST="${CALLA_GATEWAY_SSH:-isnakolah@nomonhomelab}"
# Short path: a control socket lives under a 104-byte limit, and the session
# directory names blow past it.
CONTROL="/tmp/calla-raycast.sock"
SESSION="calla-raycast"

if [[ -z "${GOAL// }" ]]; then
  echo "Say what you want to learn, for example: how do I bevel a cube"
  exit 1
fi

# Reuse one authenticated connection. Tailscale SSH mints a browser check per
# new connection, so a persistent master is what keeps this from prompting on
# every invocation.
SSH_OPTIONS=(
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o ControlMaster=auto
  -o "ControlPath=$CONTROL"
  -o ControlPersist=8h
)

# Escape the goal for the remote shell rather than interpolating it raw.
QUOTED_GOAL=$(printf '%s' "$GOAL" | sed "s/'/'\\\\''/g")

REMOTE="export PATH=\$HOME/.npm-global/bin:\$PATH;
nohup openclaw agent --session-id $SESSION -m '/teach $QUOTED_GOAL' \
  > /tmp/calla-raycast-last.json 2>&1 &
echo started"

if ! OUTPUT=$(ssh "${SSH_OPTIONS[@]}" "$GATEWAY_HOST" "$REMOTE" 2>&1); then
  if [[ "$OUTPUT" == *"login.tailscale.com"* ]]; then
    URL=$(printf '%s' "$OUTPUT" | grep -o 'https://login.tailscale.com/[^ ]*' | head -1)
    echo "Tailscale needs one approval: $URL"
    exit 1
  fi
  echo "Could not reach Calla's Gateway: ${OUTPUT##*$'\n'}"
  exit 1
fi

echo "Calla is looking at your screen — switch back to the app you want taught."
