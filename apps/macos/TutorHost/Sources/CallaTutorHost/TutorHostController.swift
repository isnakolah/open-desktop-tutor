import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI
import TutorProtocol

private let allowlistedBundleIDs: Set<String> = ["org.blenderfoundation.blender"]
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
        guard request.sessionID.count >= 8 else { return failure(request, "invalid_session", "A valid teaching session is required") }
        guard captureActive else { return failure(request, "capture_paused", "Capture is paused locally") }
        do {
            try validateMacIngress(operation: request.operation, payload: request.payload)
            let payload: [String: JSONValue]
            switch request.operation {
            case "observe": payload = try engine.observe(request.payload)
            case "point": payload = try engine.point(request.payload)
            case "propose_action": payload = try await proposeAction(request.payload)
            case "verify": payload = try engine.verify(request.payload)
            default: return failure(request, "unsupported_operation", "This TutorHost accepts observe, point, propose_action, and verify only")
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
    if let path = macForbiddenCoordinatePath(.object(payload), path: "payload", permitNormalizedHint: operation == "point") {
        throw TutorHostFailure(code: "invalid_coordinates", message: "Raw coordinate field \(path) is forbidden")
    }
}

private func macForbiddenCoordinatePath(_ value: JSONValue, path: String, permitNormalizedHint: Bool) -> String? {
    switch value {
    case .object(let object):
        for (key, child) in object {
            let next = "\(path).\(key)"
            if permitNormalizedHint && path == "payload.target_hint" && key == "region" { continue }
            if forbiddenCoordinateKeys.contains(key.lowercased()) { return next }
            if let found = macForbiddenCoordinatePath(child, path: next, permitNormalizedHint: permitNormalizedHint) { return found }
        }
    case .array(let values):
        for (index, child) in values.enumerated() {
            if let found = macForbiddenCoordinatePath(child, path: "\(path).\(index)", permitNormalizedHint: permitNormalizedHint) { return found }
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
    private let bridgeObserver = BlenderBridgeObserver()

    func observe(_ payload: [String: JSONValue]) throws -> [String: JSONValue] {
        let focused = try focusedAllowlistedApplication()
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
                let jpeg = try captureFocusedWindow(snapshot)
                result["capture"] = .object([
                    "snapshot_id": .string(snapshot.id),
                    "mime_type": .string("image/jpeg"),
                    "base64": .string(jpeg.base64EncodedString()),
                ])
            }
        }
        return result
    }

    func point(_ payload: [String: JSONValue]) throws -> [String: JSONValue] {
        let target = try resolveFreshTarget(payload, authority: .point, allowHint: true)
        var label: String?
        if case .string(let value)? = payload["label"] { label = value }
        var step = "Calla"
        if case .string(let value)? = payload["step"] { step = value }
        PointerOverlay.shared.show(at: target.frame, step: step, label: label)
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
        let focused = try focusedAllowlistedApplication()
        let fresh = try makeSnapshot(for: focused)
        guard fresh.processID == prior.processID, fresh.windowID == prior.windowID, fresh.windowFrame.equalTo(prior.windowFrame) else {
            throw TutorHostFailure(code: "changed_window", message: "The focused allowlisted window changed after observation")
        }
        let target = try resolve(descriptor: descriptor, in: focused.element, snapshot: fresh, hint: hint)
        let threshold = authority == .action ? descriptor.actionMinimumConfidence : descriptor.pointMinimumConfidence
        guard target.confidence >= threshold else {
            throw TutorHostFailure(code: "unresolved", message: "Local descriptor evidence did not meet the authored confidence threshold")
        }
        return target
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
        guard case .object(let hint) = value, Set(hint.keys) == Set(["region"]),
              case .object(let region)? = hint["region"], Set(region.keys) == Set(["left", "top", "width", "height"]),
              let left = region["left"]?.numberValue, let top = region["top"]?.numberValue,
              let width = region["width"]?.numberValue, let height = region["height"]?.numberValue else {
            throw TutorHostFailure(code: "invalid_target_hint", message: "target_hint must contain one normalized region only")
        }
        do { return try NormalizedRegion(left: left, top: top, width: width, height: height) }
        catch let error as DescriptorValidationError { throw TutorHostFailure(code: "invalid_target_hint", message: error.message) }
    }

    private func focusedAllowlistedApplication() throws -> FocusedApplication {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier,
              allowlistedBundleIDs.contains(bundleID) else {
            throw TutorHostFailure(code: "app_not_allowed", message: "An allowlisted application must be focused")
        }
        return FocusedApplication(application: app, element: AXUIElementCreateApplication(app.processIdentifier))
    }

    private func makeSnapshot(for focused: FocusedApplication) throws -> Snapshot {
        guard let window = copyElementAttribute(focused.element, kAXFocusedWindowAttribute as CFString) else {
            throw TutorHostFailure(code: "no_focused_window", message: "The focused allowlisted application has no focused window")
        }
        let frame = try frameAttribute(window)
        let windowID = try focusedWindowID(processID: focused.application.processIdentifier, frame: frame)
        let version = focused.application.bundleURL.flatMap {
            Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        } ?? "unknown"
        return Snapshot(processID: focused.application.processIdentifier, windowID: windowID, windowFrame: frame, appBundleID: focused.application.bundleIdentifier ?? "unknown", appVersion: version)
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

    private func captureFocusedWindow(_ snapshot: Snapshot) throws -> Data {
        guard let image = CGWindowListCreateImage(.null, [.optionIncludingWindow], snapshot.windowID, [.boundsIgnoreFraming]) else {
            throw TutorHostFailure(code: "capture_failed", message: "The focused allowlisted window could not be captured")
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        for compression in [0.82, 0.68, 0.52, 0.36] {
            if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression]), data.count <= maxCaptureJPEGBytes {
                return data
            }
        }
        throw TutorHostFailure(code: "capture_too_large", message: "The focused window JPEG exceeds the in-memory capture limit")
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

private func descendants(of element: AXUIElement, maxDepth: Int) -> [AXUIElement] {
    guard maxDepth > 0 else { return [] }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let children = value as? [AXUIElement] else { return [] }
    return children + children.flatMap { descendants(of: $0, maxDepth: maxDepth - 1) }
}

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

/// A distinct AI cursor plus a tooltip saying what to do. AppKit windows are
/// main-actor only and every call site is the @MainActor controller.
@MainActor
private final class PointerOverlay {
    static let shared = PointerOverlay()
    static let tooltipSize = CGSize(width: 300, height: 96)

    private var panels: [NSWindow] = []

    /// `frame` is in Accessibility coordinates (top-left origin).
    func show(at frame: CGRect, step: String = "Calla", label: String? = nil) {
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
    /// windows use a bottom-left origin. Without this flip the overlay is drawn
    /// mirrored about the horizontal axis of the display.
    private static func cocoaRect(fromAccessibility frame: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return frame }
        return CGRect(x: frame.origin.x,
                      y: primary.frame.height - frame.origin.y - frame.height,
                      width: frame.width, height: frame.height)
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
        path.withCString { source in
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
