# Open Desktop Tutor

Open Desktop Tutor is an open-source, screen-aware teaching assistant for complex desktop applications. It teaches first: explain, highlight, point, let the learner try, verify, and escalate to bounded computer control only when the learner asks.

This repository is an early Phase 0 developer build. It currently includes:

- a versioned App Pack format and compiler;
- a Blender 4.3-4.5 starter pack with one authored Bevel lesson;
- a packaged, read-only Blender observation bridge;
- an OpenClaw plugin exposing semantic tutor operations instead of raw coordinates;
- protocol schemas shared by the brain, Mac host, packs, and app bridges;
- a Swift package containing the future Mac host's protocol models and action policy.

The native overlay, screen resolver, AI pointer, local approval window, and verified mouse-control loop are not built yet. The current Mac test proves the knowledge pack, Blender state bridge, OpenClaw plugin boundary, and Swift policy—not the finished tutoring experience.

## Test it on a Mac

### Requirements

- macOS 13 or newer for development; the eventual ScreenCaptureKit target may raise this minimum;
- Blender `>=4.3 <4.6` for the included pack;
- Python 3.11 or newer;
- Node.js and npm;
- Git and Make;
- Xcode Command Line Tools for `swift test`;
- OpenClaw `>=2026.7.1-2` only if you want to inspect the brain plugin locally.

If a prerequisite is missing, install Xcode's tools with `xcode-select --install`. Homebrew is one convenient way to install Python, Node, and Blender, but it is not required.

### Guided setup

From the repository root:

```bash
./scripts/setup-macos.sh --check-only
./scripts/setup-macos.sh
```

The setup script shows five explicit stages. It creates `.venv`, installs this project into that environment, runs the available tests, builds the Blender App Pack, packages the Blender add-on, runs `swift test` when Swift is available, and prints the remaining Blender steps.

It does **not** silently modify Blender or OpenClaw. To explicitly link the plugin into the active OpenClaw installation on this Mac, use:

```bash
./scripts/setup-macos.sh --install-openclaw-plugin
```

Do not use that flag when your Gateway runs on a dedicated server; follow the dedicated-server instructions below instead.

### Install and verify the Blender bridge

After guided setup:

1. Open Blender 4.3-4.5.
2. Select **Edit → Preferences → Add-ons**.
3. Choose **Install from Disk** and select `build/blender/open-desktop-tutor-blender-0.1.0.zip`.
4. Enable **Interface: Open Desktop Tutor Bridge**.
5. Leave Blender open with the default cube selected.
6. In Terminal, run:

```bash
.venv/bin/python tools/blender_bridge_probe.py --operation ping
.venv/bin/python tools/blender_bridge_probe.py --operation observe_state
```

A successful observation returns JSON containing the Blender version, current mode, active object, modifiers, and visible editor types. The probe never prints the bridge's session token.

The add-on only permits `ping` and `observe_state`. Its loopback descriptor lives temporarily under `~/Library/Caches/OpenDesktopTutor/`, is owner-readable only, and is deleted when the add-on stops.

### Verify the Blender knowledge pack

```bash
make PYTHON=.venv/bin/python pack-check
make PYTHON=.venv/bin/python pack-build
make PYTHON=.venv/bin/python pack-search QUERY=bevel
```

The compiled pack is `build/packs/blender.otpack`. Searching for `bevel` should return the Bevel lesson, its success detector, and the non-destructive-modifier concept.

### Manual setup

The equivalent commands, without the guided script, are:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -e .
make PYTHON=.venv/bin/python test pack-build blender-addon
swift test --package-path packages/swift/TutorKit
```

If Swift is unavailable, install Xcode Command Line Tools and rerun only the last command.

## OpenClaw as the user-owned brain

OpenClaw may run on this Mac or on a dedicated server owned by the user. It chooses teaching moves and requests semantic operations. The future `TutorHost.app` on the Mac remains authoritative for screen capture, target freshness, local approvals, input dispatch, and verification.

### Local Gateway

The guided installer can link and inspect the plugin with `--install-openclaw-plugin`. To do it manually:

```bash
openclaw plugins install --link "$PWD/integrations/openclaw"
openclaw plugins enable desktop-tutor
openclaw plugins inspect desktop-tutor --runtime --json
```

### Dedicated user-owned Gateway

Run these commands on the Gateway server from its copy of this repository:

```bash
openclaw plugins install ./integrations/openclaw
openclaw plugins enable desktop-tutor
openclaw plugins inspect desktop-tutor --runtime --json
openclaw nodes list --json
```

After pairing the Mac node, copy its exact node ID and configure the plugin:

```bash
openclaw config set plugins.entries.desktop-tutor.config.nodeId '"PAIRED_MAC_NODE_ID"' --strict-json
openclaw config set plugins.entries.desktop-tutor.config.requireOwnerIdentity true --strict-json
openclaw config validate
```

The plugin should register these tools:

- `tutor_observe`
- `tutor_retrieve`
- `tutor_point`
- `tutor_propose_action`
- `tutor_verify`

Phase 0 warning: tool registration can be inspected now, but tutor calls requiring the Mac will fail until `TutorHost.app` supplies `~/Library/Application Support/OpenDesktopTutor/tutor-host.sock`. The repository does not yet claim an end-to-end OpenClaw-to-screen demonstration.

## Troubleshooting

### No Blender descriptor found

Keep Blender open and confirm the add-on checkbox is enabled. Disable and re-enable it, then rerun the probe. The descriptor is intentionally removed whenever the bridge shuts down.

### Blender version rejected by the pack

The starter pack currently declares `>=4.3 <4.6`. Use Blender 4.3, 4.4, or 4.5 until another version mapping is authored and tested.

### OpenClaw reports a missing TutorHost socket

That is expected in Phase 0. Plugin registration is testable; the native socket host is the next implementation milestone.

### macOS asks for Screen Recording or Accessibility permission

The read-only Blender bridge does not need either permission. Do not grant them for this Phase 0 test. Those permissions will be requested by the signed native host only when its capture and control features exist.

### Reporting a Mac failure

Include macOS, Blender, Python, Node, Swift, and OpenClaw versions; the failing command; and its output. Do not include bridge descriptors, session tokens, screen captures, or private OpenClaw configuration.

## Data and safety boundary

Phase 0 does not capture or upload screenshots. App Packs, compiled search indexes, test artifacts, and Blender observations stay on the user's machines. A remote OpenClaw Gateway remains user-owned, but future screen context sent to it will still require an explicit user-controlled privacy policy.

There is intentionally no `click(x,y)`, shell, or arbitrary Blender Python tool in the brain protocol. Consequential actions will require a fresh semantic target receipt and local Mac approval.

See the [Phase 0 architecture](docs/architecture/phase-0.md), [security policy](SECURITY.md), and [third-party review](third_party/NOTICE.md) for the current boundaries and dependency decisions.
