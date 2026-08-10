# Calla macOS node

`./scripts/setup-macos.sh --install` installs the complete private Mac side:

- `com.calla.tutor-host`, the native Swift menu-bar TutorHost;
- `com.calla.openclaw-node-host`, the `desktop-tutor` node-role plugin; and
- a tailnet-only WSS connection through the configured Tailscale HTTPS proxy.

No Gateway token or manually copied node ID is needed.
The server-side enroller binds the first pending node named `Calla Mac`.

The native host listens only on
`~/Library/Application Support/OpenDesktopTutor/tutor-host.sock`, with its
directory mode `0700` and socket mode `0600`. Protocol v2 handles semantic
observations, an explicitly requested in-memory JPEG of only the focused
allowlisted window, pack-authored local overlays, point-only visual search
priors, local approval, and fresh detector verification. macOS Accessibility
permission is required; no capture is written to disk.
