# TutorHost macOS application

This directory will contain the SwiftUI menu/side-panel shell and AppKit overlay/permission host.

Phase 0 integration order:

1. add `TutorKit` as a local Swift package;
2. wrap pinned Peekaboo observation/highlight/verification out of process;
3. expose an owner-only Unix socket at `~/Library/Application Support/OpenDesktopTutor/tutor-host.sock`;
4. validate every request against the v1 protocol schemas;
5. evaluate `TutorCore.ActionPolicy` locally;
6. render AI pointer/highlight without system input;
7. add system cursor/click only after exact target identity and local one-shot approval.

The Xcode app target is intentionally not generated on this Linux host. It should be created and signed on the macOS development machine after the Swift package passes `swift test` there.

On that Mac, begin with the root guided setup:

```bash
./scripts/setup-macos.sh --check-only
./scripts/setup-macos.sh
```

This tests `TutorKit` when Swift is available and prepares the App Pack and Blender bridge independently. It does not grant Screen Recording or Accessibility permissions; those permissions should wait for a signed TutorHost implementation with an in-app explanation and allowlist.
