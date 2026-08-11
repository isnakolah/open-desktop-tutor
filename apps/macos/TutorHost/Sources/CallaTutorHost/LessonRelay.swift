import AppKit
import Foundation

/// Carries what the learner pressed in the tooltip back to Calla.
///
/// The host holds no model and no credentials — deliberately, since the
/// Gateway is where the thinking belongs — so it does not answer these itself.
/// It hands them to `scripts/calla-ask.sh`, the one place that knows where a
/// question goes, which is the same path the Raycast commands take.
@MainActor
final class LessonRelay: ObservableObject {
    static let shared = LessonRelay()

    private var inFlight: Process?
    private var checking = false
    /// The one-time Tailscale approval link, when reaching Calla needs one.
    /// Detected here because the sender is the only thing that sees it, and it
    /// is useless in a log nobody is tailing.
    @Published private(set) var authorisationURL: URL?

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
            // No message to the model, and no waiting for one back. Stopping is
            // something the learner does, not something they request.
            TutorHostController.shared.stopLesson()
        default:
            break
        }
    }

    /// Begin one from the menu bar, for a learner who does not want to reach
    /// for Raycast to say "show me this".
    func startLesson() {
        TutorHostController.shared.lessonActive = true
        PointerOverlay.shared.narrate(step: "Calla", text: "Starting a lesson…",
                                      status: "Calla — starting", thinking: true)
        send("Look at my focused window and teach me what to do next.")
    }

    /// Drop whatever was in flight. A question already travelling would
    /// otherwise come back and put a step on a screen the learner has finished
    /// with.
    func clearAuthorisation() { authorisationURL = nil }

    func abort() {
        inFlight?.terminate()
        inFlight = nil
        checking = false
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
        // someone who has just finished a step and is waiting to hear. Held, so
        // the step they just finished stays on screen while they wait for the
        // verdict on it.
        PointerOverlay.shared.narrate(step: "Calla",
                                      text: checking ? "Checking your work…" : "Asking Calla…",
                                      status: checking ? "Calla — checking" : "Calla — thinking",
                                      thinking: true, holding: true)
        checking = false
        let task = Process()
        task.executableURL = sender
        task.arguments = [message]
        // The sender says "Thinking…" for the surfaces that have nothing else to
        // say it — Raycast, a shell. Here the tooltip has already said something
        // truer, and letting the generic line land a moment later replaced it.
        var environment = ProcessInfo.processInfo.environment
        environment["CALLA_QUIET"] = "1"
        task.environment = environment
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard let range = text.range(of: "https://login.tailscale.com/[^ \n]+", options: .regularExpression),
                  let url = URL(string: String(text[range])) else { return }
            Task { @MainActor in
                LessonRelay.shared.authorisationURL = url
                PointerOverlay.shared.narrate(
                    step: "Calla",
                    text: "Calla needs one Tailscale approval. Open it from the menu bar.",
                    status: "Calla — needs authorisation", thinking: false)
            }
        }
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
