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
    static let size = CGSize(width: 30, height: 30)

    let thinking: Bool
    @State private var phase: CGFloat = 0

    private var join: CGFloat {
        CallaPointerShape.cornerRadius * 2 * Self.size.width / CallaPointerShape.viewBox
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
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
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

struct CallaTooltip: View {
    let accent: Color
    let step: String
    let text: String
    let thinking: Bool

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(accent.opacity(0.45), lineWidth: 1))
                .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
        )
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
    private var pointerWatch: Timer?
    /// Distance from Calla's pointer at which fading starts and bottoms out.
    private static let fadeBegins: CGFloat = 90
    private static let fadeFloor: CGFloat = 0.12

    /// Local coordinates of the pointer's tip inside its own view.
    private static let hotspot = CGPoint(
        x: CallaPointerShape.tip.x / CallaPointerShape.viewBox * CallaCursor.size.width,
        y: CallaPointerShape.tip.y / CallaPointerShape.viewBox * CallaCursor.size.height)
    private static let cursorSize = CallaCursor.size

    /// Panel origin that places the arrow tip exactly on `point`.
    private static func cursorOrigin(for point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - hotspot.x, y: point.y - (cursorSize.height - hotspot.y))
    }

    /// `.nonactivatingPanel` is load-bearing, not cosmetic. A borderless
    /// `NSPanel` without it belongs to an application that is never frontmost
    /// here, so the window server assigns it a window number, reports
    /// `isVisible`, and still composites nothing. With it the panel renders over
    /// whichever application the learner is actually using.
    private func panel(_ frame: CGRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true       // the user's pointer keeps every click
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
        c.contentView = NSHostingView(rootView: CallaCursor(thinking: true))
        c.orderFrontRegardless(); cursor = c

        let t = panel(CGRect(x: park.x, y: park.y, width: 300, height: 100))
        t.contentView = NSHostingView(rootView: CallaTooltip(accent: accent, step: "", text: "", thinking: false))
        t.alphaValue = 0
        t.orderFrontRegardless(); tooltip = t

        let h = panel(CGRect(x: screen.midX - 150, y: screen.minY + 46, width: 300, height: 40))
        h.contentView = NSHostingView(rootView: StatusHUD(accent: accent, text: "Calla"))
        h.alphaValue = 0
        h.orderFrontRegardless(); hud = h

        startPointerWatch()
    }

    func begin(at point: CGPoint, step: String, text: String, status: String) {
        cursor?.setFrameOrigin(Self.cursorOrigin(for: point))
        tooltip?.setFrame(tooltipFrame(for: point), display: true)
        setThinking(false, step: step, text: text)
        self.status(status)
        narrating = true
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
        for panel in [tooltip, hud] { panel?.alphaValue = visible && narrating ? 1 : 0 }
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

    func updateProximity() {
        guard ownerIsFrontmost, let cursor else { return }
        let pointer = NSEvent.mouseLocation
        let rect = cursor.frame
        // Distance from the point to the pointer's own rect, zero inside it.
        let dx = max(rect.minX - pointer.x, 0, pointer.x - rect.maxX)
        let dy = max(rect.minY - pointer.y, 0, pointer.y - rect.maxY)
        let distance = (dx * dx + dy * dy).squareRoot()
        let nearness = max(0, min(1, 1 - distance / Self.fadeBegins))
        let target = 1 - nearness * (1 - Self.fadeFloor)
        guard abs(target - proximityAlpha) > 0.01 else { return }
        proximityAlpha = target
        cursor.alphaValue = target
    }

    /// Place the tooltip beside the cursor and inside the taught window.
    ///
    /// Bounding it by the window rather than the display is what keeps the
    /// narration on the program being taught instead of spilling onto the
    /// desktop or a neighbouring application. A window narrower than the
    /// tooltip would leave nowhere legal to sit, so fall back to the display.
    private func tooltipFrame(for point: CGPoint) -> CGRect {
        let size = CGSize(width: 300, height: 100)
        let display = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main!).frame
        var bounds = display
        if let window, window.width >= size.width + 20, window.height >= size.height + 20 {
            bounds = window
        }
        var x = point.x + 28
        if x + size.width > bounds.maxX - 10 { x = point.x - 28 - size.width }
        x = min(max(x, bounds.minX + 10), bounds.maxX - size.width - 10)
        let y = min(max(point.y - size.height - 4, bounds.minY + 10), bounds.maxY - size.height - 10)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    func move(to point: CGPoint) {
        cursor?.setFrameOrigin(Self.cursorOrigin(for: point))
        tooltip?.setFrameOrigin(tooltipFrame(for: point).origin)
    }

    func setThinking(_ value: Bool, step: String, text: String) {
        thinking = value
        cursor?.contentView = NSHostingView(rootView: CallaCursor(thinking: value))
        tooltip?.contentView = NSHostingView(rootView:
            CallaTooltip(accent: accent, step: step, text: text, thinking: value))
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
