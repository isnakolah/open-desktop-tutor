# Calla / Open Desktop Tutor

This repository is the standalone desktop-tutor rewrite. It owns the Gateway
policy, the macOS node bootstrap, the native TutorHost, and the Blender lesson
pack. Do not use the broader `calla-openclaw` workspace to run this rewrite.

## What it sets up

The default path is private and self-contained:

```text
Gateway device                           Mac
---------------                          ---
OpenClaw, loopback-bound                 CallaTutorHost LaunchAgent
  no Gateway login                       Calla node LaunchAgent
  Tailscale HTTPS proxy                     └─ private tailnet WSS
  Calla node enroller                       macOS Accessibility approval
  desktop-tutor plugin                       Blender 5.2.x
```

`./scripts/setup-calla-server.sh --install --yes` configures the existing
OpenClaw Gateway on this device. It loads this checkout's plugin, enables the
private tailnet endpoint, disables the Gateway login requirement, installs the
Blender 5.2 App Pack, and starts a local enroller. The enroller binds the first
pending node named `Calla Mac`, so no node ID needs to be copied into config.

`./scripts/setup-macos.sh --install` builds and starts the native TutorHost and
the Mac OpenClaw node. It does not ask for a Gateway token or a copied node ID.
The Mac must be on the same private tailnet.

The only interactive steps are macOS-owned permissions: grant Accessibility to
the launched TutorHost and allow the local one-shot action prompt. Those cannot
be bypassed by a setup script.

## Quick start

On the device running the existing OpenClaw Gateway:

```bash
git clone https://github.com/isnakolah/open-desktop-tutor.git
cd open-desktop-tutor
./scripts/setup-calla-server.sh --install --yes
```

On the Mac, from the same checkout:

```bash
./scripts/setup-macos.sh --install
```

The default private endpoint is
`wss://nomonhomelab.tailec0dca.ts.net:443`. The Gateway itself remains
loopback-bound; Tailscale Serve supplies the tailnet-only HTTPS proxy.

## How a lesson runs

The default path needs screenshots and nothing else. Accessibility is optional,
and is only involved when a lesson uses an authored App Pack.

```text
Mac                          Gateway (the model)
---                          -------------------
tutor_observe            ->  one JPEG of the focused window, as an image
                             the model reads it
tutor_guide              <-  a region of that window, 0..1, plus one sentence
Calla's cursor arrives
there; the tooltip says
the sentence
tutor_narrate            <-  new words, same cursor
observe again            ->  the window moved, or the learner acted
```

`/teach <what you want to learn>` starts that loop. The plugin ships the loop as
system-prompt guidance, so the model knows to ask for the capture and to point
rather than describe.

Ask from the Mac itself with the Raycast command in `integrations/raycast/`, or
from any channel the Gateway is on. Calla teaches the allowlisted application
you were last using rather than the window you asked from, so triggering it
never means arranging your windows first.

Guiding draws and never acts. It cannot click, and the Mac refuses a region on
any operation that can — a pixel rectangle, a raw coordinate, or a region
attached to an action is rejected at both the Gateway and the Mac.

The overlay stays with the application being taught: the tooltip is kept inside
that window, and both cursor and tooltip fade out whenever the learner brings
something else forward, then return with it.

## Native Mac host

`apps/macos/TutorHost/` is the Swift menu-bar host, installed as
`Calla TutorHost.app`. It accepts only one newline-delimited semantic envelope
over an owner-only Unix socket. It never accepts coordinates, shell commands,
arbitrary Blender Python, or raw typing.

It can:

1. observe the focused allowlisted window and, only when requested, return an in-memory window JPEG bound to that snapshot;
2. guide: place Calla's cursor and tooltip on a model-supplied region of that window, re-finding the window itself first;
3. narrate: re-word the tooltip without moving the cursor;
4. resolve any installed pack-authored UI descriptor locally and place a coordinate-free overlay receipt;
5. request local approval for one pack-authorized semantic click; and
6. verify the canonical pack-authored detector locally.

The model never receives resolved screen coordinates. The Mac keeps the snapshot,
window geometry, target resolution, local approval, detector evidence, and
action authority.

Build and install the host with:

```bash
./scripts/build-tutor-host-app.sh
```

macOS asks for Screen Recording the first time a lesson requests a capture, and
asks again after a rebuild because ad-hoc signing changes the code hash. Check
the whole path without the Gateway:

```bash
.venv/bin/python tools/calla_guide_probe.py --bundle-id org.blenderfoundation.blender
```

## Blender 5.2 pack

The bundled pack targets Blender `>=5.2 <5.3` in English. Build and validate it
with:

```bash
make test pack-build blender-addon
```

The read-only Blender bridge remains useful for local diagnostics. Install the
generated add-on from Blender's **Edit → Preferences → Add-ons → Install from
Disk**, then enable **Interface: Open Desktop Tutor Bridge**.

## Commands

```text
scripts/setup-calla-server.sh --check | --install --yes | --status
scripts/setup-macos.sh --check-only | --install
scripts/build-tutor-host-app.sh [--build-only]
scripts/bootstrap-calla-mac.sh --check | --install --yes | --remove --yes
tools/calla_openclaw_setup.py --check | --install [--yes] | --status | --remove --yes
tools/calla_node_enroller.py [--watch]
tools/calla_guide_probe.py [--bundle-id ID] [--capture-out PATH]
```

## Verification boundary

Linux checks prove the installer, plugin protocol, App Pack, bridge, and
auto-enrollment behavior. A real Mac is still required to prove the final user
path: the native host must receive Accessibility permission, resolve the live
Blender 5.2 control, accept one local approval, act, and verify the result.
