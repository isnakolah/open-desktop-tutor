import AppKit
import ApplicationServices
import SwiftUI

@main
struct CallaTutorHostApp: App {
    @StateObject private var host = TutorHostController.shared
    @StateObject private var settings = TutorSettings.shared
    @NSApplicationDelegateAdaptor(CallaAppDelegate.self) private var appDelegate

    /// Green ready · blue teaching · orange needs something · grey paused.
    private var statusTint: NSColor {
        if !host.captureActive { return .secondaryLabelColor }
        if !settings.screenRecordingGranted { return .systemOrange }
        if case .connected = BackendStatus.shared.link {} else { return .systemOrange }
        if settings.allowedBundleIDs.isEmpty { return .systemOrange }
        return host.lessonActive ? .systemBlue : .systemGreen
    }

    var body: some Scene {
        MenuBarExtra {
            CallaMenu(host: host, settings: settings,
                      backend: BackendStatus.shared, subject: LessonSubject.shared,
                      relay: LessonRelay.shared)
        } label: {
            // The mark carries the status in its colour, so the menu bar answers
            // "is Calla all right" without being opened.
            Image(nsImage: CallaMark.image(edge: 16, tint: statusTint))
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
