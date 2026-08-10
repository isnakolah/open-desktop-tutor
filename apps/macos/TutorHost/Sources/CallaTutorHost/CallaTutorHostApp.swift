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
            CallaMenu(host: host, settings: settings,
                      backend: BackendStatus.shared, subject: LessonSubject.shared)
        } label: {
            // Calla's own mark rather than a system glyph, dimmed while teaching
            // is paused so the menu bar says which state it is in.
            Image(nsImage: CallaMark.menuBar)
                .opacity(host.captureActive ? 1 : 0.4)
        }
        .menuBarExtraStyle(.window)
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
