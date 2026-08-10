#!/usr/bin/env bash
# Say something to Calla.
#
# One sender for every surface — the tooltip's own buttons, the Raycast
# commands, anything added later — so there is a single answer to "where does a
# question go" and a single place to change it.
#
# The turn runs on the Gateway. This Mac has no provider credentials and is not
# meant to have any: the thinking is never local.
set -uo pipefail

MESSAGE="${*:-}"
if [[ -z "${MESSAGE// }" ]]; then
  echo "usage: calla-ask.sh <what to say to Calla>" >&2
  exit 2
fi

GATEWAY_SSH="${CALLA_GATEWAY_SSH:-isnakolah@nomonhomelab}"
# A control socket path has to fit in 104 bytes.
CONTROL="/tmp/calla-raycast.sock"
SESSION="${CALLA_SESSION:-calla-raycast}"
# Teaching has its own agent. The general assistant answers a "how do I…" the
# way an assistant should — with a written recipe — and no tool description
# outranks eight kilobytes of workspace persona telling it to be helpful in
# chat. A workspace whose first instruction is "never write instructions" is
# what makes it point at the screen instead.
AGENT="${CALLA_AGENT:-calla}"
# "high" costs about three minutes a step and buys nothing: finding a labelled
# control in a screenshot is recognition, not reasoning.
THINKING="${CALLA_THINKING:-low}"

QUOTED=$(printf '%s' "$MESSAGE" | sed "s/'/'\\\\''/g")
REMOTE="export PATH=\$HOME/.npm-global/bin:\$PATH;
nohup openclaw agent --agent $AGENT --session-id $SESSION --thinking $THINKING -m '$QUOTED' \
  > /tmp/calla-raycast-last.txt 2>&1 &
echo started"

if ! OUTPUT=$(ssh \
  -o BatchMode=yes -o ConnectTimeout=8 \
  -o ControlMaster=auto -o "ControlPath=$CONTROL" -o ControlPersist=8h \
  "$GATEWAY_SSH" "$REMOTE" 2>&1); then
  if [[ "$OUTPUT" == *"login.tailscale.com"* ]]; then
    printf 'Tailscale needs one approval: %s\n' \
      "$(printf '%s' "$OUTPUT" | grep -o 'https://login.tailscale.com/[^ ]*' | head -1)"
    exit 1
  fi
  printf 'Could not reach Calla: %s\n' "${OUTPUT##*$'\n'}"
  exit 1
fi
exit 0
