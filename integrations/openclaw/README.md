# OpenClaw integration

The `desktop-tutor` plugin registers five high-level tools and one paired macOS node command. It never exposes raw coordinates, shell execution, CGEvent, or arbitrary Blender code.

The Gateway plugin invokes `desktop-tutor.host` on the configured paired node. The node-host handler forwards one validated newline-delimited JSON envelope to TutorHost's owner-only Unix socket.

Install it on the OpenClaw Gateway from a repository checkout:

```bash
openclaw plugins install ./integrations/openclaw
openclaw plugins enable desktop-tutor
openclaw plugins inspect desktop-tutor --runtime --json
```

Use `--link` during local plugin development. A dedicated user-owned Gateway should install from its own checkout rather than linking to a path on the Mac.

Example configuration:

```json5
{
  plugins: {
    allow: ["desktop-tutor"],
    entries: {
      "desktop-tutor": {
        enabled: true,
        config: {
          nodeId: "paired-mac-node-id",
          requireOwnerIdentity: true,
        },
      },
    },
  },
}
```

The plugin's one-shot OpenClaw approval is defense in depth. TutorHost must still show and enforce a local approval immediately before any real cursor or input mutation.

The native TutorHost socket is not implemented in Phase 0. Tool and policy registration can be inspected now, but calls routed to the Mac are expected to fail until TutorHost is running.
