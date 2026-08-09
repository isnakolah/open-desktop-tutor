# Calla deployment guide

The complete, canonical Calla operator guide—including security prerequisites, Gateway setup, Cloudflare provisioning, Mac bootstrap, node pairing, verification, rotation, removal, and troubleshooting—is maintained in the repository [README](../README.md).

Keep this page as a stable documentation link for existing bookmarks. The detailed runbook below remains for reference.

Calla uses the existing user-owned OpenClaw Gateway as its only brain. It does not create a second Gateway and does not replace the existing WhatsApp, active-memory, plugin, or Tailscale configuration.

```text
Browser -- Cloudflare Access --> calla.nomonlab.com --> existing loopback OpenClaw Gateway :18789
                                                     --> paired Mac OpenClaw node
Mac cloudflared access tcp --> node.calla.nomonlab.com --> TCP tunnel --> existing Gateway :18789
```

The human endpoint is `https://calla.nomonlab.com`; the node endpoint is `node.calla.nomonlab.com`; `packs.calla.nomonlab.com` is reserved and is not published.

## 0. Contain the existing tunnel credential first

Do this before publishing Calla. If the `nomonlab-public` tunnel token was exposed during inspection, rotate it in **Cloudflare Dashboard → Networking → Tunnels → nomonlab-public → Rotate token**. Obtain the replacement token only through a protected operator channel, put it in a root-readable mode-`0600` file, and change that tunnel's systemd unit to use cloudflared's `--token-file`; do not put the token in `ExecStart`.

Reload systemd, restart that existing tunnel in its maintenance window, and verify its Flix and Niko Kadi routes before proceeding. This repository intentionally does not discover, adopt, or mutate `nomonlab-public`: Calla uses a new `calla-control` tunnel only. Cloudflare documents that a compromised tunnel token must be rotated and existing connector sessions disconnected. [Tunnel-token guidance](https://developers.cloudflare.com/tunnel/advanced/tunnel-tokens/)

## 1. Gateway setup

On the existing OpenClaw server from this checkout:

```bash
python3 tools/calla_openclaw_setup.py --check
make pack-build
python3 tools/calla_openclaw_setup.py --install --yes \
  --app-pack build/packs/blender.otpack
python3 tools/calla_openclaw_setup.py --status
```

`--install` backs up the active OpenClaw config under `~/.openclaw/calla/backups/`, previews a schema-validated additive patch, creates only `~/.openclaw/calla/{packs,indexes,lessons,learners,audit}`, validates again, and restarts the Gateway only if `--restart` is supplied. It preserves allowlists rather than creating one when none existed. It also adds the exact Control UI origin while retaining loopback binding and OpenClaw token authentication.

Do not set `--node-id` until `openclaw nodes pending` shows the expected Mac and an operator has manually approved it. Then rerun `--install --yes --node-id EXACT_ID`; it does not auto-approve any pairing.

To remove only Calla state created by the utility:

```bash
python3 tools/calla_openclaw_setup.py --remove --yes
```

Removal requires its install receipt and keeps non-Calla OpenClaw plugins and state intact.

## 2. Cloudflare prerequisites

Enable the Cloudflare Zero Trust organization manually (team name `nomonlab` where available). Configure Cloudflare as the identity provider with **Restrict to account members** enabled. Calla's human policy selects `cloudflare_account_member` for the owning account, so a Cloudflare account that is not a member is denied. [Cloudflare identity provider](https://developers.cloudflare.com/cloudflare-one/integrations/identity-providers/cloudflare/)

Before DNS is created, purchase/enable Advanced Certificate Manager and Total TLS, then wait until an active certificate covers `node.calla.nomonlab.com` (or the one-label wildcard `*.calla.nomonlab.com`). Universal SSL for `*.nomonlab.com` does **not** cover the deeper node hostname. [Advanced Certificate Manager](https://developers.cloudflare.com/ssl/edge-certificates/advanced-certificate-manager/)

Create a least-privilege runtime API token with only the required account/zone scopes: Cloudflare Tunnel, DNS, Access Apps and Policies, Access Identity Providers read, Access Service Tokens, and SSL Certificates read. Export it only for the provisioning command:

```bash
python3 tools/calla_cloudflare.py plan --account-id ACCOUNT_ID --zone-id ZONE_ID
CALLA_CLOUDFLARE_API_TOKEN=... sudo -E python3 tools/calla_cloudflare.py apply \
  --yes --account-id ACCOUNT_ID --zone-id ZONE_ID \
  --service-token-output /root/calla-mac-node.json --install-service
```

The plan command is dry-run only. `apply --yes` refuses to run if the restricted Cloudflare identity provider or an active nested-host certificate is absent. It creates only `calla-control`, these ingress routes, two Access applications/policies, a 90-day `calla-mac-node` service token, and matching proxied CNAMEs. It writes the tunnel token to `/etc/calla/calla-control.token` mode `0600` and the systemd service uses `cloudflared tunnel run --token-file …`.

The service-token handoff JSON is mode `0600` and includes a client ID plus secret exactly once. Move it to the Mac through an approved secure channel; never commit, email, or paste it into a terminal transcript. The service token can be rotated without changing the paired Mac node:

```bash
CALLA_CLOUDFLARE_API_TOKEN=... python3 tools/calla_cloudflare.py rotate-service-token --yes
```

Update the Mac Keychain using the new handoff immediately. Rotation invalidates the old secret for new connections. `status` is ledger-only; `destroy --yes` deletes only the resource IDs recorded in the Calla ledger, retaining the shared Cloudflare identity provider.

Cloudflare Tunnel is outbound-only. The non-HTTP node route is reached through the Mac's local `cloudflared access tcp` proxy, not by binding the Gateway publicly. [Tunnel routing](https://developers.cloudflare.com/tunnel/routing/) and [arbitrary TCP](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/cloudflared-authentication/arbitrary-tcp/).

## 3. Mac node and pairing

Run the macOS bootstrap shown in [the Mac node guide](../apps/macos/README.md). It stores the Cloudflare service token and OpenClaw token in Keychain and creates a public-configuration-only LaunchAgent. Keep the existing Tailscale Serve URL as a private recovery route.

Request pairing from the Mac, then on the Gateway inspect and approve the exact node identity:

```bash
openclaw nodes pending --json
openclaw nodes approve --node EXACT_PENDING_NODE_ID
python3 tools/calla_openclaw_setup.py --install --yes --node-id EXACT_APPROVED_NODE_ID
```

Pairing is an explicit server action. Neither the installer nor the Cloudflare service token can bypass it.

## 4. Verification matrix

Local, automated evidence:

```bash
make test
cd integrations/openclaw && npm test
python3 -m unittest discover -s tools/tests -v
```

These tests cover role separation, no gateway tools in node mode, coordinate rejection, server-local version-filtered retrieval, typed missing-TutorHost errors, idempotent pack storage, safe setup-patch ownership, and nested certificate gating.

Production evidence still needs an operator and a Mac:

1. an unauthenticated browser receives Cloudflare Access;
2. a non-member Cloudflare account is denied;
3. an authorized account reaches the Control UI and then still supplies OpenClaw authentication;
4. `node.calla.nomonlab.com` presents a valid certificate covering the hostname;
5. the Mac proxy connects with the service token and revocation prevents a new connection;
6. node pairing is manually approved;
7. the real TutorHost completes observe, point, user-requested action, and verify against Blender without core Blender knowledge.

The final item remains blocked on the native Calla/TutorHost implementation described in the Mac guide; do not treat plugin or tunnel health as proof of desktop-tutoring acceptance.
