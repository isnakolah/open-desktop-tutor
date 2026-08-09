# Blender Tutor Bridge

This add-on exposes bounded read-only state to the local macOS TutorHost. It binds only to loopback, generates a new token at each launch, writes the connection descriptor with owner-only permissions, and schedules Blender API reads on Blender's main thread.

Allowed operations:

- `ping`
- `observe_state`

There is no arbitrary Python, file, asset-download, telemetry, or mutation operation.

Build the installable ZIP from the repository root:

```bash
make blender-addon
```

Install `build/blender/open-desktop-tutor-blender-0.1.0.zip` through Blender's **Edit → Preferences → Add-ons → Install from Disk** flow, enable **Interface: Open Desktop Tutor Bridge**, and verify the live add-on while Blender remains open:

```bash
python3 tools/blender_bridge_probe.py --operation ping
python3 tools/blender_bridge_probe.py --operation observe_state
```

The probe discovers the newest active descriptor in `~/Library/Caches/OpenDesktopTutor`, validates its owner-only permissions and loopback address, and never prints its session token.
