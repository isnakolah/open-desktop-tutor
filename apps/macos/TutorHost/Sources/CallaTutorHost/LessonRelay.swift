import AppKit
import Foundation

/// Carries what the learner pressed in the tooltip back to Calla.
///
/// The host holds no model and no credentials — deliberately, since the
/// Gateway is where the thinking belongs — so it does not answer these itself.
/// It hands them to `scripts/calla-ask.sh`, the one place that knows where a
/// question goes, which is the same path the Raycast commands take.
@MainActor
final class LessonRelay {
    static let shared = LessonRelay()

    private var inFlight: Process?

    func handle(event: String, text: String) {
        switch event {
        case "next":
            send("I did that. Look at the window again and point me at the next step.")
        case "ask":
            guard !text.isEmpty else { return }
            send(text)
        case "stop":
            PointerOverlay.shared.hide()
            send("Stop the lesson here. I will ask again when I want to carry on.")
        default:
            break
        }
    }

    private func send(_ message: String) {
        guard let sender = Self.senderURL() else {
            PointerOverlay.shared.narrate(
                step: "Calla",
                text: "I could not find calla-ask.sh, so that did not reach Calla.",
                status: "Calla — not sent",
                thinking: false)
            return
        }
        // One at a time: a second question while the first is still travelling
        // would interleave two turns in the same lesson.
        if inFlight?.isRunning == true { return }

        PointerOverlay.shared.narrate(step: "Calla", text: "Asking Calla…",
                                      status: "Calla — thinking", thinking: true)
        let task = Process()
        task.executableURL = sender
        task.arguments = [message]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            inFlight = task
        } catch {
            PointerOverlay.shared.narrate(step: "Calla", text: "That did not reach Calla.",
                                          status: "Calla — not sent", thinking: false)
        }
    }

    /// Beside the installed bundle, or in the checkout that built it.
    private static func senderURL() -> URL? {
        var candidates = [URL]()
        if let resource = Bundle.main.url(forResource: "calla-ask", withExtension: "sh") {
            candidates.append(resource)
        }
        // A development build runs straight out of the package directory.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(directory.appendingPathComponent("scripts/calla-ask.sh"))
            directory = directory.deletingLastPathComponent()
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
