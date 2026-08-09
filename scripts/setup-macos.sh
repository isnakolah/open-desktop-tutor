#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_ONLY=0
SKIP_TESTS=0
INSTALL_OPENCLAW_PLUGIN=0
ALLOW_NON_MACOS=0

usage() {
  cat <<'EOF'
Usage: ./scripts/setup-macos.sh [options]

Prepare the current Phase 0 build for testing on a Mac. The default run creates
a Python virtual environment, runs tests, compiles the Blender App Pack, and
packages the Blender add-on. It does not silently edit Blender or OpenClaw state.

Options:
  --check-only                 Check prerequisites without installing or building
  --skip-tests                 Build artifacts without running the test suites
  --install-openclaw-plugin    Explicitly link the plugin into this Mac's OpenClaw
  --allow-non-macos            CI/developer override for checking the script on Linux
  -h, --help                   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    --install-openclaw-plugin) INSTALL_OPENCLAW_PLUGIN=1 ;;
    --allow-non-macos) ALLOW_NON_MACOS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

step() {
  printf '\n[%s/5] %s\n' "$1" "$2"
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

command_version() {
  local command_name="$1"
  if command -v "$command_name" >/dev/null 2>&1; then
    printf '  %-10s %s\n' "$command_name" "$(command "$command_name" --version 2>/dev/null | head -n 1)"
  else
    printf '  %-10s missing\n' "$command_name"
    return 1
  fi
}

step 1 "Confirming the current test boundary"
cat <<'EOF'
This installer prepares the Phase 0 developer build. You can validate the App
Pack and install/probe the read-only Blender bridge. The native overlay, semantic
screen resolver, AI pointer, and approved-click loop are not built yet.
EOF

platform="$(uname -s)"
if [[ "$platform" != "Darwin" && "$ALLOW_NON_MACOS" -ne 1 ]]; then
  fail "this setup path requires macOS; use --allow-non-macos only for CI validation"
fi
printf 'Platform: %s\n' "$platform"

step 2 "Checking prerequisites"
missing=0
for required_command in git make python3 node npm; do
  command_version "$required_command" || missing=1
done
[[ "$missing" -eq 0 ]] || fail "install the missing prerequisites and run this script again"

python3 - <<'PY' || fail "Python 3.11 or newer is required"
import sys
raise SystemExit(0 if sys.version_info >= (3, 11) else 1)
PY

if command -v swift >/dev/null 2>&1; then
  command_version swift
else
  printf '  %-10s %s\n' "swift" "missing (TutorKit tests will be skipped; install Xcode Command Line Tools)"
fi
if command -v openclaw >/dev/null 2>&1; then
  command_version openclaw
else
  printf '  %-10s %s\n' "openclaw" "not installed locally (optional for pack/bridge testing)"
fi
if [[ -d /Applications/Blender.app ]]; then
  printf '  %-10s %s\n' "Blender" "/Applications/Blender.app"
else
  printf '  %-10s %s\n' "Blender" "not found in /Applications (install Blender 4.3-4.5 to test the pack)"
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  printf '\nPrerequisite check complete. No files or application settings were changed.\n'
  exit 0
fi

step 3 "Preparing the local Python environment"
cd "$REPOSITORY_ROOT"
if [[ ! -x .venv/bin/python ]]; then
  python3 -m venv .venv
fi
.venv/bin/python -m pip install -e .

step 4 "Building and validating Phase 0"
if [[ "$SKIP_TESTS" -eq 1 ]]; then
  make PYTHON="$REPOSITORY_ROOT/.venv/bin/python" pack-check pack-build blender-addon
else
  make PYTHON="$REPOSITORY_ROOT/.venv/bin/python" test pack-build blender-addon
fi
if command -v swift >/dev/null 2>&1; then
  swift test --package-path packages/swift/TutorKit
fi

if [[ "$INSTALL_OPENCLAW_PLUGIN" -eq 1 ]]; then
  command -v openclaw >/dev/null 2>&1 || fail "--install-openclaw-plugin requires the openclaw CLI"
  if openclaw plugins inspect desktop-tutor --json >/dev/null 2>&1; then
    printf 'OpenClaw plugin desktop-tutor is already installed; it was not overwritten.\n'
  else
    openclaw plugins install --link "$REPOSITORY_ROOT/integrations/openclaw"
  fi
  openclaw plugins enable desktop-tutor
  openclaw plugins inspect desktop-tutor --runtime --json
fi

step 5 "Manual application steps"
cat <<EOF
1. In Blender 4.3-4.5, open Edit > Preferences > Add-ons.
2. Choose Install from Disk and select:
   $REPOSITORY_ROOT/build/blender/open-desktop-tutor-blender-0.1.0.zip
3. Enable "Interface: Open Desktop Tutor Bridge" and keep Blender open.
4. Back in Terminal, verify the real bridge state:
   $REPOSITORY_ROOT/.venv/bin/python $REPOSITORY_ROOT/tools/blender_bridge_probe.py --operation observe_state
5. Verify App Pack retrieval:
   make -C "$REPOSITORY_ROOT" PYTHON="$REPOSITORY_ROOT/.venv/bin/python" pack-search QUERY=bevel

OpenClaw is optional for this Phase 0 bridge test. For a dedicated user-owned
Gateway, install the plugin on that server from integrations/openclaw, pair this
Mac as a node, then set the plugin's nodeId. End-to-end tutor tools will remain
unavailable until TutorHost.app supplies the local Unix socket.
EOF
