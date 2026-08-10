# Calla agent instructions

Use the private Tailscale test path first. The default Mac command is:

```bash
./scripts/bootstrap-calla-mac.sh --install --yes
```

It connects only to the tailnet-only `nomonhomelab.tailec0dca.ts.net` Gateway
endpoint. Do not publish Calla DNS, configure Cloudflare Access, or use the
Cloudflare transport until Zero Trust Access is enabled and nested TLS covers
`node.calla.nomonlab.com`.

Keep the Gateway loopback-bound. Do not modify, adopt, or reuse
`nomonlab-public`; Calla owns only `calla-control`. Never expose Keychain,
OpenClaw, Cloudflare, bridge, or screenshot credentials in source, logs, or
reports.

Calla never writes a paired `nodeId` automatically. Do not bind a connected
node without the exact identity supplied by the operator; use
`calla_openclaw_setup.py --install --yes --node-id EXACT_APPROVED_NODE_ID`
only after that review. This keeps Calla's tutor invocation surface manually
bound even when an installed OpenClaw version has its own generic pairing flow.

Before handing off code changes, run `make test`. For runtime work, distinguish
private-Tailscale proof from Cloudflare production proof and from a real
macOS TutorHost teaching round trip.
