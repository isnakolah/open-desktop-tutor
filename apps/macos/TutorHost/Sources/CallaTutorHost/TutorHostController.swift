import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI
import TutorProtocol

/// What this request may observe.
///
/// The lesson says which applications it is about; the user says which ones
/// Calla is allowed near at all. The answer is the intersection, so a lesson can
/// narrow the user's choice and never widen it.
@MainActor
private func allowlist(from payload: [String: JSONValue]) -> Set<String> {
    var requested: Set<String>?
    if case .array(let ids)? = payload["allowed_bundle_ids"] {
        requested = Set(ids.compactMap { value -> String? in
            if case .string(let id) = value, !id.isEmpty, id.count <= 255 { return id }
            return nil
        })
    }
    return TutorSettings.shared.effectiveAllowlist(requested: requested)
}
private let maxRequestFrameBytes = 64 * 1024
private let maxResponseFrameBytes = Int(1.5 * 1024 * 1024)
private let maxCaptureJPEGBytes = 1024 * 1024
private let forbiddenCoordinateKeys: Set<String> = [
    "x", "y", "left", "top", "width", "height", "coordinate", "coordinates", "screen_x", "screen_y", "bounds", "frame",
]

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

private struct Snapshot {
    let id = UUID().uuidString
    let createdAt = Date()
    let processID: pid_t
    let windowID: CGWindowID
    let windowFrame: CGRect
    let appBundleID: String
    let appVersion: String
}

private struct ResolvedTarget {
    let element: AXUIElement
    let frame: CGRect
    let confidence: Double
    let snapshot: Snapshot
    let descriptor: UITargetDescriptor
    let evidence: [String]
}

private struct FocusedApplication {
    let application: NSRunningApplication
    let element: AXUIElement
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
    /// Shared so the app delegate can start the socket at launch and the menu
    /// can observe the same instance.
    static let shared = TutorHostController()

    @Published var captureActive = true
    @Published var status = "Starting local TutorHost"
    @Published var pendingApproval: PendingApproval?

    private let engine = AccessibilityTutorEngine()
    private var socketServer: UnixSocketServer?

    func start() async {
        guard socketServer == nil else { return }
        do {
            let server = try UnixSocketServer(path: Self.socketPath) { [weak self] request in
                guard let self else {
                    return TutorResponse(requestID: request.requestID, ok: false, payload: nil, error: TutorError(code: "host_stopped", message: "TutorHost is unavailable"))
                }
                return await self.handle(request)
            }
            try server.start()
            socketServer = server
            status = "Local TutorHost ready (protocol v2)"
        } catch {
            status = "TutorHost failed: \(error.localizedDescription)"
        }
    }

    private func handle(_ request: TutorRequest) async -> TutorResponse {
        guard request.protocolVersion == TutorProtocolVersion.current else {
            return failure(request, "unsupported_version", "Tutor protocol version 2 is required")
        }
        // Recorded before any validation: the menu needs to show that Calla is
        // reaching this Mac even when what it sent was refused.
        BackendStatus.shared.noteRequest(operation: request.operation)
        guard request.sessionID.count >= 8 else { return failure(request, "invalid_session", "A valid teaching session is required") }
        guard captureActive else { return failure(request, "capture_paused", "Capture is paused locally") }
        do {
            try validateMacIngress(operation: request.operation, payload: request.payload)
            let payload: [String: JSONValue]
            switch request.operation {
            case "observe": payload = try await engine.observe(request.payload)
            case "guide": payload = try engine.guide(request.payload)
            case "await_change": payload = try await engine.awaitChange(request.payload)
            case "narrate": payload = engine.narrate(request.payload)
            case "point": payload = try engine.point(request.payload)
            case "propose_action": payload = try await proposeAction(request.payload)
            case "verify": payload = try engine.verify(request.payload)
            default: return failure(request, "unsupported_operation", "This TutorHost accepts observe, guide, narrate, point, propose_action, and verify only")
            }
            return TutorResponse(requestID: request.requestID, ok: true, payload: payload, error: nil)
        } catch let hostFailure as TutorHostFailure {
            return failure(request, hostFailure.code, hostFailure.message)
        } catch let descriptorFailure as DescriptorValidationError {
            return failure(request, "invalid_descriptor", descriptorFailure.message)
        } catch {
            return failure(request, "host_error", error.localizedDescription)
        }
    }

    private func proposeAction(_ payload: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard payload["target_hint"] == nil else {
            throw TutorHostFailure(code: "target_hint_forbidden", message: "A visual hint can never contribute action authority")
        }
        guard case .string(let action)? = payload["action"], action == "click" else {
            throw TutorHostFailure(code: "unsupported_action", message: "This TutorHost supports only a locally approved semantic click")
        }
        let target = try engine.resolveFreshTarget(payload, authority: .action, allowHint: false)
        let detector = try engine.detector(from: payload, key: "expected_state")
        let approved = await withCheckedContinuation { continuation in
            pendingApproval = PendingApproval(
                id: UUID(),
                summary: "Click \(target.descriptor.title) in the focused allowlisted window.",
                continuation: continuation)
        }
        guard approved else {
            return ["status": .string("denied"), "reason": .string("The local user denied the action")]
        }
        try engine.press(target)
        return try engine.evaluate(detector: detector, target: target)
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

private func validateMacIngress(operation: String, payload: [String: JSONValue]) throws {
    if operation == "propose_action", payload["target_hint"] != nil {
        throw TutorHostFailure(code: "target_hint_forbidden", message: "A visual hint can never contribute action authority")
    }
    if operation == "observe", payload["include_crop"] != nil {
        throw TutorHostFailure(code: "invalid_capture_request", message: "include_crop was replaced by include_capture in protocol v2")
    }
    // The one normalized region a model may send, and where. Pointing takes it
    // under `target_hint`; guiding takes it directly, because guiding has no
    // descriptor to hang it off. Everywhere else a coordinate-shaped key is a
    // rejection, and neither exemption reaches an operation that can act.
    let normalizedRegionParent: String?
    switch operation {
    case "point": normalizedRegionParent = "payload.target_hint"
    case "guide": normalizedRegionParent = "payload"
    default: normalizedRegionParent = nil
    }
    if let path = macForbiddenCoordinatePath(.object(payload), path: "payload", normalizedRegionParent: normalizedRegionParent) {
        throw TutorHostFailure(code: "invalid_coordinates", message: "Raw coordinate field \(path) is forbidden")
    }
}

private func macForbiddenCoordinatePath(_ value: JSONValue, path: String, normalizedRegionParent: String?) -> String? {
    switch value {
    case .object(let object):
        for (key, child) in object {
            let next = "\(path).\(key)"
            if let parent = normalizedRegionParent, path == parent, key == "region" { continue }
            if forbiddenCoordinateKeys.contains(key.lowercased()) { return next }
            if let found = macForbiddenCoordinatePath(child, path: next, normalizedRegionParent: normalizedRegionParent) { return found }
        }
    case .array(let values):
        for (index, child) in values.enumerated() {
            if let found = macForbiddenCoordinatePath(child, path: "\(path).\(index)", normalizedRegionParent: normalizedRegionParent) { return found }
        }
    default: break
    }
    return nil
}

private enum ResolutionAuthority { case point, action }

// Every call site is on the @MainActor TutorHostController, and point() drives
// an AppKit overlay, so state the isolation the code already relies on.
@MainActor
private final class AccessibilityTutorEngine {
    private var snapshots: [String: Snapshot] = [:]
    private let maxSnapshotAge: TimeInterval = 4
    /// Guiding only draws, so it can wait out a vision round trip that acting
    /// never would.
    private let maxGuideSnapshotAge: TimeInterval = 180
    private let bridgeObserver = BlenderBridgeObserver()

    func observe(_ payload: [String: JSONValue]) async throws -> [String: JSONValue] {
        let focused = try focusedAllowlistedApplication(allowlist(from: payload))
        let snapshot = try makeSnapshot(for: focused)
        snapshots[snapshot.id] = snapshot
        var result: [String: JSONValue] = [
            "status": .string("ok"),
            "snapshot_id": .string(snapshot.id),
            "app_bundle_id": .string(snapshot.appBundleID),
            "app_version": .string(snapshot.appVersion),
        ]
        if let capture = payload["include_capture"] {
            guard let includeCapture = capture.boolValue else {
                throw TutorHostFailure(code: "invalid_capture_request", message: "include_capture must be a boolean")
            }
            if includeCapture {
                let jpeg = try await captureFocusedWindow(snapshot)
                result["capture"] = .object([
                    "snapshot_id": .string(snapshot.id),
                    "mime_type": .string("image/jpeg"),
                    "base64": .string(jpeg.base64EncodedString()),
                ])
            }
        }
        return result
    }

    /// Point at a region the model read off the window capture.
    ///
    /// This is the path that carries a lesson in an application nobody has
    /// authored a pack for. There is no descriptor to resolve and no
    /// Accessibility tree to consult — the model looked at the JPEG it asked
    /// for, and says where in that window the learner should look. The Mac
    /// still owns everything that matters: it re-finds the window itself, maps
    /// the region against the window's *current* geometry, and draws. Nothing
    /// here can click, and no screen coordinate goes back over the wire.
    func guide(_ payload: [String: JSONValue]) throws -> [String: JSONValue] {
        guard let region = try normalizedRegion(payload["region"]) else {
            throw TutorHostFailure(code: "missing_region", message: "guide requires one normalized region of the observed window")
        }
        let window = try liveWindow(for: payload)
        let frame = CGRect(x: window.frame.minX + window.frame.width * region.left,
                           y: window.frame.minY + window.frame.height * region.top,
                           width: max(window.frame.width * region.width, 8),
                           height: max(window.frame.height * region.height, 8))
        let step = payload["step"]?.stringValue ?? "Calla"
        let text = payload["text"]?.stringValue ?? ""
        let status = payload["status"]?.stringValue ?? "Calla — \(step)"
        PointerOverlay.shared.point(at: frame, window: window.frame, owner: window.snapshot.appBundleID,
                                    step: step, text: String(text.prefix(240)), status: status)
        return [
            "status": .string("ok"),
            "guide_receipt": .object([
                "snapshot_id": .string(window.snapshot.id),
                "app_bundle_id": .string(window.snapshot.appBundleID),
                "evidence": .array([.string("model_region_on_live_window")]),
                "valid_until": .string("next_window_mutation"),
            ]),
        ]
    }

    /// Wait until the learner does something, then say so.
    ///
    /// This is what turns a single instruction into a lesson. Without it the
    /// model points once and stops, because nothing tells it the step was
    /// finished — the learner clicks, and Calla is still talking about the
    /// previous thing. Polling a coarse greyscale fingerprint of the window
    /// keeps the judgement on this Mac; only "it changed" crosses the wire.
    ///
    /// Returns rather than blocks when the wait runs out, so the model can
    /// decide whether to keep waiting, re-word the step, or move on.
    func awaitChange(_ payload: [String: JSONValue]) async throws -> [String: JSONValue] {
        let window = try liveWindow(for: payload)
        let requested = payload["timeout_seconds"]?.numberValue ?? 15
        let deadline = Date().addingTimeInterval(min(max(requested, 1), 25))
        let threshold = min(max(payload["sensitivity"]?.numberValue ?? 0.02, 0.005), 0.5)

        let baseline = try await thumbprint(window.snapshot)
        var latest = baseline
        var difference = 0.0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 400_000_000)
            // The learner switching away is not a change in the lesson's window,
            // and re-reading a window that is no longer there is meaningless.
            guard let focused = NSWorkspace.shared.frontmostApplication,
                  focused.bundleIdentifier == window.snapshot.appBundleID else { continue }
            latest = (try? await thumbprint(window.snapshot)) ?? latest
            difference = WindowCapture.difference(baseline, latest)
            if difference >= threshold { break }
        }
        let changed = difference >= threshold
        return [
            "status": .string("ok"),
            "changed": .bool(changed),
            "difference": .number((difference * 1000).rounded() / 1000),
            "snapshot_id": .string(window.snapshot.id),
            "next": .string(changed
                            ? "Observe again; the window is not what you last saw."
                            : "Nothing moved. The learner may be stuck, or the step may already have been done."),
        ]
    }

    private func thumbprint(_ snapshot: Snapshot) async throws -> [UInt8] {
        do {
            return try await WindowCapture.thumbprint(bundleID: snapshot.appBundleID, processID: snapshot.processID)
        } catch WindowCapture.Failure.notPermitted {
            throw TutorHostFailure(code: "screen_recording_not_permitted",
                                   message: "Screen Recording permission is required to notice the window changing")
        } catch {
            throw TutorHostFailure(code: "capture_failed", message: "The focused allowlisted window could not be read")
        }
    }

    /// Re-word the tooltip without moving the cursor, so the model can keep
    /// talking about the control it already pointed at.
    func narrate(_ payload: [String: JSONValue]) -> [String: JSONValue] {
        let step = payload["step"]?.stringValue ?? "Calla"
        let text = payload["text"]?.stringValue ?? ""
        PointerOverlay.shared.narrate(step: step,
                                      text: String(text.prefix(240)),
                                      status: payload["status"]?.stringValue ?? "Calla — \(step)",
                                      thinking: payload["thinking"]?.boolValue ?? false)
        return ["status": .string("ok")]
    }

    /// The window the observation named, located again right now.
    ///
    /// Guiding deliberately tolerates a much older observation than acting
    /// does: a vision round trip over the tailnet takes seconds, and drawing an
    /// arrow changes nothing. What it will not tolerate is a *different*
    /// window, so process and window identity must still match, and the region
    /// is mapped against the geometry read back in this call rather than the
    /// geometry captured earlier.
    private func liveWindow(for payload: [String: JSONValue]) throws -> (snapshot: Snapshot, frame: CGRect) {
        guard case .string(let snapshotID)? = payload["snapshot_id"], let prior = snapshots[snapshotID] else {
            throw TutorHostFailure(code: "unknown_snapshot", message: "An observation receipt is required before guiding")
        }
        guard Date().timeIntervalSince(prior.createdAt) <= maxGuideSnapshotAge else {
            throw TutorHostFailure(code: "stale_snapshot", message: "The observation receipt is stale; observe again")
        }
        let focused = try focusedAllowlistedApplication(allowlist(from: payload))
        let fresh = try makeSnapshot(for: focused)
        guard fresh.processID == prior.processID, fresh.windowID == prior.windowID else {
            throw TutorHostFailure(code: "changed_window", message: "The focused allowlisted window changed after observation")
        }
        return (prior, fresh.windowFrame)
    }

    func point(_ payload: [String: JSONValue]) throws -> [String: JSONValue] {
        let target = try resolveFreshTarget(payload, authority: .point, allowHint: true)
        var label: String?
        if case .string(let value)? = payload["label"] { label = value }
        var step = "Calla"
        if case .string(let value)? = payload["step"] { step = value }
        PointerOverlay.shared.point(at: target.frame,
                                    window: target.snapshot.windowFrame,
                                    owner: target.snapshot.appBundleID,
                                    step: step,
                                    text: label ?? target.descriptor.title,
                                    status: "Calla — \(target.descriptor.title)")
        return ["status": .string("ok"), "resolution_receipt": receipt(for: target)]
    }

    func verify(_ payload: [String: JSONValue]) throws -> [String: JSONValue] {
        guard payload["target_hint"] == nil else {
            throw TutorHostFailure(code: "target_hint_forbidden", message: "Verification accepts only locally resolved descriptor evidence")
        }
        let target = try resolveFreshTarget(payload, authority: .point, allowHint: false)
        let detector = try self.detector(from: payload, key: "detector_descriptor")
        return try evaluate(detector: detector, target: target)
    }

    func detector(from payload: [String: JSONValue], key: String) throws -> DetectorDescriptor {
        guard let raw = payload[key] else {
            throw TutorHostFailure(code: "missing_detector", message: "A canonical App-Pack detector descriptor is required")
        }
        return try DetectorDescriptor(raw: raw)
    }

    func resolveFreshTarget(_ payload: [String: JSONValue], authority: ResolutionAuthority, allowHint: Bool) throws -> ResolvedTarget {
        guard let rawDescriptor = payload["target_descriptor"] else {
            throw TutorHostFailure(code: "missing_target", message: "A canonical App-Pack target descriptor is required")
        }
        let descriptor = try UITargetDescriptor(raw: rawDescriptor)
        guard case .string(let snapshotID)? = payload["snapshot_id"], let prior = snapshots[snapshotID] else {
            throw TutorHostFailure(code: "unknown_snapshot", message: "An observation receipt is required before target resolution")
        }
        guard Date().timeIntervalSince(prior.createdAt) <= maxSnapshotAge else {
            throw TutorHostFailure(code: "stale_snapshot", message: "The observation receipt is stale")
        }
        let hint: NormalizedRegion?
        if allowHint {
            hint = try normalizedHint(payload["target_hint"])
        } else {
            guard payload["target_hint"] == nil else {
                throw TutorHostFailure(code: "target_hint_forbidden", message: "A visual hint is permitted for pointing only")
            }
            hint = nil
        }
        let focused = try focusedAllowlistedApplication(allowlist(from: payload))
        let fresh = try makeSnapshot(for: focused)
        guard fresh.processID == prior.processID, fresh.windowID == prior.windowID, fresh.windowFrame.equalTo(prior.windowFrame) else {
            throw TutorHostFailure(code: "changed_window", message: "The focused allowlisted window changed after observation")
        }
        let threshold = authority == .action ? descriptor.actionMinimumConfidence : descriptor.pointMinimumConfidence
        do {
            let target = try resolve(descriptor: descriptor, in: focused.element, snapshot: fresh, hint: hint)
            guard target.confidence >= threshold else {
                throw TutorHostFailure(code: "unresolved", message: "Local descriptor evidence did not meet the authored confidence threshold")
            }
            return target
        } catch let failure as TutorHostFailure where failure.code == "unresolved" || failure.code == "ambiguous_target" {
            // Applications that render their own interface (Blender draws in
            // OpenGL) expose no Accessibility elements, so constraining an empty
            // candidate list by the hint can never resolve. Pointing changes
            // nothing, so the hint alone may place the cursor there. Acting never
            // may: `authority == .action` rethrows, and allowHint is false for it.
            guard authority == .point, let hint else { throw failure }
            let window = fresh.windowFrame
            let frame = CGRect(x: window.minX + window.width * hint.left,
                               y: window.minY + window.height * hint.top,
                               width: max(window.width * hint.width, 8),
                               height: max(window.height * hint.height, 8))
            return ResolvedTarget(element: focused.element,
                                  frame: frame,
                                  confidence: min(threshold, 0.75),
                                  snapshot: fresh,
                                  descriptor: descriptor,
                                  evidence: ["visual_hint_only"])
        }
    }

    func press(_ target: ResolvedTarget) throws {
        guard AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success else {
            throw TutorHostFailure(code: "action_failed", message: "macOS Accessibility rejected the locally approved action")
        }
    }

    func evaluate(detector: DetectorDescriptor, target: ResolvedTarget) throws -> [String: JSONValue] {
        switch detector.provider {
        case .accessibility:
            guard detector.query["target"]?.stringValue == target.descriptor.id else {
                throw TutorHostFailure(code: "detector_target_mismatch", message: "The detector does not apply to the locally resolved target")
            }
            guard let attribute = detector.query["attribute"]?.stringValue, let expected = detector.query["equals"]?.boolValue else {
                throw TutorHostFailure(code: "invalid_detector", message: "The accessibility detector is malformed")
            }
            let actual: Bool
            switch attribute {
            case "selected": actual = boolAttribute(target.element, kAXSelectedAttribute as CFString) ?? false
            case "enabled": actual = boolAttribute(target.element, kAXEnabledAttribute as CFString) ?? false
            case "visible": actual = !target.frame.isEmpty
            default: throw TutorHostFailure(code: "invalid_detector", message: "The detector requests an unsupported accessibility attribute")
            }
            return [
                "expectation_id": .string(detector.id),
                "outcome": .string(actual == expected ? "satisfied" : "unsatisfied"),
                "stable_samples": .number(1),
                "evidence": .array([.string("accessibility:\(attribute)")]),
                "resolution_receipt": receipt(for: target),
            ]
        case .blenderBridge:
            do {
                let state = try bridgeObserver.observeState()
                let satisfied = try Self.evaluateBridgeQuery(detector.query, state: state)
                return [
                    "expectation_id": .string(detector.id),
                    "outcome": .string(satisfied ? "satisfied" : "unsatisfied"),
                    "stable_samples": .number(1),
                    "evidence": .array([.string("read_only_blender_bridge")]),
                    "resolution_receipt": receipt(for: target),
                ]
            } catch {
                // A missing or failed bridge never falls back to model or pixel
                // interpretation. Accessibility-only detectors remain usable.
                return [
                    "expectation_id": .string(detector.id),
                    "outcome": .string("unknown"),
                    "stable_samples": .number(0),
                    "evidence": .array([.string("read_only_bridge_unavailable")]),
                    "reason": .string("No local read-only bridge observation was available"),
                    "resolution_receipt": receipt(for: target),
                ]
            }
        }
    }

    private func receipt(for target: ResolvedTarget) -> JSONValue {
        .object([
            "semantic_id": .string(target.descriptor.id),
            "snapshot_id": .string(target.snapshot.id),
            "confidence": .number(target.confidence),
            "evidence": .array(target.evidence.map(JSONValue.string)),
            "valid_until": .string("next_window_mutation"),
        ])
    }

    private func normalizedHint(_ value: JSONValue?) throws -> NormalizedRegion? {
        guard let value else { return nil }
        guard case .object(let hint) = value, Set(hint.keys) == Set(["region"]) else {
            throw TutorHostFailure(code: "invalid_target_hint", message: "target_hint must contain one normalized region only")
        }
        return try normalizedRegion(hint["region"])
    }

    /// A region of the observed window, in [0,1], and nothing else. Rejecting
    /// any extra key is what keeps a pixel rectangle from arriving dressed as a
    /// normalized one.
    private func normalizedRegion(_ value: JSONValue?) throws -> NormalizedRegion? {
        guard let value else { return nil }
        guard case .object(let region) = value, Set(region.keys) == Set(["left", "top", "width", "height"]),
              let left = region["left"]?.numberValue, let top = region["top"]?.numberValue,
              let width = region["width"]?.numberValue, let height = region["height"]?.numberValue else {
            throw TutorHostFailure(code: "invalid_region", message: "A region must contain left, top, width, and height only")
        }
        do { return try NormalizedRegion(left: left, top: top, width: width, height: height) }
        catch let error as DescriptorValidationError { throw TutorHostFailure(code: "invalid_region", message: error.message) }
    }

    /// The application this lesson is about.
    ///
    /// Normally that is whatever is in front. But asking Calla for a lesson
    /// means typing somewhere — a chat window, a terminal — and on this Mac that
    /// is the same screen, so by the time the request arrives the application
    /// the learner meant is behind the one they typed into. Requiring it to be
    /// frontmost made the product impossible to trigger from the machine it
    /// teaches on.
    ///
    /// So when the front application is not one Calla may observe, fall back to
    /// the most recent one that was. The allowlist is still the entire
    /// permission boundary: this can only ever land on an application the owner
    /// already allowed, and only one they were using themselves.
    private func focusedAllowlistedApplication(_ allowed: Set<String>) throws -> FocusedApplication {
        if let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier,
           allowed.contains(bundleID) {
            LessonSubject.shared.remember(app)
            return FocusedApplication(application: app, element: AXUIElementCreateApplication(app.processIdentifier))
        }
        if let recent = LessonSubject.shared.mostRecent(in: allowed) {
            return FocusedApplication(application: recent, element: AXUIElementCreateApplication(recent.processIdentifier))
        }
        throw TutorHostFailure(
            code: "app_not_allowed",
            message: "No application this Mac allows Calla to observe is open. Focus it once, then ask again.")
    }

    /// Builds the observation receipt without touching Accessibility.
    ///
    /// Applications that render their own interface expose no Accessibility
    /// tree, and AX is a separate TCC grant that silently returns nil when
    /// stale. The window geometry this host actually needs — id, bounds — comes
    /// from the window server, which only requires Screen Recording. AX is used
    /// afterwards, if at all, to resolve elements *within* the window.
    private func makeSnapshot(for focused: FocusedApplication) throws -> Snapshot {
        let window = try frontmostWindow(processID: focused.application.processIdentifier)
        let version = focused.application.bundleURL.flatMap {
            Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        } ?? "unknown"
        return Snapshot(processID: focused.application.processIdentifier,
                        windowID: window.id,
                        windowFrame: window.frame,
                        appBundleID: focused.application.bundleIdentifier ?? "unknown",
                        appVersion: version)
    }

    /// The largest on-screen, non-desktop window owned by the process.
    private func frontmostWindow(processID: pid_t) throws -> (id: CGWindowID, frame: CGRect) {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw TutorHostFailure(code: "window_lookup_failed", message: "The window server did not return a window list")
        }
        let owned = infos.compactMap { info -> (CGWindowID, CGRect)? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 1, frame.height > 1 else { return nil }
            return (CGWindowID(number.uint32Value), frame)
        }
        guard let best = owned.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) else {
            throw TutorHostFailure(code: "no_focused_window", message: "The focused allowlisted application has no on-screen window")
        }
        return (best.0, best.1)
    }

    private func focusedWindowID(processID: pid_t, frame: CGRect) throws -> CGWindowID {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw TutorHostFailure(code: "window_lookup_failed", message: "Could not inspect the focused allowlisted window")
        }
        let candidate = infos.first { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let windowFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return windowFrame.intersects(frame) && windowFrame.width > 0 && windowFrame.height > 0
        }
        guard let number = candidate?[kCGWindowNumber as String] as? NSNumber else {
            throw TutorHostFailure(code: "window_lookup_failed", message: "Could not identify the focused allowlisted window")
        }
        return CGWindowID(number.uint32Value)
    }

    /// CGWindowListCreateImage is deprecated and returns nil on current macOS,
    /// so capture goes through ScreenCaptureKit. Still exactly one window,
    /// never a display, and never written to disk.
    private func captureFocusedWindow(_ snapshot: Snapshot) async throws -> Data {
        do {
            let capture = try await WindowCapture.capture(bundleID: snapshot.appBundleID,
                                                          processID: snapshot.processID,
                                                          longEdge: CGFloat(TutorSettings.shared.captureLongEdge))
            guard capture.data.count <= maxCaptureJPEGBytes else {
                throw TutorHostFailure(code: "capture_too_large", message: "The focused window JPEG exceeds the in-memory capture limit")
            }
            return capture.data
        } catch let failure as TutorHostFailure {
            throw failure
        } catch WindowCapture.Failure.notPermitted {
            throw TutorHostFailure(code: "screen_recording_not_permitted", message: "Screen Recording permission is required to capture the window")
        } catch {
            throw TutorHostFailure(code: "capture_failed", message: "The focused allowlisted window could not be captured")
        }
    }

    private func resolve(descriptor: UITargetDescriptor, in app: AXUIElement, snapshot: Snapshot, hint: NormalizedRegion?) throws -> ResolvedTarget {
        guard !descriptor.accessibilityCandidates.isEmpty else {
            throw TutorHostFailure(code: "unresolved", message: "No safe local Accessibility resolver branch is authored for this target")
        }
        let crop = hint.map { normalizedRegion in
            CGRect(
                x: snapshot.windowFrame.minX + snapshot.windowFrame.width * normalizedRegion.left,
                y: snapshot.windowFrame.minY + snapshot.windowFrame.height * normalizedRegion.top,
                width: snapshot.windowFrame.width * normalizedRegion.width,
                height: snapshot.windowFrame.height * normalizedRegion.height)
        }
        let candidates = descendants(of: app, maxDepth: 12).compactMap { element -> ResolvedTarget? in
            guard let frame = try? frameAttribute(element), frame.width > 0, frame.height > 0,
                  crop.map({ $0.intersects(frame) }) ?? true else { return nil }
            guard let role = stringAttribute(element, kAXRoleAttribute as CFString) else { return nil }
            let title = stringAttribute(element, kAXTitleAttribute as CFString) ?? ""
            let description = stringAttribute(element, kAXDescriptionAttribute as CFString) ?? ""
            let help = stringAttribute(element, kAXHelpAttribute as CFString) ?? ""
            guard let match = descriptor.accessibilityCandidates.first(where: {
                matches(candidate: $0, role: role, title: title, description: description, help: help)
            }) else { return nil }
            let neighborsSatisfied = satisfiesNeighborConstraint(element, expected: descriptor.neighborConstraints)
            guard descriptor.neighborConstraints.isEmpty || neighborsSatisfied else { return nil }
            let matcherCount = [match.labelMatcher, match.descriptionMatcher, match.helpMatcher].compactMap { $0 }.count
            let aliasMatches = ([descriptor.title] + descriptor.aliases).contains {
                title.compare($0, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            let enabled = boolAttribute(element, kAXEnabledAttribute as CFString) == true
            // The score comes solely from independently observed local AX facts:
            // descriptor matcher(s), descriptor title/alias, and enabled state.
            // A model region is intentionally absent from this calculation.
            let confidence = min(1, 0.75 + 0.1 * Double(matcherCount) / 3 + (aliasMatches ? 0.1 : 0) + (enabled ? 0.1 : 0))
            var evidence = ["accessibility-role:\(role)", "descriptor-matcher"]
            if aliasMatches { evidence.append("descriptor-alias") }
            if enabled { evidence.append("accessibility-enabled") }
            if neighborsSatisfied { evidence.append("descriptor-neighbor") }
            if hint != nil { evidence.append("local-geometry-search-prior") }
            return ResolvedTarget(element: element, frame: frame, confidence: confidence, snapshot: snapshot, descriptor: descriptor, evidence: evidence)
        }
        guard candidates.count == 1, let target = candidates.first else {
            throw TutorHostFailure(code: candidates.isEmpty ? "unresolved" : "ambiguous_target", message: "The descriptor-constrained local result is not unique")
        }
        return target
    }

    private func matches(candidate: AccessibilityCandidate, role: String, title: String, description: String, help: String) -> Bool {
        guard role == candidate.role else { return false }
        if let matcher = candidate.labelMatcher, !matcher.matches(title) { return false }
        if let matcher = candidate.descriptionMatcher, !matcher.matches(description) { return false }
        if let matcher = candidate.helpMatcher, !matcher.matches(help) { return false }
        return true
    }

    private func satisfiesNeighborConstraint(_ element: AXUIElement, expected: [String]) -> Bool {
        guard !expected.isEmpty else { return true }
        guard let parent = copyElementAttribute(element, kAXParentAttribute as CFString) else { return false }
        let labels = descendants(of: parent, maxDepth: 2).map {
            [
                stringAttribute($0, kAXTitleAttribute as CFString),
                stringAttribute($0, kAXDescriptionAttribute as CFString),
                stringAttribute($0, kAXHelpAttribute as CFString),
            ].compactMap { $0 }.joined(separator: " ").lowercased()
        }
        return expected.contains { expectedLabel in
            let normalized = expectedLabel.replacingOccurrences(of: "_", with: " ").lowercased()
            return labels.contains { $0.contains(normalized) }
        }
    }

    private static func evaluateBridgeQuery(_ query: [String: JSONValue], state: JSONValue) throws -> Bool {
        guard let path = query["path"]?.stringValue else {
            throw TutorHostFailure(code: "invalid_detector", message: "The bridge detector has no bounded path")
        }
        let value = path.split(separator: ".").reduce(Optional(state)) { current, segment in
            current?.objectValue?[String(segment)]
        }
        guard let value else { return false }
        if let expected = query["equals"] { return value == expected }
        if let expected = query["contains"], case .array(let values) = value { return values.contains(expected) }
        if case .object(let expected)? = query["any"], case .array(let values) = value {
            return values.contains { candidate in
                guard case .object(let object) = candidate else { return false }
                return expected.allSatisfy { object[$0.key] == $0.value }
            }
        }
        throw TutorHostFailure(code: "invalid_detector", message: "The bridge detector has an unsupported query")
    }
}

private struct BlenderBridgeDescriptor: Decodable {
    let protocolVersion: Int
    let bridge: String
    let host: String
    let port: UInt16
    let token: String
    let readOnly: Bool

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case bridge, host, port, token
        case readOnly = "read_only"
    }
}

private final class BlenderBridgeObserver {
    private let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Caches/OpenDesktopTutor", isDirectory: true)

    func observeState() throws -> JSONValue {
        let descriptor = try latestDescriptor()
        let requestID = UUID().uuidString
        let request: [String: JSONValue] = [
            "protocol_version": .number(1),
            "request_id": .string(requestID),
            "token": .string(descriptor.token),
            "operation": .string("observe_state"),
            "payload": .object([:]),
        ]
        let response = try requestLoopback(descriptor: descriptor, request: request)
        guard let object = response.objectValue, object["request_id"]?.stringValue == requestID,
              object["ok"]?.boolValue == true, let result = object["result"] else {
            throw TutorHostFailure(code: "bridge_unavailable", message: "The local read-only bridge returned no valid observation")
        }
        return result
    }

    private func latestDescriptor() throws -> BlenderBridgeDescriptor {
        let manager = FileManager.default
        let files = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasPrefix("blender-") && $0.pathExtension == "json" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return left > right
            }
        guard let path = files.first else {
            throw TutorHostFailure(code: "bridge_unavailable", message: "No active local read-only bridge descriptor exists")
        }
        let attributes = try manager.attributesOfItem(atPath: path.path)
        guard let permission = (attributes[.posixPermissions] as? NSNumber)?.intValue, permission & 0o077 == 0,
              let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue, owner == Int(getuid()),
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0, size <= 8 * 1024 else {
            throw TutorHostFailure(code: "bridge_unavailable", message: "The local bridge descriptor is not owner-only and bounded")
        }
        let descriptor = try JSONDecoder().decode(BlenderBridgeDescriptor.self, from: Data(contentsOf: path, options: .mappedIfSafe))
        guard descriptor.protocolVersion == 1, descriptor.bridge == "blender-tutor-bridge-v1", descriptor.host == "127.0.0.1",
              descriptor.port > 0, descriptor.token.count >= 16, descriptor.readOnly else {
            throw TutorHostFailure(code: "bridge_unavailable", message: "The local bridge descriptor is not a read-only loopback endpoint")
        }
        return descriptor
    }

    private func requestLoopback(descriptor: BlenderBridgeDescriptor, request: [String: JSONValue]) throws -> JSONValue {
        var encoded = try JSONEncoder().encode(request)
        encoded.append(10)
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw TutorHostFailure(code: "bridge_unavailable", message: "Could not open the local bridge socket") }
        defer { close(socketFD) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = descriptor.port.bigEndian
        guard inet_pton(AF_INET, descriptor.host, &address.sin_addr) == 1 else {
            throw TutorHostFailure(code: "bridge_unavailable", message: "The local bridge host is invalid")
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw TutorHostFailure(code: "bridge_unavailable", message: "The local read-only bridge is unavailable") }
        try encoded.withUnsafeBytes { bytes in
            var offset = 0
            while offset < encoded.count {
                let written = Darwin.write(socketFD, bytes.baseAddress!.advanced(by: offset), encoded.count - offset)
                if written < 0 { throw TutorHostFailure(code: "bridge_unavailable", message: "Could not write to the local read-only bridge") }
                offset += written
            }
        }
        var response = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count <= 64 * 1024 {
            let count = read(socketFD, &buffer, buffer.count)
            if count <= 0 { break }
            response.append(buffer, count: count)
            if response.last == 10 { break }
        }
        guard response.count > 0, response.count <= 64 * 1024, response.last == 10 else {
            throw TutorHostFailure(code: "bridge_unavailable", message: "The local read-only bridge returned an invalid response")
        }
        return try JSONDecoder().decode(JSONValue.self, from: response)
    }
}

private func copyElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? value as? String : nil
}

private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? (value as? NSNumber)?.boolValue : nil
}

// AXValue is a CoreFoundation type, so `as?` always succeeds and cannot test the
// payload. Check the CFTypeID, then the AXValue's own type tag.
private func axValueAttribute(_ element: AXUIElement, _ attribute: CFString, _ type: AXValueType) -> AXValue? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = (value as! AXValue)
    return AXValueGetType(axValue) == type ? axValue : nil
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

private func firstWindow(of application: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return nil }
    return windows.first
}

private func descendants(of element: AXUIElement, maxDepth: Int) -> [AXUIElement] {
    guard maxDepth > 0 else { return [] }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let children = value as? [AXUIElement] else { return [] }
    return children + children.flatMap { descendants(of: $0, maxDepth: maxDepth - 1) }
}

/// Drives the overlay renderer, which runs as a separate process.
///
/// AppKit panels never composite from this SwiftUI MenuBarExtra host: they are
/// assigned a window number and report `isVisible`, but nothing reaches the
/// screen. The helper is a plain NSApplication that builds its panels during
/// launch, which is the only arrangement that renders.
@MainActor
final class PointerOverlay {
    static let shared = PointerOverlay()

    private var process: Process?
    private var input: FileHandle?

    /// The overlay renderer is a nested application inside the installed
    /// bundle, and a sibling binary in a build directory. Looking only where the
    /// installer puts it — or only where the build puts it — is why the cursor
    /// did not appear in one arrangement or the other.
    private static func helperURL() -> URL? {
        let bundle = Bundle.main.bundleURL
        let beside = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent()
        let candidates = [
            bundle.appendingPathComponent("Contents/Helpers/CallaOverlayHelper.app/Contents/MacOS/CallaOverlayHelper"),
            bundle.appendingPathComponent("Contents/MacOS/CallaOverlayHelper"),
            beside.appendingPathComponent("CallaOverlayHelper"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func ensureRunning() {
        guard process?.isRunning != true else { return }
        guard let helper = Self.helperURL() else { return }
        let task = Process()
        task.executableURL = helper
        let pipe = Pipe()
        task.standardInput = pipe
        guard (try? task.run()) != nil else { return }
        process = task
        input = pipe.fileHandleForWriting
    }

    private func send(_ command: [String: Any]) {
        ensureRunning()
        guard let input,
              let data = try? JSONSerialization.data(withJSONObject: command) else { return }
        input.write(data)
        input.write(Data([10]))
    }

    /// `frame` and `window` are in screen coordinates with a top-left origin;
    /// the helper owns the conversion to Cocoa's bottom-left origin.
    ///
    /// The window rect and owner travel with every point so the overlay stays
    /// the taught application's overlay: the tooltip is kept inside that
    /// window's bounds, and the whole overlay hides whenever the learner is
    /// looking at something else.
    func point(at frame: CGRect, window: CGRect, owner: String, step: String, text: String, status: String) {
        send(["cmd": "point", "x": frame.midX, "y": frame.midY,
              "window": ["x": window.minX, "y": window.minY,
                         "width": window.width, "height": window.height],
              "owner": owner,
              "dim": TutorSettings.shared.dimNearPointer,
              "cursor_size": TutorSettings.shared.cursorSize,
              "show_hud": TutorSettings.shared.showStatusHUD,
              "step": step, "text": text, "status": status])
    }

    /// Re-word the tooltip in place. The cursor stays where the last step put
    /// it, so a lesson can narrate several beats about one control.
    func narrate(step: String, text: String, status: String, thinking: Bool) {
        send(["cmd": "narrate", "step": step, "text": text, "status": status, "thinking": thinking])
    }

    func hide() {
        send(["cmd": "hide"])
    }
}

// File-scope rather than a static method on UnixSocketServer: see acceptConnection.
private func serveConnection(client: Int32, handler: @Sendable (TutorRequest) async -> TutorResponse) async {
    defer { close(client) }
    do {
        let request = try UnixSocketServer.readRequest(client)
        let response = await handler(request)
        try UnixSocketServer.write(response, to: client)
    } catch {
        let response = TutorResponse(requestID: UUID().uuidString, ok: false, payload: nil,
                                     error: TutorError(code: "protocol_error", message: error.localizedDescription))
        try? UnixSocketServer.write(response, to: client)
    }
}

private final class UnixSocketServer {
    private let path: String
    private let handler: @Sendable (TutorRequest) async -> TutorResponse
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, handler: @escaping @Sendable (TutorRequest) async -> TutorResponse) throws {
        self.path = path
        self.handler = handler
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
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in strncpy(destination, source, byteCount) }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sa_family_t>.size + byteCount))
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno)); close(descriptor)
            throw TutorHostFailure(code: "socket_bind_failed", message: message)
        }
        guard chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            let message = String(cString: strerror(errno)); close(descriptor)
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
        source?.cancel(); source = nil; fileDescriptor = -1; _ = unlink(path)
    }

    private func acceptConnection() {
        let client = accept(fileDescriptor, nil, nil)
        guard client >= 0 else { return }
        // serveConnection is a file-scope function, not a static member: calling a
        // static member of this non-Sendable class from inside a Task makes the
        // region-based isolation checker fail with "pattern that the region-based
        // isolation checker does not understand how to check. Please file a bug."
        let serve = handler
        Task.detached { await serveConnection(client: client, handler: serve) }
    }

    fileprivate static func readRequest(_ descriptor: Int32) throws -> TutorRequest {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maxRequestFrameBytes {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 { throw TutorHostFailure(code: "socket_read_failed", message: String(cString: strerror(errno))) }
            if count == 0 { break }
            data.append(buffer, count: count)
            if data.last == 10 { break }
        }
        guard data.count > 0, data.count <= maxRequestFrameBytes, data.last == 10 else {
            throw TutorHostFailure(code: "frame_limit", message: "TutorHost requires one newline-delimited request under 64 KiB")
        }
        return try JSONDecoder().decode(TutorRequest.self, from: data)
    }

    fileprivate static func write(_ response: TutorResponse, to descriptor: Int32) throws {
        var data = try JSONEncoder().encode(response); data.append(10)
        guard data.count <= maxResponseFrameBytes else { throw TutorHostFailure(code: "frame_limit", message: "TutorHost response exceeds 1.5 MiB") }
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
