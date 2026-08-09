# Calla macOS node

The macOS side runs the `desktop-tutor` OpenClaw plugin in `node` role and exposes only `desktop-tutor.host` to its paired Gateway. Calla’s proxy binds locally on `127.0.0.1:18790`; the node connects to `ws://127.0.0.1:18790`, never directly to the public TCP endpoint.

## Bootstrap

On the Mac, after the server has produced a securely transferred service-token handoff, run:

```bash
./scripts/bootstrap-calla-mac.sh --check
./scripts/bootstrap-calla-mac.sh --install --yes
```

The installer prompts for the Cloudflare service-token ID/secret and the separate OpenClaw Gateway token. It writes them to the login Keychain, then installs `com.calla.openclaw-access-proxy` as a user LaunchAgent. The plist contains only the public hostname and loopback listener. `scripts/calla-access-proxy.sh` reads the two Cloudflare credentials from Keychain immediately before executing:

```text
cloudflared access tcp --hostname node.calla.nomonlab.com --url 127.0.0.1:18790
```

The credentials are not placed in the plist, logs, or proxy command arguments. Do not place them in a shell profile, repository, or screenshot.

The installer does not approve a node. Request pairing through the Mac OpenClaw node, inspect the pending request on the server, and approve its exact ID manually. Revoke/rotate a Cloudflare service token independently; this does not alter OpenClaw pairing.

## Current app boundary

The signed Calla/TutorHost UI is not yet generated in this Linux-hosted repository. The existing `TutorKit` Swift package supplies the protocol models and fail-closed action policy. Before the real TutorHost starts, node calls correctly return `TUTOR_HOST_UNAVAILABLE`; once a macOS host implements the local socket, it must preserve the semantic-target, fresh-snapshot, sensitive-context, and local-approval gates in `TutorCore.ActionPolicy`.
