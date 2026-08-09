# Calla

Calla is a teaching-first assistant for complex desktop applications. It explains, highlights, points, lets the learner try, verifies the result, and only considers bounded input after an explicit request and a local approval.

This repository is still named `open-desktop-tutor`. The stable protocol identifiers (`desktop-tutor`, `desktop-tutor.host`, and `tutor_*`) deliberately remain unchanged for compatibility. Blender is the first App Pack, not a limit on the core architecture.

## What is implemented here

- a versioned App Pack compiler and a Blender 4.3–4.5 starter pack;
- a read-only Blender observation bridge;
- the Calla OpenClaw plugin, with separate `gateway`, `node`, and development-only `both` roles;
- server-local App Pack retrieval from `~/.openclaw/calla/`, filtered by application version;
- safety boundaries that reject raw coordinates and require owner identity plus one-shot approval for requested actions;
- Cloudflare and macOS bootstrap tooling that is dry-run/confirmation gated.

The signed `Calla.app` / `TutorHost.app`, ScreenCaptureKit resolver, overlay, local approval UI, and real input loop remain macOS implementation work. The repository does not claim an end-to-end desktop-control demonstration until those pieces run on a Mac.

## Naming and architecture

| Contract | Value |
| --- | --- |
| Calla browser endpoint | `https://calla.nomonlab.com` |
| Mac node endpoint | `node.calla.nomonlab.com` |
| Dedicated tunnel | `calla-control` |
| User-owned server state | `~/.openclaw/calla/` |
| Mac service token | `calla-mac-node` |
| Reserved, not provisioned | `packs.calla.nomonlab.com` |

```text
Browser → Cloudflare Access → calla.nomonlab.com → existing loopback OpenClaw Gateway :18789
                                                   → manually paired Mac OpenClaw node
Mac cloudflared access tcp → node.calla.nomonlab.com → TCP tunnel → Gateway :18789
```

The existing Gateway remains the only brain. It stays loopback-bound and retains OpenClaw token authentication as the second layer behind Cloudflare Access. Tailscale Serve remains a private recovery path.

## Complete setup

The deployment order below is deliberate. It keeps the existing Gateway private, avoids sharing the old public tunnel, and keeps Cloudflare credentials out of the repository.

### 0. Contain the old tunnel credential

Before publishing Calla, rotate `nomonlab-public` if its token was exposed during prior inspection. In Cloudflare Dashboard, go to **Networking → Tunnels → nomonlab-public → Rotate token**; deliver the replacement through a protected channel; store it in a root-readable mode-`0600` file; and use cloudflared's `--token-file` in the existing systemd unit rather than an inline `ExecStart` token.

Restart that existing tunnel in a maintenance window, then verify its Flix and Niko Kadi routes. Calla never discovers, adopts, or changes `nomonlab-public`; it owns only the new `calla-control` tunnel. [Cloudflare tunnel-token guidance](https://developers.cloudflare.com/tunnel/advanced/tunnel-tokens/)

### 1. Local validation and Blender App Pack

Requirements are Python 3.11+, Node.js/npm, Git, Make, and OpenClaw `>=2026.7.1-2`. macOS development additionally needs Xcode Command Line Tools; Blender 4.3–4.5 is required for the first App Pack and bridge.

```bash
./scripts/setup-macos.sh --check-only # macOS; add --allow-non-macos only for CI validation
make test pack-build blender-addon
```

For a developer Mac, the setup script's explicit Calla default is the safe `node` role—not the Gateway role. This compatibility-safe path does not configure a public proxy or secrets:

```bash
./scripts/setup-macos.sh --install-calla-node
```

`--install-openclaw-plugin` remains an alias and now selects the same node role. Use the later macOS bootstrap step for the Keychain-backed Access proxy.

On a Mac with Xcode tools:

```bash
swift test --package-path packages/swift/TutorKit
```

The bridge is read-only. Install `build/blender/open-desktop-tutor-blender-0.1.0.zip` from Blender's **Edit → Preferences → Add-ons → Install from Disk**, enable it, then run:

```bash
.venv/bin/python tools/blender_bridge_probe.py --operation ping
.venv/bin/python tools/blender_bridge_probe.py --operation observe_state
```

The descriptor contains a private session token. Never paste it, screenshots, OpenClaw configuration, Keychain data, or Cloudflare credentials into reports.

### 2. Gateway setup

Calla uses the existing user-owned OpenClaw Gateway as its only brain. It preserves existing WhatsApp, active-memory, plugins, and Tailscale configuration.

The default server setup uses the dedicated `cf-dns` Calla lifecycle. Its default is read-only; the install path builds the default Blender App Pack, installs the Gateway role, creates or validates the private `calla-control` manifest, and restarts the Gateway once. It does **not** publish Calla DNS:

```bash
./scripts/setup-calla-server.sh
./scripts/setup-calla-server.sh --install --yes
```

`make setup` is the same confirmed server install. Use `--no-restart` only when you need to choose the Gateway restart window yourself.

For manual or advanced Gateway setup, start with a read-only preflight and configuration preview:

```bash
python3 tools/calla_openclaw_setup.py --check
python3 tools/calla_openclaw_setup.py --install
```

The preview prints a schema-validated additive patch without writing configuration. After reviewing it, build and install the Blender App Pack:

```bash
make pack-build
python3 tools/calla_openclaw_setup.py --install --yes \
  --app-pack build/packs/blender.otpack
python3 tools/calla_openclaw_setup.py --status
```

The installer backs up the current config under `~/.openclaw/calla/backups/`, preserves a pre-existing plugin allowlist, adds only the Calla Control UI origin, creates owner-only Calla state, validates before completion, and restarts only if `--restart` is explicitly added. It writes a receipt, so this removes only installer-owned state:

```bash
python3 tools/calla_openclaw_setup.py --remove --yes
```

| Role | Runs on | Registers |
| --- | --- | --- |
| `gateway` | Existing Gateway server | `tutor_*` tools, policy, paired-node invocation, server-local retrieval |
| `node` | Paired Mac node | Only `desktop-tutor.host`, forwarding validated envelopes to TutorHost |
| `both` | Development only | Both surfaces, only with `developmentMode: true` |

`tutor_retrieve` runs at the Gateway and reads `~/.openclaw/calla/indexes/`, filtering by application bundle ID and version. It does not round-trip to the Mac. Until the real socket host exists, node commands return `TUTOR_HOST_UNAVAILABLE`.

### 3. Cloudflare prerequisites and provisioning

Enable the Cloudflare Zero Trust organization manually, using `nomonlab` as the team name where available. Configure Cloudflare as the identity provider with **Restrict to account members** enabled. The human Access policy uses the owning account's `cloudflare_account_member`, denying non-members. [Cloudflare identity-provider instructions](https://developers.cloudflare.com/cloudflare-one/integrations/identity-providers/cloudflare/)

Before any Calla DNS record is created, purchase/enable Advanced Certificate Manager and Total TLS. Wait for an active certificate that covers `node.calla.nomonlab.com` or `*.calla.nomonlab.com`; `*.nomonlab.com` does not cover the nested endpoint. [Advanced Certificate Manager](https://developers.cloudflare.com/ssl/edge-certificates/advanced-certificate-manager/)

#### `cf-dns` tunnel and DNS lifecycle

On this server, use the dedicated private `calla-control.toml` manifest with `cf-dns`; never adopt, edit, or reuse `nomonlab-public`. The desired Calla origins are deliberately loopback-only:

```toml
[hosts]
"calla" = "http://127.0.0.1:18789"
"node.calla" = "tcp://127.0.0.1:18789"
```

Run the read-only checks first. They prove the target-zone account, tunnel and DNS permissions, local origin reachability, and that no existing Calla CNAME will be overwritten:

```bash
cd /srv/app/cloudflare-dns
cf-dns --manifest calla-control.toml doctor
cf-dns --manifest calla-control.toml plan
```

Only after Zero Trust Access is enabled, the account-member identity policy and node Service Auth policy exist, and the nested certificate is active, publish the two managed CNAMEs:

```bash
cf-dns --manifest calla-control.toml reconcile
cf-dns --manifest calla-control.toml published
```

`cf-dns` installs only `cf-dns-calla-control-tunnel.service`; its Cloudflare tunnel token is held in a root-owned `0600` environment file, never in the unit command, manifest, or repository. It keeps the tunnel up with a terminal 404 rule while the CNAMEs are absent. Remove only Calla resources with `cf-dns --manifest calla-control.toml destroy --yes`.

Do not mix this lifecycle with `calla_cloudflare.py apply` for the same `calla-control` tunnel: both tools manage tunnel configuration and DNS. With `cf-dns` as the tunnel/DNS owner, create the two Access applications, policies, and the 90-day `calla-mac-node` service token in the Zero Trust dashboard. The human application is `calla.nomonlab.com`, uses the Cloudflare account-member identity provider and an eight-hour session; the node application is `node.calla.nomonlab.com` and has only a Service Auth policy for that token. Store the resulting client ID and secret only in the Mac Keychain during bootstrap.

#### Repository-owned provisioning alternative

If you do not use `cf-dns`, the repository provisioner is an all-in-one lifecycle owner. It must be the only tool that creates the Calla tunnel and DNS records:

Create a least-privilege Cloudflare API token with only Cloudflare Tunnel, DNS, Access Apps and Policies, Access Identity Providers read, Access Service Tokens, and SSL Certificates read. Keep it runtime-only:

```bash
python3 tools/calla_cloudflare.py plan --account-id ACCOUNT_ID --zone-id ZONE_ID

CALLA_CLOUDFLARE_API_TOKEN=... sudo -E python3 tools/calla_cloudflare.py apply \
  --yes --account-id ACCOUNT_ID --zone-id ZONE_ID \
  --service-token-output /root/calla-mac-node.json --install-service
```

`plan` does not mutate Cloudflare. `apply --yes` refuses to proceed before the restricted identity provider and valid nested certificate exist. It creates only `calla-control`, the two ingress routes, two Access applications/policies, a 90-day `calla-mac-node` service token, Calla CNAME records, and an optional systemd unit which reads `/etc/calla/calla-control.token` using `--token-file`.

The one-time Mac handoff JSON is mode `0600` and contains a Cloudflare client ID plus secret. Transfer it through an approved secure channel only: never source control, shell history, email, or a screenshot. Rotate it without changing OpenClaw pairing:

```bash
CALLA_CLOUDFLARE_API_TOKEN=... python3 tools/calla_cloudflare.py rotate-service-token --yes
```

Update the Mac Keychain immediately after rotation. `status` is ledger-only; `destroy --yes` removes only resources stored in Calla's ledger and retains the shared identity provider. [Tunnel routing](https://developers.cloudflare.com/tunnel/routing/) and [Access TCP proxy](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/cloudflared-authentication/arbitrary-tcp/)

### 4. Mac node and explicit pairing

Securely transfer the current service-token handoff to the Mac, then run:

```bash
./scripts/bootstrap-calla-mac.sh --check
./scripts/bootstrap-calla-mac.sh --install --yes
```

The installer prompts for the Cloudflare service-token ID/secret and separate OpenClaw Gateway token. It stores all three in the login Keychain, configures the plugin in `node` mode, and creates `com.calla.openclaw-access-proxy` as a user LaunchAgent.

The plist contains only public hostname/listener values. The proxy reads Cloudflare secrets from Keychain immediately before running:

```text
cloudflared access tcp --hostname node.calla.nomonlab.com --url 127.0.0.1:18790
```

The Mac OpenClaw node connects to `ws://127.0.0.1:18790`. Neither the plist, logs, nor cloudflared command arguments contain credentials. The future signed Calla app reads its Gateway token from Keychain; that native app is not generated by this Linux-hosted repository.

Request pairing from the Mac, then inspect and approve the exact pending identity from the server:

```bash
openclaw nodes pending --json
openclaw nodes approve --node EXACT_PENDING_NODE_ID
python3 tools/calla_openclaw_setup.py --install --yes --node-id EXACT_APPROVED_NODE_ID
```

No installer auto-approves a node, and a Cloudflare service token cannot bypass pairing. To remove only Mac-side Calla Keychain entries and its LaunchAgent:

```bash
./scripts/bootstrap-calla-mac.sh --remove --yes
```

### 5. Safety, verification, and troubleshooting

There is intentionally no `click(x,y)`, shell, CGEvent, arbitrary Blender code, or arbitrary app scripting tool in the brain protocol. Semantic targets are mandatory. The brain can suggest a teaching move, but the Mac host must resolve targets and make the final authorization decision.

- Calls fail closed without host-verified owner identity; coordinate-shaped fields are recursively rejected.
- System mutation needs a fresh semantic receipt, exact window identity, authored expected state, confidence, and local one-shot approval.
- Password fields, authentication, purchases, messages, destructive operations, external submissions, and terminal/code execution prohibit mutations and demonstrations.
- Screenshot persistence is disabled by default.

Run every Linux-verifiable check:

```bash
make test
./scripts/setup-calla-server.sh --check
```

The tests cover role isolation, coordinate rejection, server-local version-filtered retrieval, typed missing-TutorHost errors, App Pack storage, installer idempotence/removal ownership, and nested certificate gating.

Production acceptance still needs an operator and a permissioned Mac:

1. an unauthenticated browser receives Cloudflare Access;
2. a non-member Cloudflare account is denied;
3. an authorized user reaches the Control UI, then still completes OpenClaw authentication;
4. the node endpoint presents a valid nested certificate;
5. the Mac proxy accepts the service token and revocation blocks new connections;
6. pairing requires exact manual approval;
7. the real TutorHost completes observe, point, requested action, and verify for a Blender lesson.

Do not treat passing plugin, tunnel, or installer checks as evidence of the final macOS tutoring path. It remains blocked until the native Calla/TutorHost app is built and verified on macOS.

## Command reference

```text
tools/calla_openclaw_setup.py --check | --install [--yes] | --status | --remove --yes
scripts/setup-calla-server.sh --check | --install --yes | --status
tools/calla_cloudflare.py plan | apply --yes | status | rotate-service-token --yes | destroy --yes
scripts/bootstrap-calla-mac.sh --check | --install --yes | --remove --yes
tools/calla_pack_store.py COMPILED.otpack --state-directory ~/.openclaw/calla
```

Use `--help` on each command for optional paths and operational flags. See [SECURITY.md](SECURITY.md), [the architecture notes](docs/architecture/phase-0.md), and the legacy [deployment-guide link](docs/calla.md).
