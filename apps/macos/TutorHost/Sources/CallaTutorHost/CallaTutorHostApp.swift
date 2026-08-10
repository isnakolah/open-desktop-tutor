import AppKit
import ApplicationServices
import SwiftUI

@main
struct CallaTutorHostApp: App {
    @StateObject private var host = TutorHostController.shared
    @NSApplicationDelegateAdaptor(CallaAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Calla Tutor", systemImage: host.captureActive ? "eye.circle.fill" : "eye.slash") {
            VStack(alignment: .leading, spacing: 10) {
                Text(host.status).font(.headline)
                Text("Capture, target resolution, approval, and actions stay on this Mac. Calla never receives screen coordinates.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if let approval = host.pendingApproval {
                    Divider()
                    Text("Approve one action?").font(.headline)
                    Text(approval.summary).font(.caption)
                    HStack {
                        Button("Deny") { host.resolveApproval(false) }
                        Button("Allow once") { host.resolveApproval(true) }.keyboardShortcut(.defaultAction)
                    }
                }
                Divider()
                Toggle("Capture active", isOn: $host.captureActive)
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding()
            .frame(width: 340)
            .task { await host.start() }
        }
    }
}

// MenuBarExtra only builds its content when the menu is opened, so a `.task`
// there would delay the socket until a human clicked the icon. Start at launch.
final class CallaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Resolving targets and verifying lesson steps both read the
        // Accessibility tree, so ask for the grant on first launch.
        // kAXTrustedCheckOptionPrompt is an imported `var`, which Swift 6 treats
        // as shared mutable state; its value is the documented constant string.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        FileHandle.standardError.write("accessibility trusted: \(trusted)\n".data(using: .utf8)!)
        Task { await TutorHostController.shared.start() }
    }
}
