# Calla OpenClaw integration

The plugin identifier remains `desktop-tutor`; Calla is the user-facing name. It never exposes raw coordinates, shell execution, CGEvent, or arbitrary Blender code.

## Roles

| Role | Runs on | Registers |
| --- | --- | --- |
| `gateway` | Existing user-owned OpenClaw Gateway | `tutor_*` tools, local action policy, paired-node invocation, server-local retrieval |
| `node` | Paired macOS OpenClaw node | Only `desktop-tutor.host`, forwarding validated envelopes to local TutorHost |
| `both` | Development only | Both surfaces; requires `developmentMode: true` |

The Gateway invokes `desktop-tutor.host` on the node enrolled by the bundled
private-Tailscale setup. The node handler forwards one validated
newline-delimited JSON envelope to TutorHost's mode-`0600` Unix socket. Until
TutorHost is running it returns the typed result `TUTOR_HOST_UNAVAILABLE`.

Gateway configuration is additive:

```json5
{
  plugins: {
    entries: {
      "desktop-tutor": {
        enabled: true,
        config: {
          role: "gateway",
          stateDirectory: "~/.openclaw/calla",
          nodeId: "AUTO_ENROLLED_CALLA_MAC_NODE_ID",
          requireOwnerIdentity: false,
        },
      },
    },
  },
  gateway: {
    mode: "local",
    bind: "loopback",
    auth: { mode: "none" },
    tailscale: { mode: "off" },
  },
}
```

`scripts/setup-calla-server.sh` adds the private Tailscale HTTPS proxy outside
the Gateway, because the Gateway itself remains loopback-bound. Use
`role: "node"` on the Mac. It must not register Gateway tools.

## Server-local App Pack retrieval

`tutor_retrieve` runs on the Gateway; it does not round-trip to the Mac. It requires the active application bundle ID and version, then filters packs by their `apps` compatibility constraints and entities by optional `app_versions`.

Install a compiled App Pack into the user-owned server state:

```bash
python3 tools/calla_pack_store.py build/packs/blender.otpack \
  --state-directory ~/.openclaw/calla
```

This copies the `.otpack` and writes a mode-`0600` JSON retrieval sidecar under `packs/` and `indexes/`. It does not create a network registry or copy the pack to the Mac.

## Verification

```bash
cd integrations/openclaw
npm test
```

The tests prove role isolation, server-local version-filtered retrieval,
coordinate rejection, local one-shot approval, socket transport, and typed
TutorHost unavailability.
