import AppKit
import ApplicationServices
import Darwin
import Foundation
import SwiftUI

private let blenderBundleID = "org.blenderfoundation.blender"
private let maxFrameBytes = 64 * 1024

private struct TutorRequest: Codable, Sendable {
    let protocolVersion: Int
    let requestID: String
    let operation: String
    let sessionID: String
    let payload: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case operation
        case sessionID = "session_id"
        case payload
    }
}

private struct TutorError: Codable, Sendable { let code: String; let message: String }
private struct TutorResponse: Codable, Sendable {
    let requestID: String
    let ok: Bool
    let payload: [String: JSONValue]?
    let error: TutorError?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case ok
        case payload
        case error
    }
}

private enum JSONValue: Codable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private struct Snapshot {
    let id = UUID().uuidString
    let createdAt = Date()
    let processID: pid_t
    let windowFrame: CGRect
    let appVersion: String
}

private struct ResolvedTarget {
    let element: AXUIElement
    let frame: CGRect
    let confidence: Double
    let snapshot: Snapshot
}

struct PendingApproval {
    let id: UUID
    let summary: String
    let continuation: CheckedContinuation<Bool, Never>
}

struct TutorHostFailure: Error {
    let code: String
    let message: String
}

@MainActor
final class TutorHostController: ObservableObject {
    @Published var captureActive = true
    @Published var status = "Starting local TutorHost"
    @Published var pendingApproval: PendingApproval?

    // Shared so the app delegate can start the socket at launch and the menu
    // can observe the same instance.
    static let shared = TutorHostController()

    private let engine = AccessibilityTutorEngine()
    private var socketServer: UnixSocketServer?

    func start() async {
        guard socketServer == nil else { return }
        do {
            let server = try UnixSocketServer(path: Self.socketPath, delegate: self)
            try server.start()
            socketServer = server
            status = "Local TutorHost ready"
        } catch {
            status = "TutorHost failed: \(error.localizedDescription)"
        }
    }

    fileprivate func handle(_ request: TutorRequest) async -> TutorResponse {
        guard request.protocolVersion == 1 else { return failure(request, "unsupported_version", "Tutor protocol version 1 is required") }
        guard request.sessionID.count >= 8 else { return failure(request, "invalid_session", "A valid teaching session is required") }
        guard captureActive else { return failure(request, "capture_paused", "Capture is paused locally") }
        do {
            let payload: [String: JSONValue]
            switch request.operation {
            case "observe": payload = try engine.observe()
            case "point": payload = try engine.point(request.payload)
            case "propose_action": payload = try await proposeAction(request.payload)
            case "verify": payload = try engine.verify(request.payload)
            default: return failure(request, "unsupported_operation", "This TutorHost only accepts observe, point, propose_action, and verify")
            }
            return TutorResponse(requestID: request.requestID, ok: true, payload: payload, error: nil)
        } catch let error as TutorHostFailure {
            return failure(request, error.code, error.message)
        } catch {
            return failure(request, "host_error", error.localizedDescription)
        }
    }

    private func proposeAction(_ payload: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard case .string(let action)? = payload["action"], action == "click" else {
            throw TutorHostFailure(code: "unsupported_action", message: "The Blender 5.2 starter lesson permits only one semantic click")
        }
        let target = try engine.resolveFreshModifierTarget(payload, minimumConfidence: 0.92)
        let approved = await withCheckedContinuation { continuation in
            pendingApproval = PendingApproval(id: UUID(), summary: "Open Modifier Properties in the focused Blender window.", continuation: continuation)
        }
        guard approved else { return ["status": .string("denied"), "reason": .string("The local user denied the action")] }
        try engine.press(target)
        return try engine.verify(["snapshot_id": .string(target.snapshot.id)])
    }

    func resolveApproval(_ approved: Bool) {
        guard let pending = pendingApproval else { return }
        pendingApproval = nil
        pending.continuation.resume(returning: approved)
    }

    private func failure(_ request: TutorRequest, _ code: String, _ message: String) -> TutorResponse {
        TutorResponse(requestID: request.requestID, ok: false, payload: nil, error: TutorError(code: code, message: message))
    }

    static let socketPath = NSHomeDirectory() + "/Library/Application Support/OpenDesktopTutor/tutor-host.sock"
}

// Every call site is on the @MainActor TutorHostController, and point() drives
// an AppKit overlay, so state the isolation the code already relies on.
@MainActor
private final class AccessibilityTutorEngine {
    private var snapshots: [String: Snapshot] = [:]
    private let maxSnapshotAge: TimeInterval = 4

    func observe() throws -> [String: JSONValue] {
        let app = try focusedBlender()
        let snapshot = try makeSnapshot(for: app)
        snapshots[snapshot.id] = snapshot
        return [
            "status": .string("ok"),
            "snapshot_id": .string(snapshot.id),
            "app_bundle_id": .string(blenderBundleID),
            "app_version": .string(snapshot.appVersion),
        ]
    }

    func point(_ payload: [String: JSONValue]) throws -> [String: JSONValue] {
        let target = try resolveFreshModifierTarget(payload, minimumConfidence: 0.72)
        PointerOverlay.shared.show(at: target.frame)
        return ["status": .string("ok"), "snapshot_id": .string(target.snapshot.id), "confidence": .number(target.confidence)]
    }

    func verify(_ payload: [String: JSONValue]) throws -> [String: JSONValue] {
        let app = try focusedBlender()
        let snapshot = try makeSnapshot(for: app)
        let target = try findModifierTarget(in: app, snapshot: snapshot, minimumConfidence: 0.72)
        let selected = boolAttribute(target.element, kAXSelectedAttribute as CFString) ?? false
        return [
            "status": .string(selected ? "satisfied" : "unsatisfied"),
            "snapshot_id": .string(snapshot.id),
            "detector": .string("properties.context_is"),
            "value": .string(selected ? "MODIFIER" : "UNKNOWN"),
        ]
    }

    func resolveFreshModifierTarget(_ payload: [String: JSONValue], minimumConfidence: Double) throws -> ResolvedTarget {
        guard case .string(let semanticTarget)? = payload["semantic_target"], semanticTarget == "properties.modifiers_tab" else {
            throw TutorHostFailure(code: "unsupported_target", message: "Only properties.modifiers_tab is authored in the Blender 5.2 starter lesson")
        }
        guard case .string(let snapshotID)? = payload["snapshot_id"], let prior = snapshots[snapshotID] else {
            throw TutorHostFailure(code: "unknown_snapshot", message: "An observation receipt is required before resolving an action target")
        }
        guard Date().timeIntervalSince(prior.createdAt) <= maxSnapshotAge else {
            throw TutorHostFailure(code: "stale_snapshot", message: "The observation receipt is stale")
        }
        let app = try focusedBlender()
        let fresh = try makeSnapshot(for: app)
        guard fresh.processID == prior.processID, fresh.windowFrame.equalTo(prior.windowFrame) else {
            throw TutorHostFailure(code: "changed_window", message: "The focused Blender window changed after observation")
        }
        return try findModifierTarget(in: app, snapshot: fresh, minimumConfidence: minimumConfidence)
    }

    func press(_ target: ResolvedTarget) throws {
        guard AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success else {
            throw TutorHostFailure(code: "action_failed", message: "macOS Accessibility rejected the approved action")
        }
    }

    private func focusedBlender() throws -> AXUIElement {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == blenderBundleID else {
            throw TutorHostFailure(code: "app_not_allowed", message: "Blender must be the focused application")
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func makeSnapshot(for app: AXUIElement) throws -> Snapshot {
        var processID: pid_t = 0
        AXUIElementGetPid(app, &processID)
        guard let window = copyElementAttribute(app, kAXFocusedWindowAttribute as CFString) else {
            throw TutorHostFailure(code: "no_focused_window", message: "Blender has no focused window")
        }
        let version = NSWorkspace.shared.frontmostApplication?.bundleURL.flatMap {
            Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        } ?? "unknown"
        return Snapshot(processID: processID, windowFrame: try frameAttribute(window), appVersion: version)
    }

    private func findModifierTarget(in app: AXUIElement, snapshot: Snapshot, minimumConfidence: Double) throws -> ResolvedTarget {
        let candidates = descendants(of: app, maxDepth: 12).compactMap { element -> ResolvedTarget? in
            guard let role = stringAttribute(element, kAXRoleAttribute as CFString), [kAXRadioButtonRole as String, kAXButtonRole as String].contains(role) else { return nil }
            let label = [stringAttribute(element, kAXTitleAttribute as CFString), stringAttribute(element, kAXDescriptionAttribute as CFString), stringAttribute(element, kAXHelpAttribute as CFString)].compactMap { $0 }.joined(separator: " ").lowercased()
            guard label.contains("modifier"), let frame = try? frameAttribute(element), frame.width > 0, frame.height > 0 else { return nil }
            let confidence = label.contains("modifier properties") || label == "modifiers" ? 0.96 : 0.76
            return ResolvedTarget(element: element, frame: frame, confidence: confidence, snapshot: snapshot)
        }.sorted { $0.confidence > $1.confidence }
        guard let best = candidates.first, best.confidence >= minimumConfidence else {
            throw TutorHostFailure(code: "unresolved", message: "Modifier Properties could not be resolved with enough confidence")
        }
        guard candidates.dropFirst().first.map({ best.confidence - $0.confidence >= 0.1 }) ?? true else {
            throw TutorHostFailure(code: "ambiguous_target", message: "Modifier Properties remains ambiguous")
        }
        return best
    }
}

private func copyElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

// AXValue is a CoreFoundation type, so `as?` always succeeds and cannot be used
// to test the payload. Check the CFTypeID, then the AXValue's own type tag.
private func axValueAttribute(_ element: AXUIElement, _ attribute: CFString, _ type: AXValueType) -> AXValue? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = (value as! AXValue)
    return AXValueGetType(axValue) == type ? axValue : nil
}

private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? value as? String : nil
}

private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? (value as? NSNumber)?.boolValue : nil
}

// There is no public kAXFrameAttribute; compose the frame from the documented
// position and size attributes instead of the undocumented "AXFrame".
private func frameAttribute(_ element: AXUIElement) throws -> CGRect {
    guard let positionValue = axValueAttribute(element, kAXPositionAttribute as CFString, .cgPoint),
          let sizeValue = axValueAttribute(element, kAXSizeAttribute as CFString, .cgSize) else {
        throw TutorHostFailure(code: "missing_frame", message: "The resolved Accessibility element has no usable frame")
    }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue, .cgPoint, &origin), AXValueGetValue(sizeValue, .cgSize, &size) else {
        throw TutorHostFailure(code: "missing_frame", message: "The resolved Accessibility element has no usable frame")
    }
    return CGRect(origin: origin, size: size)
}

private func descendants(of element: AXUIElement, maxDepth: Int) -> [AXUIElement] {
    guard maxDepth > 0 else { return [] }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let children = value as? [AXUIElement] else { return [] }
    return children + children.flatMap { descendants(of: $0, maxDepth: maxDepth - 1) }
}

// AppKit windows are main-actor only, and the sole call site is the
// @MainActor TutorHostController, so isolate the overlay to the main actor.
@MainActor
private final class PointerOverlay {
    static let shared = PointerOverlay()
    private var window: NSWindow?

    func show(at frame: CGRect) {
        let size = CGSize(width: max(frame.width, 36), height: max(frame.height, 36))
        let rect = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RoundedRectangle(cornerRadius: 8).stroke(.orange, lineWidth: 4).padding(2))
        panel.orderFrontRegardless()
        window = panel
    }
}

// File-scope rather than a static method on UnixSocketServer: see acceptConnection.
private func serveConnection(client: Int32, delegate: TutorHostController?) async {
    defer { close(client) }
    do {
        let request = try UnixSocketServer.readRequest(client)
        guard let delegate else {
            try UnixSocketServer.write(TutorResponse(requestID: request.requestID, ok: false, payload: nil, error: TutorError(code: "host_stopped", message: "TutorHost is unavailable")), to: client)
            return
        }
        let response = await delegate.handle(request)
        try UnixSocketServer.write(response, to: client)
    } catch {
        let response = TutorResponse(requestID: UUID().uuidString, ok: false, payload: nil, error: TutorError(code: "protocol_error", message: error.localizedDescription))
        try? UnixSocketServer.write(response, to: client)
    }
}

private final class UnixSocketServer {
    private let path: String
    private weak var delegate: TutorHostController?
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, delegate: TutorHostController) throws {
        self.path = path
        self.delegate = delegate
    }

    deinit { stop() }

    func start() throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TutorHostFailure(code: "socket_create_failed", message: String(cString: strerror(errno))) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let byteCount = path.utf8.count + 1
        guard byteCount <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw TutorHostFailure(code: "socket_path_too_long", message: "The TutorHost socket path is too long")
        }
        _ = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                strncpy(destination, source, byteCount)
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sa_family_t>.size + byteCount))
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            close(descriptor)
            throw TutorHostFailure(code: "socket_bind_failed", message: message)
        }
        guard chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            let message = String(cString: strerror(errno))
            close(descriptor)
            throw TutorHostFailure(code: "socket_listen_failed", message: message)
        }
        fileDescriptor = descriptor
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .userInitiated))
        readSource.setEventHandler { [weak self] in self?.acceptConnection() }
        readSource.setCancelHandler { [descriptor] in close(descriptor) }
        readSource.resume()
        source = readSource
    }

    func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
        _ = unlink(path)
    }

    private func acceptConnection() {
        let client = accept(fileDescriptor, nil, nil)
        guard client >= 0 else { return }
        // serveConnection is a file-scope function, not a static method: calling a
        // static member of this non-Sendable class from inside a Task makes the
        // region-based isolation checker fail with "pattern that the region-based
        // isolation checker does not understand how to check. Please file a bug."
        let target = delegate
        Task { await serveConnection(client: client, delegate: target) }
    }

    fileprivate static func readRequest(_ descriptor: Int32) throws -> TutorRequest {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maxFrameBytes {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 { throw TutorHostFailure(code: "socket_read_failed", message: String(cString: strerror(errno))) }
            if count == 0 { break }
            data.append(buffer, count: count)
            if data.last == 10 { break }
        }
        guard data.count > 0, data.count <= maxFrameBytes, data.last == 10 else {
            throw TutorHostFailure(code: "frame_limit", message: "TutorHost requires one newline-delimited request under 64 KiB")
        }
        return try JSONDecoder().decode(TutorRequest.self, from: data)
    }

    fileprivate static func write(_ response: TutorResponse, to descriptor: Int32) throws {
        var data = try JSONEncoder().encode(response)
        data.append(10)
        guard data.count <= maxFrameBytes else { throw TutorHostFailure(code: "frame_limit", message: "TutorHost response exceeds 64 KiB") }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 { throw TutorHostFailure(code: "socket_write_failed", message: String(cString: strerror(errno))) }
                offset += count
            }
        }
    }
}
