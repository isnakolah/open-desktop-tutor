import Foundation

/// Whether this Mac is actually plugged into Calla's intelligence.
///
/// The host itself never talks to the Gateway — the separate node agent holds
/// that WebSocket and forwards envelopes into this host's socket. So "is it
/// connected" is not something the host can answer by introspection, and
/// without it a lesson that never starts looks identical to one nobody asked
/// for. Two independent facts answer it: what the node agent last logged about
/// its connection, and when this host last received a request from it.
@MainActor
final class BackendStatus: ObservableObject {
    enum Link: Equatable {
        case connected(gateway: String)
        case disconnected(reason: String)
        case agentNotRunning
        case unknown

        var isHealthy: Bool { if case .connected = self { return true } else { return false } }
    }

    static let shared = BackendStatus()

    @Published private(set) var link: Link = .unknown
    /// When the link stopped being healthy, so a blip can be told from a
    /// failure. "Reconnecting…" that never resolves is a lie the learner has no
    /// way to see through.
    @Published private(set) var unhealthySince: Date?

    /// Long enough that an ordinary reconnect never trips it.
    private let stuckAfter: TimeInterval = 30

    var isStuck: Bool {
        guard let unhealthySince else { return false }
        return Date().timeIntervalSince(unhealthySince) >= stuckAfter
    }
    /// When the Gateway last sent this host anything at all.
    @Published private(set) var lastRequestAt: Date?
    /// The operation in that request, so "connected but idle" is legible.
    @Published private(set) var lastOperation: String?

    private let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Calla/node-host.log")
    private var timer: Timer?

    func noteRequest(operation: String) {
        lastRequestAt = Date()
        lastOperation = operation
    }

    func startWatching() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { BackendStatus.shared.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let next = readLink()
        if next.isHealthy {
            unhealthySince = nil
        } else if unhealthySince == nil {
            unhealthySince = Date()
        }
        link = next
    }

    /// The node agent's log is the only place its connection state is visible,
    /// so read the last line that reports one. Reading the tail rather than the
    /// file keeps this cheap as the log grows.
    private func readLink() -> Link {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return .agentNotRunning }
        defer { try? handle.close() }
        let tailBytes = 16 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return .unknown
        }
        for line in text.split(separator: "\n").reversed() {
            if line.contains("gateway connected") {
                let gateway = line.split(separator: " ").last.map(String.init) ?? "the Gateway"
                return .connected(gateway: gateway)
            }
            if line.contains("gateway connect failed") {
                return .disconnected(reason: "the Gateway refused the connection")
            }
            if line.contains("gateway closed") {
                return .disconnected(reason: "the connection dropped")
            }
        }
        return .unknown
    }
}
