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
allowlisted window, screenshot-driven guiding and narration, pack-authored local
overlays, point-only visual search priors, local approval, and fresh detector
verification. No capture is written to disk.

## Settings

The menu bar is where this Mac's owner sees and changes what Calla may do.
Everything there used to be a constant in the source:

- **Applications Calla may look at.** A lesson names the application it is
  teaching, but the effective allowlist is the intersection with this list, so a
  lesson can narrow the owner's choice and never widen it. "Allow <frontmost
  app>" adds whatever is in front, so no bundle identifier has to be typed.
- **Capture detail** — the long edge of the window image a lesson sends. Less
  detail keeps more of the screen unreadable off this Mac; more helps the model
  read small labels.
- **Fade the pointer near mine** — Calla's pointer thins out as the owner's own
  pointer approaches it.
- **Screen Recording status**, with a button to the right pane in System
  Settings, so a missing grant is visible here rather than only inside a failed
  tool call.

Scoping the overlay to the application being taught is deliberately not a
setting. Calla annotating a window it is not teaching is a bug, not a taste.

## Permissions

Screen Recording is the only permission the default teaching path needs; it is
what lets the host capture the one focused window. Accessibility is needed only
for the pack-authored path, which resolves a descriptor to a real control and
can request approval to click it. Guiding and narrating touch neither the
Accessibility tree nor the mouse, so the host no longer asks for Accessibility
at launch — a lesson that needs it will say so.

Both grants attach to `Calla TutorHost.app`, which `scripts/build-tutor-host-app.sh`
builds and installs. The overlay renderer ships nested at
`Contents/Helpers/CallaOverlayHelper.app` because AppKit panels only composite
from a separate application of their own.

## Overlay scope

The cursor and tooltip belong to the application being taught, not to the
desktop. Every point carries that window's rect and bundle identifier, so the
tooltip is placed inside the window rather than anywhere on the display, and the
whole overlay fades out while the learner has another application in front and
returns when they come back. Focus is read from `NSWorkspace`, which needs no
permission of its own.
