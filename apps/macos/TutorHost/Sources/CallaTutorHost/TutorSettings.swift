import AppKit
import Foundation
import ScreenCaptureKit

/// The choices that were previously compiled in.
///
/// Which applications Calla may look at, how much detail leaves this Mac, and
/// how the overlay behaves were all constants in the source. They are the
/// user's decisions, not the build's, so they live here and are surfaced in the
/// menu bar. Everything persists in the host's own preferences domain.
@MainActor
final class TutorSettings: ObservableObject {
    static let shared = TutorSettings()

    /// Applications Calla is permitted to observe. A lesson may narrow this,
    /// never widen it.
    @Published var allowedBundleIDs: [String] {
        didSet { defaults.set(allowedBundleIDs, forKey: Key.allowedBundleIDs) }
    }

    /// Show the overlay only while the application being taught is in front.
    /// Off keeps it on screen wherever the learner goes, which is useful when
    /// following a lesson across two applications.
    @Published var overlayFollowsFocus: Bool {
        didSet { defaults.set(overlayFollowsFocus, forKey: Key.overlayFollowsFocus) }
    }

    /// Hide the tooltip while the learner's own pointer is over it, so it stops
    /// covering what is underneath. The pointer itself never hides.
    @Published var hideTooltipOnHover: Bool {
        didSet { defaults.set(hideTooltipOnHover, forKey: Key.hideTooltipOnHover) }
    }

    // Scoping the overlay to the application being taught is deliberately not a
    // preference. Calla annotating a window it is not teaching is a bug, not a
    // taste, so the overlay is always confined to that window and always hides
    // when the learner looks elsewhere.

    /// Long edge, in pixels, of the window capture sent for a lesson. Smaller
    /// keeps less legible detail off the network; larger helps the model read
    /// small labels.
    @Published var captureLongEdge: Int {
        didSet { defaults.set(captureLongEdge, forKey: Key.captureLongEdge) }
    }

    /// Point size of the pointer Calla draws. Larger is easier to follow on a
    /// dense interface; smaller covers less of it.
    @Published var cursorSize: Int {
        didSet { defaults.set(cursorSize, forKey: Key.cursorSize) }
    }

    /// The small capsule naming what Calla is doing. Useful while learning what
    /// Calla does, noise once that is obvious.
    @Published var showStatusHUD: Bool {
        didSet { defaults.set(showStatusHUD, forKey: Key.showStatusHUD) }
    }

    /// Put the tooltip away when a lesson goes quiet, so an abandoned session
    /// does not leave words on the screen.
    @Published var hideTooltipWhenIdle: Bool {
        didSet { defaults.set(hideTooltipWhenIdle, forKey: Key.hideTooltipWhenIdle) }
    }

    @Published private(set) var screenRecordingGranted = false

    static let captureLongEdgeChoices = [1024, 1600, 2048]
    static let cursorSizeChoices = [24, 30, 38]
    static let defaultAllowedBundleIDs = ["org.blenderfoundation.blender"]

    private let defaults: UserDefaults

    private enum Key {
        static let allowedBundleIDs = "allowedBundleIDs"
        static let hideTooltipOnHover = "hideTooltipOnHover"
        static let overlayFollowsFocus = "overlayFollowsFocus"
        static let captureLongEdge = "captureLongEdge"
        static let cursorSize = "cursorSize"
        static let showStatusHUD = "showStatusHUD"
        static let hideTooltipWhenIdle = "hideTooltipWhenIdle"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.array(forKey: Key.allowedBundleIDs) as? [String]
        allowedBundleIDs = stored?.filter { !$0.isEmpty } ?? Self.defaultAllowedBundleIDs
        // `object(forKey:)` rather than `bool(forKey:)`: an absent preference
        // must mean the shipped default, and bool(forKey:) cannot tell absent
        // from false.
        hideTooltipOnHover = defaults.object(forKey: Key.hideTooltipOnHover) as? Bool ?? true
        overlayFollowsFocus = defaults.object(forKey: Key.overlayFollowsFocus) as? Bool ?? true
        let edge = defaults.object(forKey: Key.captureLongEdge) as? Int ?? 1600
        captureLongEdge = Self.captureLongEdgeChoices.contains(edge) ? edge : 1600
        let size = defaults.object(forKey: Key.cursorSize) as? Int ?? 30
        cursorSize = Self.cursorSizeChoices.contains(size) ? size : 30
        showStatusHUD = defaults.object(forKey: Key.showStatusHUD) as? Bool ?? true
        hideTooltipWhenIdle = defaults.object(forKey: Key.hideTooltipWhenIdle) as? Bool ?? false
    }

    /// Put every choice back to the shipped default, including the allowlist.
    func resetToDefaults() {
        allowedBundleIDs = Self.defaultAllowedBundleIDs
        hideTooltipOnHover = true
        overlayFollowsFocus = true
        captureLongEdge = 1600
        cursorSize = 30
        showStatusHUD = true
        hideTooltipWhenIdle = false
    }

    func openLogs() {
        let logs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Calla")
        NSWorkspace.shared.open(logs)
    }

    /// What a lesson may actually observe: the applications the user allowed,
    /// narrowed by the ones this lesson asked for. A lesson naming an
    /// application the user has not allowed gets nothing.
    func effectiveAllowlist(requested: Set<String>?) -> Set<String> {
        let allowed = Set(allowedBundleIDs)
        guard let requested, !requested.isEmpty else { return allowed }
        return allowed.intersection(requested)
    }

    func allow(bundleID: String) {
        guard !bundleID.isEmpty, !allowedBundleIDs.contains(bundleID) else { return }
        allowedBundleIDs.append(bundleID)
    }

    func disallow(bundleID: String) {
        allowedBundleIDs.removeAll { $0 == bundleID }
    }

    /// The frontmost application, so the user can allow what they are looking
    /// at instead of typing a bundle identifier.
    func frontmostCandidate() -> (name: String, bundleID: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return nil }
        return (app.localizedName ?? bundleID, bundleID)
    }

    func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String else {
            return bundleID
        }
        return name
    }

    func refreshScreenRecordingStatus() async {
        screenRecordingGranted = await WindowCapture.isPermitted()
    }

    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
