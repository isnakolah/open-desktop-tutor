import AppKit
import SwiftUI

/// The menu bar panel.
///
/// It answers one question first — can Calla teach right now, and what — and
/// only then offers the controls. The earlier version showed six equal sections
/// with a paragraph under each, so the state that mattered was buried in
/// explanation. Everything that is working stays quiet; only what is broken
/// speaks up, and it comes with the button that fixes it.
struct CallaMenu: View {
    @ObservedObject var host: TutorHostController
    @ObservedObject var settings: TutorSettings
    @ObservedObject var backend: BackendStatus
    @ObservedObject var subject: LessonSubject

    @State private var showingOptions = false

    /// Everything that has to be true before a lesson can start, in the order
    /// the owner should fix them.
    private enum Readiness {
        case paused
        case needsScreenRecording
        case disconnected(String)
        case noApplications
        case ready(String)
    }

    private var readiness: Readiness {
        if !host.captureActive { return .paused }
        if !settings.screenRecordingGranted { return .needsScreenRecording }
        if case .connected = backend.link {} else {
            return .disconnected(CallaMenu.linkSummary(backend.link))
        }
        if settings.allowedBundleIDs.isEmpty { return .noApplications }
        return .ready(subject.lastSubjectName ?? settings.displayName(for: settings.allowedBundleIDs[0]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // Sized by its content rather than scrolled: a MenuBarExtra window
            // gives its content no height to resolve against, so a flexible
            // ScrollView collapses to nothing and the panel becomes a header
            // and a footer with a gap between them.
            VStack(alignment: .leading, spacing: 14) {
                if let approval = host.pendingApproval { approvalCard(approval) }
                problemCard
                applications
                options
            }
            .padding(14)
            Divider()
            footer
        }
        .frame(width: 340)
        .task {
            await host.start()
            await settings.refreshScreenRecordingStatus()
            backend.startWatching()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: CallaMark.image(edge: 22))
                .renderingMode(.template)
                .foregroundStyle(statusTint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Calla").font(.system(size: 13, weight: .semibold))
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if case .ready = readiness {
                Button("Find it") { PointerOverlay.shared.locate() }
                    .controlSize(.small)
                    .help("Flash Calla's pointer and tooltip where they are")
            }
            Circle().fill(statusTint).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var statusLine: String {
        switch readiness {
        case .paused: return "Paused"
        case .needsScreenRecording: return "Needs permission to see the screen"
        case .disconnected(let why): return why
        case .noApplications: return "No application allowed yet"
        case .ready(let app): return "Ready · teaching \(app)"
        }
    }

    private var statusTint: Color {
        switch readiness {
        case .ready: return .green
        case .paused: return .secondary
        default: return .orange
        }
    }

    private static func linkSummary(_ link: BackendStatus.Link) -> String {
        switch link {
        case .connected: return "Connected"
        case .disconnected: return "Reconnecting to Calla…"
        case .agentNotRunning: return "Calla's node agent is not running"
        case .unknown: return "Not connected yet"
        }
    }

    // MARK: - The one thing that is wrong

    @ViewBuilder private var problemCard: some View {
        switch readiness {
        case .needsScreenRecording:
            card(icon: "eye.trianglebadge.exclamationmark",
                 title: "Let Calla see the screen",
                 detail: "It reads one window at a time, only the app you allow.",
                 action: ("Open Settings", { settings.openScreenRecordingSettings() }))
        case .disconnected(let why):
            card(icon: "antenna.radiowaves.left.and.right.slash",
                 title: why,
                 detail: "Calla retries on its own.",
                 action: ("Logs", { settings.openLogs() }))
        case .noApplications:
            card(icon: "square.dashed",
                 title: "Allow an application",
                 detail: "Calla can only look at applications you list below.",
                 action: nil)
        case .paused, .ready:
            EmptyView()
        }
    }

    private func card(icon: String, title: String, detail: String,
                      action: (String, () -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.orange).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let action {
                Button(action.0, action: action.1).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.orange.opacity(0.10)))
    }

    private func approvalCard(_ approval: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow one action?").font(.system(size: 12, weight: .semibold))
            Text(approval.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Deny") { host.resolveApproval(false) }.controlSize(.small)
                Button("Allow once") { host.resolveApproval(true) }
                    .controlSize(.small).keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accentColor.opacity(0.12)))
    }

    // MARK: - Applications

    private var applications: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Calla may look at")
            ForEach(settings.allowedBundleIDs, id: \.self) { bundleID in
                HStack(spacing: 8) {
                    appIcon(bundleID)
                    Text(settings.displayName(for: bundleID)).font(.system(size: 12))
                    Spacer()
                    Button {
                        settings.disallow(bundleID: bundleID)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop Calla looking at \(settings.displayName(for: bundleID))")
                }
                .padding(.vertical, 2)
            }
            if let candidate = settings.frontmostCandidate(),
               !settings.allowedBundleIDs.contains(candidate.bundleID) {
                Button {
                    settings.allow(bundleID: candidate.bundleID)
                } label: {
                    Label("Allow \(candidate.name)", systemImage: "plus.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            }
        }
    }

    private func appIcon(_ bundleID: String) -> some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed").foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Options, folded away

    private var options: some View {
        DisclosureGroup(isExpanded: $showingOptions) {
            VStack(alignment: .leading, spacing: 10) {
                labelled("Detail Calla sees") {
                    Picker("", selection: $settings.captureLongEdge) {
                        ForEach(TutorSettings.captureLongEdgeChoices, id: \.self) { edge in
                            Text(CallaMenu.captureLabel(edge)).tag(edge)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                labelled("Pointer") {
                    Picker("", selection: $settings.cursorSize) {
                        ForEach(TutorSettings.cursorSizeChoices, id: \.self) { size in
                            Text(CallaMenu.cursorLabel(size)).tag(size)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                Toggle("Hide the tooltip when I hover it", isOn: $settings.hideTooltipOnHover)
                    .font(.system(size: 12))
                Toggle("Only over the app being taught", isOn: $settings.overlayFollowsFocus)
                    .font(.system(size: 12))
                Toggle("Status capsule", isOn: $settings.showStatusHUD)
                    .font(.system(size: 12))
                HStack {
                    Button("Reset") { settings.resetToDefaults() }.controlSize(.small)
                    Button("Logs") { settings.openLogs() }.controlSize(.small)
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(.top, 8)
        } label: {
            sectionTitle("Options")
        }
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            content()
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .kerning(0.4)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Toggle(isOn: $host.captureActive) {
                Text(host.captureActive ? "Teaching on" : "Paused").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private static func captureLabel(_ edge: Int) -> String {
        switch edge {
        case 1024: return "Less"
        case 2048: return "More"
        default: return "Standard"
        }
    }

    private static func cursorLabel(_ size: Int) -> String {
        switch size {
        case 24: return "Small"
        case 38: return "Large"
        default: return "Medium"
        }
    }
}
