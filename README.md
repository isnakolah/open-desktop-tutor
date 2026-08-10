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

## Native Mac host

`apps/macos/TutorHost/` is the Swift menu-bar host. It accepts only one
newline-delimited semantic envelope over an owner-only Unix socket. It never
accepts coordinates, shell commands, arbitrary Blender Python, or raw typing.

For the initial Blender 5.2 lesson it can:

1. observe the focused Blender window and, only when requested, return an in-memory window JPEG bound to that snapshot;
2. resolve any installed pack-authored UI descriptor locally and place a coordinate-free overlay receipt;
3. use a vision region only as a pointing search prior, never as action authority;
4. request local approval for one pack-authorized semantic click; and
5. verify the canonical pack-authored detector locally.

The model never receives resolved screen coordinates. The Mac keeps the snapshot,
target resolution, local approval, detector evidence, and Accessibility action authority.

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
scripts/bootstrap-calla-mac.sh --check | --install --yes | --remove --yes
tools/calla_openclaw_setup.py --check | --install [--yes] | --status | --remove --yes
tools/calla_node_enroller.py [--watch]
```

## Verification boundary

Linux checks prove the installer, plugin protocol, App Pack, bridge, and
auto-enrollment behavior. A real Mac is still required to prove the final user
path: the native host must receive Accessibility permission, resolve the live
Blender 5.2 control, accept one local approval, act, and verify the result.
