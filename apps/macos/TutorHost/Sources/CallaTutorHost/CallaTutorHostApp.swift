import AppKit
import ApplicationServices
import SwiftUI

@main
struct CallaTutorHostApp: App {
    @StateObject private var host = TutorHostController.shared
    @StateObject private var settings = TutorSettings.shared
    @NSApplicationDelegateAdaptor(CallaAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Calla Tutor", systemImage: host.captureActive ? "eye.circle.fill" : "eye.slash") {
            CallaMenu(host: host, settings: settings)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let approval = host.pendingApproval { approvalRequest(approval) }
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
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 360)
        .task {
            await host.start()
            await settings.refreshScreenRecordingStatus()
        }
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
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Fade the pointer near mine", isOn: $settings.dimNearPointer)
            Text("Calla's pointer and tooltip only ever appear over the application being taught, and never take a click.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        Task {
            await TutorHostController.shared.start()
            await TutorSettings.shared.refreshScreenRecordingStatus()
        }
    }
}
