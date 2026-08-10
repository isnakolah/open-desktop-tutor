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
    private var checking = false

    func handle(event: String, text: String) {
        switch event {
        case "next":
            checking = true
            send("I have done that step. Check the window and tell me whether it worked — "
                 + "if it did, point me at the next step; if it did not, say what is different.")
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

        // Say which of the two it is. "Checking" and "asking" feel different to
        // someone who has just finished a step and is waiting to hear.
        PointerOverlay.shared.narrate(step: "Calla",
                                      text: checking ? "Checking your work…" : "Asking Calla…",
                                      status: checking ? "Calla — checking" : "Calla — thinking",
                                      thinking: true)
        checking = false
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
