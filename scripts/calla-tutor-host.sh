#!/usr/bin/env bash
# LaunchAgent entrypoint for the local native TutorHost.
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
HOST_PACKAGE="$REPOSITORY_ROOT/apps/macos/TutorHost"
SOCKET_DIRECTORY="$HOME/Library/Application Support/OpenDesktopTutor"

[[ -f "$HOST_PACKAGE/Package.swift" ]] || {
  echo "Calla TutorHost package is missing: $HOST_PACKAGE" >&2
  exit 78
}

mkdir -p "$SOCKET_DIRECTORY"
chmod 700 "$SOCKET_DIRECTORY"
exec /usr/bin/xcrun swift run --package-path "$HOST_PACKAGE" -c release CallaTutorHost
