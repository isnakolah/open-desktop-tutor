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

- **Whether Calla is actually reachable.** The host never talks to the Gateway
  itself — the node agent holds that WebSocket — so the menu reports what that
  agent last logged about its connection, names the Gateway it reached, and
  shows when Calla last sent this Mac anything. Without it, a lesson that never
  starts and a lesson nobody asked for look identical from here.

- **Applications Calla may look at.** A lesson names the application it is
  teaching, but the effective allowlist is the intersection with this list, so a
  lesson can narrow the owner's choice and never widen it. "Allow <frontmost
  app>" adds whatever is in front, so no bundle identifier has to be typed.
- **Capture detail** — the long edge of the window image a lesson sends. Less
  detail keeps more of the screen unreadable off this Mac; more helps the model
  read small labels.
- **Pointer size**, **fade the pointer near mine** — Calla's pointer thins out
  as the owner's own pointer approaches it — and **show the status capsule**.
- **Reset**, which puts every choice including the allowlist back to the
  shipped default, and **Logs**, which opens the node agent's log directory.
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

## Shortcuts

Answering Calla never needs the mouse, and the tooltip is a poor click target
because it moves out from under your pointer:

| | |
| --- | --- |
| `⌥⌘⏎` | Did it — look again and point at the next step |
| `⌥⌘/` | Ask a question, typed into the tooltip |
| `⌥⌘.` | Stop the lesson |

These are Carbon hot keys rather than a global `NSEvent` monitor, which is what
keeps them working without an Accessibility grant.

A system-wide hot key outranks the application underneath it, so Calla claims
these three only while a lesson is on screen and gives them back the moment it
ends. A collision can therefore last as long as a lesson and no longer, rather
than taking three combinations away from every program on the Mac for good. If
another application already holds one when a lesson starts, Calla says so
instead of leaving a button that looks live and does nothing.

## Overlay scope

The cursor and tooltip are placed against the taught window — the tooltip sits
inside its bounds, and the pointer is clamped to it — so Calla never annotates
something it is not teaching.

They do not disappear when you look elsewhere. A lesson that vanished every time
the learner checked something had to be found again, so the step stays on screen
until the lesson ends or teaching is switched off in the menu bar.

The pointer never fades or moves out of the way; it is the thing being followed,
and it marks the spot even when the words are gone. The tooltip hides completely
while your own pointer is over it, and returns the moment you move away.

Three other answers were tried and are worse. Fading it leaves half-transparent
text over a busy interface, which is harder to read than either state and still
occludes. Stepping to another corner detaches the words from the arrow, because
a box this wide is only ever adjacent to the arrow at one of its own corners.
Collapsing it in place read as the tooltip vanishing anyway.

The hover test is made against the tooltip's anchor, never its live frame. That
distinction is what keeps the behaviour from chasing itself: earlier versions
tested against something the behaviour changed, so acting on the answer changed
the answer, and the tooltip shook or ping-ponged. Hiding moves and resizes
nothing, so it cannot recur.

A lesson shows its whole route: `tutor_plan` hands the Mac the steps up front
and the tooltip lists them, done ones struck through, the current one lit. It is
provisional — the model re-issues it when the screen turns out differently — so
the learner can see where this is going without the plan becoming a script.

Waiting looks like waiting: a ring pulses out of the pointer's tip and the
tooltip shows moving dots while a request is in flight, including one asked for
from Raycast, which tells the Mac before the request leaves.

**Find it** in the menu bar pulses the pointer and tooltip where they already
are, for a lesson lost on a large display.
