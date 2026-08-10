import AppKit
import ApplicationServices
import SwiftUI

@main
struct CallaTutorHostApp: App {
    @StateObject private var host = TutorHostController.shared
    @StateObject private var settings = TutorSettings.shared
    @NSApplicationDelegateAdaptor(CallaAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            CallaMenu(host: host, settings: settings, backend: BackendStatus.shared)
        } label: {
            // Calla's own mark rather than a system glyph, dimmed while teaching
            // is paused so the menu bar says which state it is in.
            Image(nsImage: CallaMark.menuBar)
                .opacity(host.captureActive ? 1 : 0.4)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu is the only place this Mac's owner can see or change what Calla is
/// allowed to do, so everything that used to be a constant in the source is
/// here: which applications may be observed, how much detail leaves the
/// machine, and whether the pointer gets out of the way.
struct CallaMenu: View {
    @ObservedObject var host: TutorHostController
    @ObservedObject var settings: TutorSettings
    @ObservedObject var backend: BackendStatus

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let approval = host.pendingApproval { approvalRequest(approval) }
                Divider()
                connection
                Divider()
                permission
                Divider()
                applications
                Divider()
                capture
                Divider()
                overlay
                Divider()
                HStack {
                    Toggle("Teaching enabled", isOn: $host.captureActive)
                    Spacer()
                    Button("Reset") { settings.resetToDefaults() }
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }
            }
            .padding(14)
        }
        // A definite height, not a maximum: a MenuBarExtra window gives its
        // content no height to resolve against, so a flexible ScrollView
        // collapses to nothing.
        .frame(width: 380, height: 560)
        .task {
            await host.start()
            await settings.refreshScreenRecordingStatus()
            backend.startWatching()
        }
    }

    /// Whether this Mac is actually reachable by Calla's intelligence. Without
    /// it, a lesson that never starts and a lesson nobody asked for look the
    /// same from here.
    private var connection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(backend.link.isHealthy ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.connectionTitle(backend.link)).font(.subheadline.weight(.medium))
                    Text(Self.connectionDetail(backend.link))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Logs") { settings.openLogs() }.font(.caption)
            }
            Text(Self.activity(backend.lastRequestAt, backend.lastOperation))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func connectionTitle(_ link: BackendStatus.Link) -> String {
        switch link {
        case .connected: return "Connected to Calla"
        case .disconnected: return "Not connected to Calla"
        case .agentNotRunning: return "Calla's node agent is not running"
        case .unknown: return "Connection state unknown"
        }
    }

    private static func connectionDetail(_ link: BackendStatus.Link) -> String {
        switch link {
        case .connected(let gateway): return gateway
        case .disconnected(let reason): return "\(reason). It retries on its own."
        case .agentNotRunning: return "Run scripts/bootstrap-calla-mac.sh --install --yes."
        case .unknown: return "No connection has been logged yet."
        }
    }

    private static func activity(_ at: Date?, _ operation: String?) -> String {
        guard let at else { return "Calla has not sent this Mac anything yet." }
        let seconds = Int(Date().timeIntervalSince(at))
        let ago = seconds < 60 ? "\(max(seconds, 1))s ago"
            : seconds < 3600 ? "\(seconds / 60)m ago" : "\(seconds / 3600)h ago"
        return "Last request: \(operation ?? "unknown") · \(ago)"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(host.status).font(.headline)
            Text("Screen capture, window geometry, approval, and every action stay on this Mac. Calla never receives screen coordinates.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func approvalRequest(_ approval: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Approve one action?").font(.headline)
            Text(approval.summary).font(.caption)
            HStack {
                Button("Deny") { host.resolveApproval(false) }
                Button("Allow once") { host.resolveApproval(true) }.keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Screen Recording is the whole permission story for the screenshot path,
    /// so its state belongs in front of the user rather than in a failed tool
    /// call the model sees and the user does not.
    private var permission: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: settings.screenRecordingGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(settings.screenRecordingGranted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Recording").font(.subheadline.weight(.medium))
                Text(settings.screenRecordingGranted
                     ? "Calla can capture the focused window."
                     : "Without this Calla cannot see the screen and cannot teach.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !settings.screenRecordingGranted {
                Button("Open…") { settings.openScreenRecordingSettings() }
            }
        }
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Applications Calla may look at").font(.subheadline.weight(.medium))
            Text("A lesson can narrow this list. It can never add to it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if settings.allowedBundleIDs.isEmpty {
                Text("None — Calla cannot observe anything.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(settings.allowedBundleIDs, id: \.self) { bundleID in
                HStack {
                    Text(settings.displayName(for: bundleID)).font(.callout)
                    Spacer()
                    Button {
                        settings.disallow(bundleID: bundleID)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(bundleID)
                }
            }
            if let candidate = settings.frontmostCandidate(),
               !settings.allowedBundleIDs.contains(candidate.bundleID) {
                Button("Allow \(candidate.name)") { settings.allow(bundleID: candidate.bundleID) }
                    .font(.caption)
            }
        }
    }

    private var capture: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Capture detail", selection: $settings.captureLongEdge) {
                ForEach(TutorSettings.captureLongEdgeChoices, id: \.self) { edge in
                    Text(Self.captureLabel(edge)).tag(edge)
                }
            }
            .pickerStyle(.segmented)
            Text("How large the window image sent for a lesson is. Less detail keeps more of your screen unreadable off this Mac; more detail helps Calla read small labels.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Pointer size", selection: $settings.cursorSize) {
                ForEach(TutorSettings.cursorSizeChoices, id: \.self) { size in
                    Text(Self.cursorLabel(size)).tag(size)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Fade the pointer near mine", isOn: $settings.dimNearPointer)
            Toggle("Show the status capsule", isOn: $settings.showStatusHUD)
            Text("Calla's pointer and tooltip only ever appear over the application being taught, and never take a click.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func cursorLabel(_ size: Int) -> String {
        switch size {
        case 24: return "Small"
        case 38: return "Large"
        default: return "Medium"
        }
    }

    private static func captureLabel(_ edge: Int) -> String {
        switch edge {
        case 1024: return "Less"
        case 2048: return "More"
        default: return "Standard"
        }
    }
}

// MenuBarExtra only builds its content when the menu is opened, so a `.task`
// there would delay the socket until a human clicked the icon. Start at launch.
final class CallaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Started before any lesson: the application a lesson is about has to be
        // known from the moment the learner uses it, not from the moment they
        // get around to asking.
        LessonSubject.shared.startWatching {
            MainActor.assumeIsolated { Set(TutorSettings.shared.allowedBundleIDs) }
        }
        Task {
            await TutorHostController.shared.start()
            await TutorSettings.shared.refreshScreenRecordingStatus()
        }
    }
}
