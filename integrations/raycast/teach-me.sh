#!/bin/bash
#
# Ask Calla anything about the app you are using, without leaving it.
#
# Raycast overlays the application you are in and hands focus straight back when
# it closes, so by the time the lesson starts you are already looking at the
# thing being taught. The Mac host resolves the allowlisted application you were
# last in, so the lesson lands there rather than on Raycast.
#
# The turn runs on the Gateway. This Mac has no provider credentials and is not
# meant to have any, so nothing here can quietly think locally.
#
# Every question continues the same lesson, so "what about the other one?" and
# "I did that" both work. To start fresh, just say so in the question.
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
source "$(dirname "$0")/_calla-send.sh"

GOAL="${1:-}"
if [[ -z "${GOAL// }" ]]; then
  echo "Say what you want to learn, for example: how do I bevel a cube"
  exit 1
fi

calla_send "/teach $GOAL" || exit 1
echo "Calla is looking — switch back to the app you want taught."
