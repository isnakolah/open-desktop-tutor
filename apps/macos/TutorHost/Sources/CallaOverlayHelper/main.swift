import AppKit
import CoreImage
import Foundation
import SwiftUI

// Calla's overlay renderer.
//
// This runs as its own plain NSApplication process rather than inside
// TutorHost. The identical AppKit panels never composite from the SwiftUI
// MenuBarExtra host — they report isVisible with a real window number and
// nothing reaches the screen — while they render correctly from a process
// shaped like this one. Keeping the renderer separate also means a hung or
// crashed overlay can never take the socket host down with it.
//
// Protocol: one JSON object per line on stdin.
//   {"cmd":"point","x":123,"y":456,"window":{"x":0,"y":0,"width":1,"height":1},
//    "owner":"com.example.app","step":"Step 1 of 2","text":"...","status":"..."}
//   {"cmd":"narrate","step":"Step 1 of 2","text":"...","status":"...","thinking":true}
//   {"cmd":"hide"}
//   {"cmd":"quit"}
// Coordinates are screen points with a top-left origin, matching what the host
// resolves; the conversion to Cocoa's bottom-left origin happens here.
//
// `window` and `owner` scope the overlay to the application being taught: the
// tooltip is kept inside that window rather than anywhere on the display, and
// everything hides while the learner has some other application in front.

// MARK: - Wallpaper accent

enum Accent {
    /// Average the wallpaper, then force enough saturation and brightness that
    /// the cursor stays legible over any background.
    static func fromWallpaper() -> Color {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = CIImage(contentsOf: url) else { return Color(red: 1, green: 0.58, blue: 0) }
        let extent = image.extent
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: image,
                                                 kCIInputExtentKey: CIVector(cgRect: extent)]),
              let output = filter.outputImage else { return Color(red: 1, green: 0.58, blue: 0) }
        var bitmap = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()])
            .render(output, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let base = NSColor(red: CGFloat(bitmap[0]) / 255, green: CGFloat(bitmap[1]) / 255,
                           blue: CGFloat(bitmap[2]) / 255, alpha: 1)
        guard let hsb = base.usingColorSpace(.deviceRGB) else { return Color(red: 1, green: 0.58, blue: 0) }
        let saturation = max(hsb.saturationComponent, 0.72)
        let brightness = min(max(hsb.brightnessComponent, 0.85), 1.0)
        return Color(nsColor: NSColor(hue: hsb.hueComponent, saturation: saturation,
                                      brightness: brightness, alpha: 1))
    }
}

// MARK: - Cursor

/// Calla's pointer, drawn from `apps/macos/TutorHost/assets/calla-cursor.svg`.
///
/// Authored in the SVG's 512 view box and scaled into whatever rect it is
/// given, so the geometry has exactly one definition. A bare `Path` inside
/// `.frame()` gets centred, which moves the tip by about half a point in each
/// axis; a Shape receives the exact rect, so the tip stays on `hotspot`.
///
/// The corners are rounded by stroking the outline with a round line join over
/// the fill, which is what keeps the radius uniform on the concave notch too.
struct CallaPointerShape: Shape {
    /// Half the round join width, in view-box units.
    static let cornerRadius: CGFloat = 31
    /// The tip, in view-box units, after the round join pushes it outward.
    static let tip = CGPoint(x: 70, y: 58)
    static let viewBox: CGFloat = 512

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / Self.viewBox
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        var p = Path()
        p.move(to: point(100, 90))
        p.addLine(to: point(418, 218))
        p.addLine(to: point(300, 298))
        p.addLine(to: point(240, 418))
        p.closeSubpath()
        return p
    }
}

struct CallaCursor: View {
    /// Kept off the wallpaper accent on purpose: the pointer is Calla's mark,
    /// and it has to stay recognisable on every desktop.
    static let gradient = LinearGradient(
        colors: [Color(red: 0.13, green: 0.83, blue: 1.0), Color(red: 0.0, green: 0.50, blue: 0.94)],
        startPoint: UnitPoint(x: 0.08, y: 0.06), endPoint: UnitPoint(x: 0.86, y: 0.82))
    /// The panel is always built at the largest size a user can pick, because a
    /// rebuilt panel would never composite. Changing the size re-renders the
    /// artwork inside that panel instead.
    static let maxSize: CGFloat = 38
    static let defaultSize: CGFloat = 30

    let size: CGFloat
    let thinking: Bool
    @State private var phase: CGFloat = 0

    private var join: CGFloat {
        CallaPointerShape.cornerRadius * 2 * size / CallaPointerShape.viewBox
    }

    var body: some View {
        ZStack {
            // A white halo under the fill, so the pointer separates from dark
            // and light interfaces alike without an outline that reads as chrome.
            CallaPointerShape()
                .stroke(.white.opacity(0.88),
                        style: StrokeStyle(lineWidth: join + 1.8, lineCap: .round, lineJoin: .round))
            CallaPointerShape()
                .stroke(Self.gradient, style: StrokeStyle(lineWidth: join, lineCap: .round, lineJoin: .round))
            CallaPointerShape().fill(Self.gradient)
        }
        .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
        .frame(width: size, height: size, alignment: .topLeading)
        // Pinned to the panel's top-left so the tip stays on the hotspot
        // whatever size the artwork is drawn at.
        .frame(width: Self.maxSize, height: Self.maxSize, alignment: .topLeading)
        // Thinking reads as a small, organic tilt rather than a spinner.
        .rotationEffect(.degrees(thinking ? Double(sin(phase) * 6) : 0),
                        anchor: UnitPoint(x: CallaPointerShape.tip.x / CallaPointerShape.viewBox,
                                          y: CallaPointerShape.tip.y / CallaPointerShape.viewBox))
        .offset(x: thinking ? sin(phase * 1.3) * 1.6 : 0,
                y: thinking ? cos(phase * 0.9) * 1.2 : 0)
        .onAppear {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                phase = .pi * 4
            }
        }
    }
}

// MARK: - Tooltip

/// The lesson's controls live on the lesson.
///
/// Everything a learner needs mid-step — I did that, a question, stop — is here
/// rather than in a menu or another application. Going somewhere else to say "I
/// finished" means leaving the window being taught, which is the thing this
/// whole design is trying to avoid.
struct CallaTooltip: View {
    let accent: Color
    let step: String
    let text: String
    let thinking: Bool
    var onEvent: ((String, String) -> Void)?

    @State private var asking = false
    @State private var question = ""
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text(step)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if thinking {
                    Text("thinking")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if onEvent != nil { controls }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 300, alignment: .leading)
        .animation(.easeOut(duration: 0.14), value: asking)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(accent.opacity(0.45), lineWidth: 1))
                .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
        )
    }

    @ViewBuilder private var controls: some View {
        if asking {
            HStack(spacing: 6) {
                TextField("Ask Calla…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($questionFocused)
                    .onSubmit(send)
                Button("Send", action: send)
                    .controlSize(.small)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .onAppear { questionFocused = true }
        } else {
            HStack(spacing: 8) {
                pill("Did it", "checkmark") { onEvent?("next", "") }
                pill("Ask", "questionmark") { asking = true }
                Spacer(minLength: 0)
                pill("Stop", "xmark") { onEvent?("stop", "") }
            }
            .padding(.top, 1)
        }
    }

    private func send() {
        let trimmed = question.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onEvent?("ask", trimmed)
        question = ""
        asking = false
    }

    private func pill(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(accent.opacity(0.18)))
            .overlay(Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status HUD

struct StatusHUD: View {
    let accent: Color
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(accent).frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
            Divider().frame(height: 12)
            Text("Pause")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule().fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        )
    }
}

// MARK: - Overlay

@MainActor
final class CallaOverlay {
    static let shared = CallaOverlay()

    private var cursor: NSPanel?
    private var tooltip: NSPanel?
    private var hud: NSPanel?
    private let accent = Accent.fromWallpaper()
    private var thinking = true

    /// The application being taught, and its window in Cocoa coordinates.
    private var owner: String?
    private var window: CGRect?
    /// Whether a step has asked to be on screen, and whether the learner is
    /// currently looking at the taught application. Both must hold to draw.
    private var narrating = false
    private var ownerIsFrontmost = true

    /// How opaque the pointer should be given where the learner's own pointer
    /// is. Panels already ignore mouse events, so Calla never steals a click —
    /// this is about not covering what the learner is trying to look at.
    private var proximityAlpha: CGFloat = 1
    private var tooltipAlpha: CGFloat = 1
    /// Tall enough for two lines and the control row beneath them.
    private let tooltipHeight: CGFloat = 148

    /// The learner pressed something in the tooltip. The host is listening on
    /// this process's stdout, because it owns the connection to Calla.
    private static func emit(_ event: String, _ text: String) {
        let payload: [String: Any] = ["event": event, "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }
    private var pointerWatch: Timer?
    private var dimNearPointer = true
    private var hudEnabled = true
    /// Distance from Calla's pointer at which fading starts and bottoms out.
    private static let fadeBegins: CGFloat = 90
    private static let fadeFloor: CGFloat = 0.35

    /// The size the artwork is currently drawn at, inside a panel that is
    /// always `CallaCursor.maxSize` square.
    private var cursorPointSize = CallaCursor.defaultSize

    /// Local coordinates of the pointer's tip, measured from the panel's
    /// top-left, for the size the artwork is drawn at.
    private var hotspot: CGPoint {
        CGPoint(x: CallaPointerShape.tip.x / CallaPointerShape.viewBox * cursorPointSize,
                y: CallaPointerShape.tip.y / CallaPointerShape.viewBox * cursorPointSize)
    }
    private static let cursorSize = CGSize(width: CallaCursor.maxSize, height: CallaCursor.maxSize)

    /// Panel origin that places the pointer's tip exactly on `point`.
    private func cursorOrigin(for point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - hotspot.x, y: point.y - (Self.cursorSize.height - hotspot.y))
    }

    /// Keep the pointer's tip inside the window being taught.
    ///
    /// A region near an edge, or a window that moved between the observation
    /// and the draw, would otherwise put Calla's cursor on the desktop or on a
    /// neighbouring application — annotating something it is not teaching.
    private func clamped(_ point: CGPoint) -> CGPoint {
        guard let window, window.width > 1, window.height > 1 else { return point }
        return CGPoint(x: min(max(point.x, window.minX + 1), window.maxX - 1),
                       y: min(max(point.y, window.minY + 1), window.maxY - 1))
    }

    /// `.nonactivatingPanel` is load-bearing, not cosmetic. A borderless
    /// `NSPanel` without it belongs to an application that is never frontmost
    /// here, so the window server assigns it a window number, reports
    /// `isVisible`, and still composites nothing. With it the panel renders over
    /// whichever application the learner is actually using.
    private func panel(_ frame: CGRect, interactive: Bool = false) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // Only the tooltip takes clicks, and only because it carries the
        // lesson's controls. A non-activating panel can take them without
        // pulling focus off the application being taught, which is the whole
        // reason the controls can live here at all.
        p.ignoresMouseEvents = !interactive
        // Always true, including for the interactive tooltip. Clearing it makes
        // the panel want key status, and a borderless non-activating panel that
        // wants to be key stops compositing while its own application is
        // inactive — which is always, since Calla never takes focus. The
        // tooltip's buttons still take clicks without it; only the text field
        // needs key status, and it asks for that itself when it appears.
        p.becomesKeyOnlyIfNeeded = true
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }

    /// Build every panel up front, on-screen but fully transparent.
    ///
    /// Two constraints meet here. Panels created after `NSApplication.run()`
    /// begins get a window number and report `isVisible` while never reaching
    /// the screen, so nothing may be constructed lazily later. And a panel first
    /// ordered front while its frame lies outside every display is never added
    /// to the window server's on-screen list — moving it back later does not
    /// re-evaluate that. So they are parked at the centre of the main screen at
    /// `alphaValue` 0 instead of off to one side.
    func prepare() {
        let screen = NSScreen.main!.frame
        let park = CGPoint(x: screen.midX, y: screen.midY)

        // The pointer comes up with the helper and stays up: the helper only
        // runs while Calla is teaching, so a visible pointer is what tells the
        // learner Calla is on. Only the tooltip and the HUD come and go.
        let c = panel(CGRect(origin: park, size: Self.cursorSize))
        c.contentView = NSHostingView(rootView: CallaCursor(size: cursorPointSize, thinking: true))
        c.orderFrontRegardless(); cursor = c

        let t = panel(CGRect(x: park.x, y: park.y, width: 300, height: tooltipHeight), interactive: true)
        t.contentView = NSHostingView(rootView: CallaTooltip(accent: accent, step: "", text: "",
                                                             thinking: false, onEvent: Self.emit))
        t.alphaValue = 0
        t.orderFrontRegardless(); tooltip = t

        let h = panel(CGRect(x: screen.midX - 150, y: screen.minY + 46, width: 300, height: 40))
        h.contentView = NSHostingView(rootView: StatusHUD(accent: accent, text: "Calla"))
        h.alphaValue = 0
        h.orderFrontRegardless(); hud = h

        startPointerWatch()
    }

    func begin(at rawPoint: CGPoint, step: String, text: String, status: String) {
        let point = clamped(rawPoint)
        cursor?.setFrameOrigin(cursorOrigin(for: point))
        tooltip?.setFrame(tooltipFrame(for: point), display: true)
        setThinking(false, step: step, text: text)
        self.status(status)
        narrating = true
        tooltipAlpha = 1
        proximityAlpha = 1
        show()
    }

    /// Scope the overlay to one application, and start following its focus.
    ///
    /// Without this the cursor and tooltip float over the whole desktop,
    /// including whatever the learner switches to next, which reads as Calla
    /// annotating the wrong program.
    func adopt(owner bundleID: String?, window rect: CGRect?) {
        window = rect
        guard owner != bundleID else { return }
        owner = bundleID
        ownerIsFrontmost = bundleID == nil
            || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
        applyVisibility()
    }

    /// The learner brought some other application forward, or came back.
    func frontmostApplicationChanged(to bundleID: String?) {
        guard let owner else { return }
        let isOwner = bundleID == owner
        guard isOwner != ownerIsFrontmost else { return }
        ownerIsFrontmost = isOwner
        applyVisibility()
    }

    /// Panels are ordered front during launch while parked off-screen and fully
    /// transparent, which is the only arrangement that composites at all — but
    /// the window server never adds them to its visible list in that state, and
    /// a later move or alpha change does not re-evaluate it. Ordering front
    /// again once they are positioned and opaque is what actually puts them on
    /// the screen.
    private func show() {
        applyVisibility()
    }

    private func applyVisibility() {
        let visible = ownerIsFrontmost
        cursor?.alphaValue = visible ? proximityAlpha : 0
        tooltip?.alphaValue = visible && narrating ? tooltipAlpha : 0
        hud?.alphaValue = visible && narrating && hudEnabled ? 1 : 0
        guard visible else { return }
        for panel in [cursor, tooltip, hud] { panel?.orderFrontRegardless() }
    }

    /// Fade Calla's pointer as the learner's own pointer nears it.
    ///
    /// Polled rather than event-driven on purpose: a global mouse monitor is
    /// more machinery for the same answer, and polling keeps this feature from
    /// depending on any permission at all, which is the point of the screenshot
    /// path. The timer only does arithmetic while the pointer is on screen.
    private func startPointerWatch() {
        pointerWatch?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { CallaOverlay.shared.updateProximity() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerWatch = timer
    }

    /// Apply the owner's overlay preferences. The panels themselves are never
    /// rebuilt — only what is drawn inside them, and whether the HUD shows.
    func apply(cursorSize: CGFloat?, showHUD: Bool?) {
        if let cursorSize, cursorSize != cursorPointSize {
            cursorPointSize = min(max(cursorSize, 16), CallaCursor.maxSize)
            cursor?.contentView = NSHostingView(rootView: CallaCursor(size: cursorPointSize, thinking: thinking))
        }
        if let showHUD, showHUD != hudEnabled {
            hudEnabled = showHUD
            applyVisibility()
        }
    }

    func setDimNearPointer(_ value: Bool) {
        guard dimNearPointer != value else { return }
        dimNearPointer = value
        if !value, proximityAlpha != 1 {
            proximityAlpha = 1
            applyVisibility()
        }
    }

    func updateProximity() {
        // Re-check who is in front here rather than trusting the activation
        // notification alone. A lesson is normally asked for from somewhere
        // else — Raycast, a chat window — so the first guide lands while the
        // taught application is behind, and the overlay is hidden until the
        // learner switches back. If that one notification is missed, it stays
        // hidden forever and the lesson looks like it never started. Polling
        // what is already a running timer costs nothing and cannot miss.
        frontmostApplicationChanged(to: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

        guard dimNearPointer, ownerIsFrontmost else { return }
        let pointer = NSEvent.mouseLocation

        if let cursor {
            let target = Self.fade(from: pointer, to: cursor.frame, begins: Self.fadeBegins)
            if abs(target - proximityAlpha) > 0.01 {
                proximityAlpha = target
                cursor.alphaValue = target
            }
        }
        // The tooltip is the bigger obstruction, and the learner reaching toward
        // whatever is under it is exactly the moment to get out of the way. It
        // fades on contact rather than on approach, so reading it does not
        // require holding the pointer still somewhere else.
        if let tooltip, narrating {
            let target = Self.fade(from: pointer, to: tooltip.frame, begins: 24)
            if abs(target - tooltipAlpha) > 0.01 {
                tooltipAlpha = target
                tooltip.alphaValue = target
            }
        }
    }

    private static func fade(from pointer: CGPoint, to rect: CGRect, begins: CGFloat) -> CGFloat {
        // Distance from the pointer to the rect, zero inside it.
        let dx = max(rect.minX - pointer.x, 0, pointer.x - rect.maxX)
        let dy = max(rect.minY - pointer.y, 0, pointer.y - rect.maxY)
        let distance = (dx * dx + dy * dy).squareRoot()
        let nearness = max(0, min(1, 1 - distance / begins))
        return 1 - nearness * (1 - fadeFloor)
    }

    /// Place the tooltip beside the cursor, inside the taught window, on
    /// whichever side of it has more room.
    ///
    /// Bounding it by the window rather than the display keeps the narration on
    /// the program being taught instead of spilling onto the desktop. Choosing
    /// the side by where the cursor sits is what stops it from parking on top of
    /// the thing it is describing: pointing at something near the top of the
    /// window pushes the words down, pointing near the bottom pushes them up,
    /// and the same for left and right. A window too small to hold it leaves
    /// nowhere legal to sit, so fall back to the display.
    private func tooltipFrame(for point: CGPoint) -> CGRect {
        let size = CGSize(width: 300, height: tooltipHeight)
        let display = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main!).frame
        var bounds = display
        if let window, window.width >= size.width + 20, window.height >= size.height + 20 {
            bounds = window
        }
        let gap: CGFloat = 26
        // Cocoa's y grows upward, so a cursor high on screen has a large y and
        // wants its words below it, at a smaller y.
        let cursorIsHigh = point.y > bounds.midY
        let cursorIsLeft = point.x < bounds.midX

        var x = cursorIsLeft ? point.x + gap : point.x - gap - size.width
        var y = cursorIsHigh ? point.y - gap - size.height : point.y + gap
        // Whichever side was chosen, it still has to fit; flip back if not.
        if x < bounds.minX + 10 { x = point.x + gap }
        if x + size.width > bounds.maxX - 10 { x = point.x - gap - size.width }
        if y < bounds.minY + 10 { y = point.y + gap }
        if y + size.height > bounds.maxY - 10 { y = point.y - gap - size.height }
        x = min(max(x, bounds.minX + 10), bounds.maxX - size.width - 10)
        y = min(max(y, bounds.minY + 10), bounds.maxY - size.height - 10)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    func move(to rawPoint: CGPoint) {
        let point = clamped(rawPoint)
        cursor?.setFrameOrigin(cursorOrigin(for: point))
        tooltip?.setFrameOrigin(tooltipFrame(for: point).origin)
    }

    func setThinking(_ value: Bool, step: String, text: String) {
        thinking = value
        cursor?.contentView = NSHostingView(rootView: CallaCursor(size: cursorPointSize, thinking: value))
        tooltip?.contentView = NSHostingView(rootView:
            CallaTooltip(accent: accent, step: step, text: text, thinking: value, onEvent: Self.emit))
    }

    /// Puts the narration away and leaves the pointer on screen. Calla is still
    /// active — the helper is still running — so the pointer still belongs
    /// there. `quit` is what ends the session.
    func hide() {
        // Fade out rather than destroy: rebuilt panels would never composite.
        narrating = false
        applyVisibility()
    }

    func status(_ text: String) {
        hud?.contentView = NSHostingView(rootView: StatusHUD(accent: accent, text: text))
    }
}


// MARK: - Command loop

struct WindowRect: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct Command: Decodable {
    let cmd: String
    let x: Double?
    let y: Double?
    let window: WindowRect?
    let owner: String?
    let dim: Bool?
    let cursor_size: Int?
    let show_hud: Bool?
    let step: String?
    let text: String?
    let status: String?
    let thinking: Bool?
}

func cocoa(_ p: CGPoint) -> CGPoint {
    guard let primary = NSScreen.screens.first else { return p }
    return CGPoint(x: p.x, y: primary.frame.height - p.y)
}

/// Top-left-origin screen rect to Cocoa's bottom-left origin.
func cocoa(_ rect: WindowRect) -> CGRect {
    guard let primary = NSScreen.screens.first else {
        return CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
    return CGRect(x: rect.x, y: primary.frame.height - rect.y - rect.height,
                  width: rect.width, height: rect.height)
}

/// Quadratic arc so the cursor sweeps to its target instead of sliding along a
/// ruler, which is far easier for the eye to follow.
func arc(_ from: CGPoint, _ to: CGPoint, _ t: CGFloat) -> CGPoint {
    let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
    let dx = to.x - from.x, dy = to.y - from.y
    let length = max(sqrt(dx * dx + dy * dy), 1)
    let bow = min(length * 0.22, 120)
    let control = CGPoint(x: mid.x - dy / length * bow, y: mid.y + dx / length * bow)
    let inv = 1 - t
    return CGPoint(x: inv * inv * from.x + 2 * inv * t * control.x + t * t * to.x,
                   y: inv * inv * from.y + 2 * inv * t * control.y + t * t * to.y)
}

@MainActor
final class Runner {
    static let shared = Runner()
    private var last: CGPoint?
    private var step = "Calla"
    private var text = ""

    /// Change what the tooltip says without moving the cursor. This is how a
    /// lesson narrates several beats about one control, and how it shows that
    /// the model is still deciding.
    func narrate(step: String?, text: String?, status: String?, thinking: Bool) {
        self.step = step ?? self.step
        self.text = text ?? self.text
        guard let last else { return }
        CallaOverlay.shared.begin(at: last, step: self.step, text: self.text,
                                  status: status ?? "Calla")
        CallaOverlay.shared.setThinking(thinking, step: self.step, text: self.text)
    }

    func point(_ target: CGPoint, step: String, text: String, status: String) {
        self.step = step
        self.text = text
        guard let from = last else {
            CallaOverlay.shared.begin(at: target, step: step, text: text, status: status)
            CallaOverlay.shared.setThinking(false, step: step, text: text)
            last = target
            return
        }
        CallaOverlay.shared.setThinking(true, step: step, text: "Moving to the next control…")
        CallaOverlay.shared.status("Calla — moving")
        let seconds = 0.9
        let frames = Int(seconds * 60)
        for frame in 0...frames {
            let raw = Double(frame) / Double(frames)
            let eased = raw < 0.5 ? 4 * raw * raw * raw : 1 - pow(-2 * raw + 2, 3) / 2
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds * raw) {
                MainActor.assumeIsolated {
                    CallaOverlay.shared.move(to: arc(from, target, CGFloat(eased)))
                    if frame == frames {
                        CallaOverlay.shared.setThinking(false, step: step, text: text)
                        CallaOverlay.shared.status(status)
                    }
                }
            }
        }
        last = target
    }
}

/// Panels must be built inside applicationDidFinishLaunching. Built before
/// `run()` they composite only intermittently, and built later they never
/// composite at all — they get a window number and report isVisible while
/// nothing reaches the screen.
final class OverlayDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { CallaOverlay.shared.prepare() }
        // Follow the learner's attention. NSWorkspace reports this without any
        // Accessibility grant, so scoping the overlay to one application costs
        // no extra permission.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = application?.bundleIdentifier
            MainActor.assumeIsolated { CallaOverlay.shared.frontmostApplicationChanged(to: bundleID) }
        }
    }
}

let app = NSApplication.shared
let delegate = OverlayDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// Read commands off the main thread; apply them on it.
Thread.detachNewThread {
    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8),
              let command = try? JSONDecoder().decode(Command.self, from: data) else { continue }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch command.cmd {
                case "point":
                    guard let x = command.x, let y = command.y else { return }
                    CallaOverlay.shared.setDimNearPointer(command.dim ?? true)
                    CallaOverlay.shared.apply(cursorSize: command.cursor_size.map(CGFloat.init),
                                              showHUD: command.show_hud)
                    CallaOverlay.shared.adopt(owner: command.owner, window: command.window.map(cocoa))
                    Runner.shared.point(cocoa(CGPoint(x: x, y: y)),
                                        step: command.step ?? "Calla",
                                        text: command.text ?? "",
                                        status: command.status ?? "Calla")
                case "narrate":
                    Runner.shared.narrate(step: command.step, text: command.text,
                                          status: command.status, thinking: command.thinking ?? false)
                case "hide":
                    CallaOverlay.shared.hide()
                case "quit":
                    NSApplication.shared.terminate(nil)
                default:
                    break
                }
            }
        }
    }
    // stdin closed: the host is gone, so the overlay should not linger.
    DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
}

app.run()
