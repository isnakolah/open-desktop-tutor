# Phase 0 architecture

## Product invariant

Open Desktop Tutor teaches before it acts. The reasoning brain may be local or on infrastructure owned by the user, but only the Mac host can authorize capture, resolve current UI targets, approve consequential actions, dispatch input, and verify results.

## Current component map

```text
User-owned OpenClaw Gateway (Calla gateway role)
  desktop-tutor plugin
    tutor_observe / tutor_retrieve / tutor_point / tutor_propose_action / tutor_verify
    no user-identity gate + one-shot action approval
    server-local App Pack retrieval: ~/.openclaw/calla/{packs,indexes}
                 │
                 │ private-tailnet paired-node invocation
                 ▼
OpenClaw node host on the user's Mac (Calla node role)
  desktop-tutor.host
                 │
                 │ owner-only newline-delimited JSON over Unix socket
                 ▼
CallaTutorHost.app
  request validation
  focused-Blender allowlist
  Accessibility semantic target resolver
  local highlight
  local one-shot approval
  Accessibility press / verify adapter
                 │
                 ├── macOS Accessibility
                 └── optional read-only Blender Tutor Bridge
                         ping / observe_state only
```

## Authority boundaries

### Brain

The brain may select a teaching move and request a semantic operation. It cannot issue executable screen coordinates, CGEvents, shell commands, or arbitrary Blender Python. Screen pixels and retrieved documentation are untrusted input.

### OpenClaw plugin

The plugin exposes only high-level tutor tools. The private single-user setup
does not require an OpenClaw owner identity, rejects coordinate-shaped
parameters recursively, and asks for an allow-once/deny decision for
`tutor_propose_action`.

This approval is defense in depth, not final authorization.

### Mac TutorHost

TutorHost is the non-delegable trust boundary. It will:

1. require focused Blender and the authored Modifier Properties target;
2. obtain a fresh observation receipt;
3. resolve the semantic target through macOS Accessibility;
4. require operation-specific confidence;
5. show a local highlight and collect local approval;
6. revalidate snapshot/window identity immediately before dispatch;
7. dispatch only the approved Accessibility press; and
8. observe fresh state and return `satisfied` or `unsatisfied`.

### Blender bridge

The Blender add-on is deliberately narrower than general Blender MCP servers. It binds to loopback, generates a per-launch token, writes the descriptor with owner-only permissions, executes reads on Blender's main thread, limits request/response sizes, and supports only `ping` and `observe_state`.

## App Pack build

Source packs use YAML and Markdown with YAML front matter. `packctl` validates:

- manifest and entity JSON Schemas;
- globally unique stable IDs;
- source/provenance references;
- lesson target, detector, and concept references;
- absence of raw action coordinates.

Compilation creates a deterministic-entry `.otpack` ZIP containing:

- `manifest.json`;
- `entities.json`;
- `index.sqlite3`, an FTS5 retrieval index.

Vector search is intentionally deferred until lexical retrieval fails measurable tests.

## What is verified on this Linux host

- Blender App Pack validation, compilation, and FTS retrieval;
- rejection of duplicate IDs, unknown semantic references, and raw coordinates;
- Blender read-only observation contract, token denial, arbitrary-operation denial, loopback server, owner-only descriptor, and main-thread scheduling behavior using a fake Blender runtime;
- OpenClaw plugin registration, semantic envelope routing, approval contract, raw-coordinate denial, and Unix-socket transport;
- live isolated OpenClaw runtime inspection of all five tools and the typed `before_tool_call` hook.

## What requires macOS

- `swift test` for TutorKit;
- Accessibility onboarding;
- a real approved click followed by stable verification in Blender 5.2;
- Xcode signing, entitlements, packaging, and notarization decisions.
