import AppKit
import ApplicationServices
import Darwin
import Foundation
import SwiftUI

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

enum JSONValue: Codable, Sendable {
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
    /// Which providers corroborated this target, per resolved-target.schema.json.
    let evidence: [String]
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
            case "observe": payload = try engine.observe(request.payload)
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
            throw TutorHostFailure(code: "unsupported_action", message: "This TutorHost dispatches only one semantic click")
        }
        guard let descriptor = TargetDescriptor(payload: payload) else {
            throw TutorHostFailure(code: "unsupported_target", message: "An authored target descriptor is required to propose an action")
        }
        // A vision hint can never authorise a mutation; actions demand the
        // pack's `act` threshold, met by locally corroborated evidence only.
        let target = try engine.resolveFreshTarget(payload, descriptor: descriptor,
                                                   minimumConfidence: descriptor.confidence.act)
        var summary = "Act on \(descriptor.semanticID) in the focused window."
        if case .string(let rationale)? = payload["rationale"] { summary = rationale }
        let approved = await withCheckedContinuation { continuation in
            pendingApproval = PendingApproval(id: UUID(), summary: summary, continuation: continuation)
        }
        guard approved else { return ["status": .string("denied"), "reason": .string("The local user denied the action")] }
        try engine.press(target)
        var verifyPayload = payload
        verifyPayload["snapshot_id"] = .string(target.snapshot.id)
        return try engine.verify(verifyPayload)
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

    func observe(_ payload: [String: JSONValue]) throws -> [String: JSONValue] {
        let (app, runningApp) = try focusedAllowedApp(allowlist: Self.allowlist(from: payload))
        let snapshot = try makeSnapshot(for: app)
        snapshots[snapshot.id] = snapshot
        return [
            "status": .string("ok"),
            "snapshot_id": .string(snapshot.id),
            "app_bundle_id": .string(runningApp.bundleIdentifier ?? "unknown"),
            "app_version": .string(snapshot.appVersion),
        ]
    }

    func point(_ payload: [String: JSONValue]) throws -> [String: JSONValue] {
        guard let descriptor = TargetDescriptor(payload: payload) else {
            throw TutorHostFailure(code: "unsupported_target", message: "An authored target descriptor is required to resolve a target")
        }
        // Pointing changes nothing, so a model hint is sufficient on its own when
        // no local provider can resolve the target. Acting is different: it still
        // demands locally corroborated evidence at the pack's `act` threshold.
        let target: ResolvedTarget
        do {
            target = try resolveFreshTarget(payload, descriptor: descriptor, minimumConfidence: descriptor.confidence.point)
        } catch let failure as TutorHostFailure where failure.code == "unresolved" || failure.code == "ambiguous_target" {
            guard let hinted = try hintedTarget(payload, descriptor: descriptor) else { throw failure }
            target = hinted
        }
        // tutor_point already carries a `label`; render it beside the cursor so
        // the learner is told what to do, not just where to look.
        var label: String?
        if case .string(let value)? = payload["label"] { label = value }
        var step = "Calla"
        if case .string(let value)? = payload["step"] { step = value }
        PointerOverlay.shared.show(at: target.frame, step: step, label: label)
        return [
            "status": .string("ok"),
            "snapshot_id": .string(target.snapshot.id),
            "confidence": .number(target.confidence),
            "evidence": .array(target.evidence.map { .string($0) }),
        ]
    }

    func verify(_ payload: [String: JSONValue]) throws -> [String: JSONValue] {
        guard let descriptor = TargetDescriptor(payload: payload) else {
            throw TutorHostFailure(code: "unsupported_target", message: "An authored target descriptor is required to verify a target")
        }
        let (app, _) = try focusedAllowedApp(allowlist: descriptor.bundleIDs)
        let snapshot = try makeSnapshot(for: app)
        let target = try resolve(descriptor: descriptor, in: app, snapshot: snapshot,
                                 minimumConfidence: descriptor.confidence.point)
        let selected = boolAttribute(target.element, kAXSelectedAttribute as CFString) ?? false
        return [
            "status": .string(selected ? "satisfied" : "unsatisfied"),
            "snapshot_id": .string(snapshot.id),
            "semantic_id": .string(descriptor.semanticID),
            "value": .string(selected ? "selected" : "unselected"),
        ]
    }

    func resolveFreshTarget(_ payload: [String: JSONValue],
                            descriptor: TargetDescriptor,
                            minimumConfidence: Double) throws -> ResolvedTarget {
        guard case .string(let snapshotID)? = payload["snapshot_id"], let prior = snapshots[snapshotID] else {
            throw TutorHostFailure(code: "unknown_snapshot", message: "An observation receipt is required before resolving an action target")
        }
        guard Date().timeIntervalSince(prior.createdAt) <= maxSnapshotAge else {
            throw TutorHostFailure(code: "stale_snapshot", message: "The observation receipt is stale")
        }
        let (app, _) = try focusedAllowedApp(allowlist: descriptor.bundleIDs)
        let fresh = try makeSnapshot(for: app)
        guard fresh.processID == prior.processID, fresh.windowFrame.equalTo(prior.windowFrame) else {
            throw TutorHostFailure(code: "changed_window", message: "The focused window changed after observation")
        }
        return try resolve(descriptor: descriptor, in: app, snapshot: fresh, minimumConfidence: minimumConfidence)
    }

    func press(_ target: ResolvedTarget) throws {
        guard AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success else {
            throw TutorHostFailure(code: "action_failed", message: "macOS Accessibility rejected the approved action")
        }
    }

    /// Maps a normalised vision hint onto the observed window. The hint is a
    /// search prior, never authority: it is accepted for `point` only, is capped
    /// below any action threshold, and is recorded as `model_hint` evidence.
    private func hintedTarget(_ payload: [String: JSONValue], descriptor: TargetDescriptor) throws -> ResolvedTarget? {
        guard case .object(let hint)? = payload["target_hint"],
              case .object(let region)? = hint["region"],
              case .number(let x)? = region["x"], case .number(let y)? = region["y"],
              case .number(let width)? = region["width"], case .number(let height)? = region["height"] else {
            return nil
        }
        for value in [x, y, width, height] where !(0...1).contains(value) {
            throw TutorHostFailure(code: "unsupported_target", message: "A target hint must be normalised to the captured window")
        }
        guard width > 0, height > 0 else { return nil }
        guard case .string(let snapshotID)? = payload["snapshot_id"], let snapshot = snapshots[snapshotID] else {
            throw TutorHostFailure(code: "unknown_snapshot", message: "An observation receipt is required before using a target hint")
        }
        guard Date().timeIntervalSince(snapshot.createdAt) <= maxSnapshotAge else {
            throw TutorHostFailure(code: "stale_snapshot", message: "The observation receipt is stale")
        }
        let window = snapshot.windowFrame
        let frame = CGRect(x: window.origin.x + x * window.width,
                           y: window.origin.y + y * window.height,
                           width: max(width * window.width, 8),
                           height: max(height * window.height, 8))
        return ResolvedTarget(element: AXUIElementCreateSystemWide(), frame: frame,
                              confidence: min(descriptor.confidence.point, 0.75),
                              snapshot: snapshot, evidence: ["model_hint"])
    }

    private static func allowlist(from payload: [String: JSONValue]) -> [String] {
        if let descriptor = TargetDescriptor(payload: payload) { return descriptor.bundleIDs }
        if case .array(let ids)? = payload["bundle_ids"] {
            return ids.compactMap { if case .string(let value) = $0 { return value } else { return nil } }
        }
        return []
    }

    /// Fails closed: with no authored allowlist there is no allowed application.
    private func focusedAllowedApp(allowlist: [String]) throws -> (AXUIElement, NSRunningApplication) {
        guard !allowlist.isEmpty else {
            throw TutorHostFailure(code: "app_not_allowed", message: "No application allowlist was supplied by the App Pack")
        }
        guard let running = NSWorkspace.shared.frontmostApplication,
              let bundleID = running.bundleIdentifier,
              allowlist.contains(bundleID) else {
            throw TutorHostFailure(code: "app_not_allowed", message: "The focused application is not allowlisted for this pack")
        }
        return (AXUIElementCreateApplication(running.processIdentifier), running)
    }

    /// Provider chain. Each provider that contributes appends to `evidence`, which
    /// is what the resolved-target receipt reports.
    private func resolve(descriptor: TargetDescriptor,
                         in app: AXUIElement,
                         snapshot: Snapshot,
                         minimumConfidence: Double) throws -> ResolvedTarget {
        guard descriptor.hasAccessibilityContract else {
            throw TutorHostFailure(code: "unresolved", message: "\(descriptor.semanticID) has no resolver this host can execute yet")
        }
        let candidates = accessibilityCandidates(descriptor: descriptor, in: app, snapshot: snapshot)
            .sorted { $0.confidence > $1.confidence }
        guard let best = candidates.first, best.confidence >= minimumConfidence else {
            throw TutorHostFailure(code: "unresolved", message: "\(descriptor.semanticID) could not be resolved with enough confidence")
        }
        guard candidates.dropFirst().first.map({ best.confidence - $0.confidence >= 0.1 }) ?? true else {
            throw TutorHostFailure(code: "ambiguous_target", message: "\(descriptor.semanticID) remains ambiguous")
        }
        return best
    }

    private func accessibilityCandidates(descriptor: TargetDescriptor,
                                         in app: AXUIElement,
                                         snapshot: Snapshot) -> [ResolvedTarget] {
        let elements = descendants(of: app, maxDepth: 12)
        return elements.compactMap { element -> ResolvedTarget? in
            let role = stringAttribute(element, kAXRoleAttribute as CFString)
            let title = stringAttribute(element, kAXTitleAttribute as CFString)
            let description = stringAttribute(element, kAXDescriptionAttribute as CFString)
            let help = stringAttribute(element, kAXHelpAttribute as CFString)
            let label = [title, description, help].compactMap { $0 }.joined(separator: " ")

            for candidate in descriptor.accessibilityCandidates {
                if let expectedRole = candidate.role, role != expectedRole { continue }
                var matched = candidate.role != nil
                var evidence: [String] = []
                if let pattern = candidate.labelPattern {
                    guard pattern.matches(label) else { continue }
                    matched = true
                    evidence.append("ax:label")
                }
                if let pattern = candidate.descriptionPattern {
                    guard pattern.matches(description ?? "") else { continue }
                    matched = true
                    evidence.append("ax:description")
                }
                guard matched, let frame = try? frameAttribute(element), frame.width > 0, frame.height > 0 else { continue }
                if let expectedRole = candidate.role { evidence.append("ax:role=\(expectedRole)") }
                // An exact label is stronger corroboration than a regex hit alone.
                let exact = label.compare(descriptor.semanticID, options: .caseInsensitive) == .orderedSame
                let confidence = exact ? 0.96 : (evidence.count >= 2 ? 0.9 : 0.76)
                return ResolvedTarget(element: element, frame: frame, confidence: confidence,
                                      snapshot: snapshot, evidence: evidence)
            }
            return nil
        }
    }

    private func makeSnapshot(for app: AXUIElement) throws -> Snapshot {
        var processID: pid_t = 0
        AXUIElementGetPid(app, &processID)
        guard let window = copyElementAttribute(app, kAXFocusedWindowAttribute as CFString) else {
            throw TutorHostFailure(code: "no_focused_window", message: "The focused application has no focused window")
        }
        let version = NSWorkspace.shared.frontmostApplication?.bundleURL.flatMap {
            Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        } ?? "unknown"
        return Snapshot(processID: processID, windowFrame: try frameAttribute(window), appVersion: version)
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

// The Calla pointer: a distinct AI cursor plus a macOS tooltip saying what to
// do. AppKit windows are main-actor only and every call site is the @MainActor
// controller, so the whole overlay is isolated to the main actor.
private struct AICursor: View {
    private static let arrow = Path { p in
        p.move(to: CGPoint(x: 2, y: 1))
        p.addLine(to: CGPoint(x: 2, y: 23))
        p.addLine(to: CGPoint(x: 7.6, y: 17.8))
        p.addLine(to: CGPoint(x: 11.1, y: 25.4))
        p.addLine(to: CGPoint(x: 14.9, y: 23.7))
        p.addLine(to: CGPoint(x: 11.4, y: 16.3))
        p.addLine(to: CGPoint(x: 18.8, y: 15.8))
        p.closeSubpath()
    }

    var body: some View {
        Self.arrow
            .fill(LinearGradient(colors: [Color(red: 1, green: 0.72, blue: 0.25),
                                          Color(red: 1, green: 0.48, blue: 0)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Self.arrow.stroke(.white, lineWidth: 1.4))
            .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
            .frame(width: 22, height: 27)
    }
}

private struct PulseRing: View {
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(Color(red: 1, green: 0.58, blue: 0).opacity(expanded ? 0 : 0.85), lineWidth: 3)
            .scaleEffect(expanded ? 1.5 : 0.6)
            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: expanded)
            .onAppear { expanded = true }
    }
}

private struct TutorTooltip: View {
    let step: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.58, blue: 0))
                Text(step)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: PointerOverlay.tooltipSize.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(red: 1, green: 0.58, blue: 0).opacity(0.55), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        )
    }
}

@MainActor
private final class PointerOverlay {
    static let shared = PointerOverlay()
    static let tooltipSize = CGSize(width: 300, height: 96)

    private var panels: [NSWindow] = []

    /// `frame` is in Accessibility coordinates (top-left origin).
    func show(at frame: CGRect, step: String, label: String?) {
        hide()
        let target = Self.cocoaRect(fromAccessibility: frame)
        let tip = CGPoint(x: target.midX, y: target.midY)

        let ring = Self.panel(CGRect(x: tip.x - 26, y: tip.y - 26, width: 52, height: 52))
        ring.contentView = NSHostingView(rootView: PulseRing())
        ring.orderFrontRegardless()
        panels.append(ring)

        // The cursor's hotspot is its top-left tip, and Cocoa y grows upward.
        let cursor = Self.panel(CGRect(x: tip.x, y: tip.y - 27, width: 22, height: 27))
        cursor.contentView = NSHostingView(rootView: AICursor())
        cursor.orderFrontRegardless()
        panels.append(cursor)

        guard let label, !label.isEmpty else { return }
        let tooltip = Self.panel(Self.tooltipFrame(besides: tip))
        tooltip.contentView = NSHostingView(rootView: TutorTooltip(step: step, text: String(label.prefix(240))))
        tooltip.orderFrontRegardless()
        panels.append(tooltip)
    }

    /// Without this the previous step's cursor and tooltip stay on screen forever.
    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    private static func panel(_ frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    /// Prefer the right of the cursor, flip left when it would run off screen.
    private static func tooltipFrame(besides tip: CGPoint) -> CGRect {
        let size = tooltipSize
        let screen = NSScreen.screens.first { $0.frame.contains(tip) } ?? NSScreen.main ?? NSScreen.screens[0]
        var x = tip.x + 26
        if x + size.width > screen.frame.maxX - 8 { x = tip.x - 26 - size.width }
        x = max(screen.frame.minX + 8, min(x, screen.frame.maxX - size.width - 8))
        let y = min(max(tip.y - size.height - 6, screen.frame.minY + 8), screen.frame.maxY - size.height - 8)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Accessibility reports a top-left origin with y growing downward; Cocoa
    /// windows use a bottom-left origin with y growing upward. Without this flip
    /// the overlay is drawn mirrored about the horizontal axis of the display.
    private static func cocoaRect(fromAccessibility frame: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return frame }
        return CGRect(x: frame.origin.x,
                      y: primary.frame.height - frame.origin.y - frame.height,
                      width: frame.width,
                      height: frame.height)
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
