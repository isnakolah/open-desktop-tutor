import SwiftUI

@main
struct CallaTutorHostApp: App {
    @StateObject private var host = TutorHostController()

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
