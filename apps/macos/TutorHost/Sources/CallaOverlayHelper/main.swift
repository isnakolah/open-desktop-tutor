import AppKit
import Carbon.HIToolbox
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
//   {"cmd":"plan","steps":["Delete the cube","Add a torus"],"index":0}
//   {"cmd":"locate"}
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
    /// The working ring. Large enough to catch the eye from across a window.
    static let ringSize: CGFloat = 46

    let size: CGFloat
    let thinking: Bool
    @State private var march: CGFloat = 0

    private var join: CGFloat {
        CallaPointerShape.cornerRadius * 2 * size / CallaPointerShape.viewBox
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if thinking { halo }
            pointer
        }
        .frame(width: Self.maxSize + Self.ringSize, height: Self.maxSize + Self.ringSize, alignment: .topLeading)
    }

    private var pointer: some View {
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
        .frame(width: Self.maxSize, height: Self.maxSize, alignment: .topLeading)
    }

    /// Waiting travels around the pointer's own outline.
    ///
    /// A ring floating near the tip was both easy to miss and half-covered by
    /// the tooltip. A dashed margin marching around the arrow itself cannot be
    /// mistaken for anything else on screen, needs no room of its own, and
    /// belongs unmistakably to the pointer rather than sitting beside it.
    private var halo: some View {
        CallaPointerShape()
            .stroke(Self.gradient,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round,
                                       dash: [6, 5], dashPhase: march))
            .frame(width: size, height: size, alignment: .topLeading)
            // Grown from the tip, so the margin sits outside the artwork and the
            // tip itself never appears to move.
            .scaleEffect(1.34, anchor: UnitPoint(x: CallaPointerShape.tip.x / CallaPointerShape.viewBox,
                                                 y: CallaPointerShape.tip.y / CallaPointerShape.viewBox))
            .shadow(color: .black.opacity(0.35), radius: 2)
            .frame(width: Self.maxSize + Self.ringSize, height: Self.maxSize + Self.ringSize,
                   alignment: .topLeading)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    march = -22
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
    /// Bumped by the ⌥⌘/ shortcut to open the question field.
    var startAsking: Int = 0
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
                    Text("working")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            // The route is not listed here. It was, and the tooltip grew tall
            // enough to become the thing in the way — which is the problem this
            // whole overlay is trying not to be. "Step 2 of 5" in the header
            // carries the same shape in four words.
            if thinking { WaitingBar(accent: accent) }
            if onEvent != nil { controls }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 300, alignment: .leading)
        .animation(.easeOut(duration: 0.14), value: asking)
        .onAppear { if startAsking > 0 { asking = true } }
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
                pill("Did it", "⌥⌘↩") { onEvent?("next", "") }
                pill("Ask", "⌥⌘/") { asking = true }
                Spacer(minLength: 0)
                pill("Stop", "⌥⌘.") { onEvent?("stop", "") }
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

    /// The shortcut rides on the button, because a shortcut nobody can see is a
    /// shortcut nobody uses — and the tooltip hides while the pointer is over
    /// it, so the keyboard is the only way to answer it without looking away.
    private func pill(_ title: String, _ shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 11, weight: .medium, design: .rounded))
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(accent.opacity(0.18)))
            .overlay(Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

/// A bar that travels, because waiting should look like it is getting somewhere.
///
/// Dots that fade in turn say "busy" and nothing else. A band sweeping the width
/// of the tooltip is the shape people already read as progress, and it costs one
/// line of the layout rather than a row of its own.
struct WaitingBar: View {
    let accent: Color
    @State private var travelling = false

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(accent)
                .frame(width: geometry.size.width * 0.34)
                .offset(x: travelling ? geometry.size.width * 0.66 : 0)
                .animation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true),
                           value: travelling)
        }
        .frame(height: 2)
        .background(Capsule().fill(accent.opacity(0.18)).frame(height: 2))
        .onAppear { travelling = true }
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

/// A panel that will accept the keyboard.
///
/// Borderless windows refuse key status, so the question field could be shown
/// but never typed into. Non-activating plus this override is the combination
/// that lets the tooltip take keystrokes without yanking the learner out of the
/// application they are being taught.
final class CallaPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay

@MainActor
final class CallaOverlay {
    static let shared = CallaOverlay()

    private var cursor: CallaPanel?
    private var tooltip: CallaPanel?
    private var hud: CallaPanel?
    private let accent = Accent.fromWallpaper()
    private var thinking = true

    /// The application being taught, and its window in Cocoa coordinates.
    private var owner: String?
    private var window: CGRect?
    /// Whether a step has asked to be on screen, and whether the learner is
    /// currently looking at the taught application. Both must hold to draw.
    private var narrating = false
    private var ownerIsFrontmost = true

    /// Where the current step put the cursor. Every decision about the tooltip
    /// is made against this anchor rather than against the panel's live frame,
    /// which is the rule that keeps the behaviour from chasing itself.
    private var lastPoint: CGPoint?
    /// True while the learner's own pointer is over where the tooltip sits.
    private var pointerIsOver = false
    private var askingRequested = 0
    private var currentStep = ""
    private var currentText = ""
    /// The whole route, laid out before the first step. Held so the tooltip can
    /// say which step this is and what follows, without the model having to
    /// repeat itself every call.
    private var plan: [String] = []
    private var planIndex = 0
    /// Two lines and the control row. Fixed: a tooltip that changes height is a
    /// tooltip that moves, and moving is what makes it lose its arrow.
    private let tooltipHeight: CGFloat = 148

    /// The learner pressed something in the tooltip. The host is listening on
    /// this process's stdout, because it owns the connection to Calla.
    static func emit(_ event: String, _ text: String) {
        if event == "ask" { CallaOverlay.shared.askOpen = false }
        let payload: [String: Any] = ["event": event, "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }
    private var pointerWatch: Timer?
    private var hideOnHover = true
    private var followFocus = true
    /// True while the question field is open. Asking necessarily brings Calla
    /// forward so the field can take keystrokes, and the scoping rule would
    /// then read that as the learner leaving and hide the lesson mid-question.
    /// Rather than trying to out-guess which process macOS calls frontmost,
    /// scoping is simply suspended for as long as the field is up.
    private var askOpen = false
    private var hudEnabled = true

    /// The size the artwork is currently drawn at, inside a panel that is
    /// always `CallaCursor.maxSize` square.
    private var cursorPointSize = CallaCursor.defaultSize

    /// Local coordinates of the pointer's tip, measured from the panel's
    /// top-left, for the size the artwork is drawn at.
    private var hotspot: CGPoint {
        CGPoint(x: CallaPointerShape.tip.x / CallaPointerShape.viewBox * cursorPointSize,
                y: CallaPointerShape.tip.y / CallaPointerShape.viewBox * cursorPointSize)
    }
    /// Room for the pointer plus the thinking pulse around its tip.
    private static let cursorSize = CGSize(width: CallaCursor.maxSize + CallaCursor.ringSize,
                                           height: CallaCursor.maxSize + CallaCursor.ringSize)

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
    private func panel(_ frame: CGRect, interactive: Bool = false) -> CallaPanel {
        let p = CallaPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
                                                             thinking: false, startAsking: 0, onEvent: Self.emit))
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
        lastPoint = point
        cursor?.setFrameOrigin(cursorOrigin(for: point))
        tooltip?.setFrame(tooltipFrame(for: point), display: true)
        setThinking(false, step: step, text: text)
        self.status(status)
        let arriving = tooltip?.alphaValue ?? 0 < 0.5
        narrating = true
        askOpen = false
        pointerIsOver = false
        Shortcuts.shared.claim()
        show()
        if arriving {
            tooltip?.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                tooltip?.animator().alphaValue = 1
            }
        }
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

    func frontmostApplicationChanged(to bundleID: String?) {
        // Calla coming forward is not the learner leaving.
        //
        // Asking a question activates this process so the field can take
        // keystrokes, which made the frontmost application Calla — and the
        // scoping rule then hid the whole lesson the instant the shortcut was
        // pressed. Its own windows never count as somewhere else.
        let isOwner = owner == nil || bundleID == owner
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

    /// The overlay belongs to the application being taught.
    ///
    /// It is not drawn over anything else — a pointer floating above an unrelated
    /// window is annotating something Calla knows nothing about. What made this
    /// feel broken before was not the scoping but a missed activation
    /// notification: the overlay would hide and never come back. Frontmost is
    /// polled on the pointer timer now, so that cannot happen.
    private func applyVisibility() {
        // Claim the shortcuts whenever a lesson is up, and give them back when
        // it is not. Claiming only on the first step meant every later step —
        // which takes a different path — ran with no keys registered, and one
        // hide released them for the rest of the session.
        if narrating { Shortcuts.shared.claim() } else { Shortcuts.shared.release() }
        let onScreen = !followFocus || ownerIsFrontmost || askOpen
        cursor?.alphaValue = onScreen ? 1 : 0
        // The tooltip is the only thing that gets out of the way, and it does it
        // by disappearing rather than moving or fading: moving detached the
        // words from the arrow they belong to, and half-transparent text over a
        // busy interface is harder to read than either state.
        tooltip?.alphaValue = onScreen && narrating && !(hideOnHover && pointerIsOver) ? 1 : 0
        hud?.alphaValue = onScreen && narrating && hudEnabled ? 1 : 0
        guard onScreen else { return }
        // Cursor last, so it is on top. The tooltip sits ten points from the
        // tip and the working ring is wider than that, so ordering the pointer
        // first buried the very thing that says Calla is busy. The pointer
        // should never be behind its own words in any case.
        for panel in [tooltip, hud, cursor] { panel?.orderFrontRegardless() }
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

    /// Say where the lesson is, when the learner has lost it.
    ///
    /// A pointer thirty points wide on a large display is easy to miss, and the
    /// tooltip hides itself whenever the learner's own pointer is over it. This
    /// pulses both, in place, without moving the step or disturbing anything.
    func locate() {
        guard let anchor = lastPoint else { return }
        pointerIsOver = false
        applyVisibility()
        for panel in [cursor, tooltip] { panel?.orderFrontRegardless() }
        // Two quick dips in opacity read as "over here" without the overlay
        // jumping around, which would undo the point of pinning it to the step.
        let pulses = 2
        for pulse in 0..<pulses {
            let base = Double(pulse) * 0.34
            DispatchQueue.main.asyncAfter(deadline: .now() + base) {
                MainActor.assumeIsolated { CallaOverlay.shared.flash(to: 0.25) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + base + 0.17) {
                MainActor.assumeIsolated { CallaOverlay.shared.flash(to: 1) }
            }
        }
        status("Calla — here")
        _ = anchor
    }

    private func flash(to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            cursor?.animator().alphaValue = alpha
            if narrating { tooltip?.animator().alphaValue = alpha }
        }
    }

    /// Open the tooltip's question field from a shortcut.
    func beginAsking() {
        FileHandle.standardError.write("[calla] ask requested, narrating=\(narrating)\n".data(using: .utf8)!)
        guard narrating else { return }
        askOpen = true
        applyVisibility()
        askingRequested += 1
        tooltip?.contentView = NSHostingView(rootView:
            CallaTooltip(accent: accent, step: currentStep, text: currentText,
                         thinking: thinking, startAsking: askingRequested, onEvent: Self.emit))
        // Key without activating the app in the Dock sense, so the learner
        // keeps their place; but the process does have to come forward for
        // keystrokes to arrive at all.
        NSApp.activate(ignoringOtherApps: true)
        tooltip?.makeKeyAndOrderFront(nil)
    }

    func setFollowFocus(_ value: Bool) {
        guard followFocus != value else { return }
        followFocus = value
        applyVisibility()
    }

    func setHideOnHover(_ value: Bool) {
        guard hideOnHover != value else { return }
        hideOnHover = value
        // Switching it off must reveal the tooltip immediately, not at the next
        // time the pointer happens to move.
        if !value { pointerIsOver = false }
        applyVisibility()
    }

    func updateProximity() {
        // Re-check who is in front here rather than trusting the activation
        // notification alone. A lesson is normally asked for from somewhere
        // else — Raycast, a chat window — so the first guide lands while the
        // taught application is behind. If that one notification is missed the
        // overlay would never come back. Polling a timer that already runs
        // costs nothing and cannot miss.
        // Calla coming forward is not the learner leaving. Asking a question
        // activates this process so the field can take keystrokes, and the
        // scoping rule would otherwise hide the whole lesson the instant the
        // shortcut was pressed. Compared by process, not bundle id, because the
        // renderer is a nested helper and its identifier is easy to get wrong.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != NSRunningApplication.current.processIdentifier {
            frontmostApplicationChanged(to: front.bundleIdentifier)
        }

        // Hide the tooltip while the learner's pointer is over it.
        //
        // The test is against the anchor's rect, never the panel's live frame.
        // That is the whole trick. Every earlier version tested against
        // something the behaviour itself changed — a frame mid-animation, or a
        // position that had just dodged — so acting on the answer changed the
        // answer, and it shook or ping-ponged. Hiding moves nothing and resizes
        // nothing, so this test cannot be disturbed by its own result.
        guard hideOnHover, narrating, let anchor = lastPoint else { return }
        let over = tooltipFrame(for: anchor).insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
        guard over != pointerIsOver else { return }
        pointerIsOver = over
        NSAnimationContext.runAnimationGroup { context in
            // Long enough to read as the tooltip getting out of the way rather
            // than blinking out, short enough not to be in the way while it does.
            context.duration = over ? 0.16 : 0.22
            context.timingFunction = CAMediaTimingFunction(name: over ? .easeIn : .easeOut)
            tooltip?.animator().alphaValue = over ? 0 : 1
        }
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
    /// Every place the words could legally sit, best first.
    ///
    /// Four corners around the cursor, ordered so the first is the side of the
    /// window with more room — pointing near the top pushes the words down,
    /// near the bottom pushes them up. `avoiding` re-sorts them by distance
    /// from the learner's own pointer, which is how the tooltip steps aside
    /// instead of fading.
    private func tooltipSlots(for point: CGPoint) -> [CGRect] {
        let size = CGSize(width: 300, height: tooltipHeight)
        let display = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main!).frame
        var bounds = display
        if let window, window.width >= size.width + 20, window.height >= size.height + 20 {
            bounds = window
        }
        // Close enough to read as one object with the pointer. Far enough not
        // to cover what the pointer is indicating.
        let gap: CGFloat = 10
        // Cocoa's y grows upward, so a cursor high on screen has a large y and
        // wants its words below it, at a smaller y.
        // Down and to the right of the tip first, every time. A tooltip that
        // picks a different corner each step stops looking attached to the
        // arrow, which is the only thing telling the learner the words and the
        // pointer are one object. Cocoa's y grows upward, so "below" is the
        // smaller y. The other three corners are fallbacks for when it does not
        // fit, and targets for stepping aside.
        let xs = [point.x + gap, point.x - gap - size.width]
        let ys = [point.y - gap - size.height, point.y + gap]

        var slots: [CGRect] = []
        for y in ys {
            for x in xs {
                let clampedX = min(max(x, bounds.minX + 10), bounds.maxX - size.width - 10)
                let clampedY = min(max(y, bounds.minY + 10), bounds.maxY - size.height - 10)
                slots.append(CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: size))
            }
        }
        return slots
    }

    private func tooltipFrame(for point: CGPoint) -> CGRect {
        tooltipSlots(for: point)[0]
    }


    /// Slide the pointer and its words to the next step together.
    func glide(from: CGPoint, to rawPoint: CGPoint, duration: TimeInterval) {
        let point = clamped(rawPoint)
        lastPoint = point
        // Clearing the flag is not enough on its own: the alpha is where the
        // last hide left it, so a step that began while the learner's pointer
        // happened to be over the old position would arrive invisible.
        pointerIsOver = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if narrating { tooltip?.animator().alphaValue = 1 }
            // setFrame, not setFrameOrigin: the animator proxy ignores
            // setFrameOrigin on a window, so animating that way moved the
            // tooltip and left the pointer standing where it was.
            if let cursor {
                cursor.animator().setFrame(
                    CGRect(origin: cursorOrigin(for: point), size: cursor.frame.size),
                    display: true)
            }
            tooltip?.animator().setFrame(tooltipFrame(for: point), display: true)
        }
    }

    func move(to rawPoint: CGPoint) {
        let point = clamped(rawPoint)
        lastPoint = point
        cursor?.setFrameOrigin(cursorOrigin(for: point))
        tooltip?.setFrameOrigin(tooltipFrame(for: point).origin)
    }

    /// Take the route the model worked out, keeping what the learner has done.
    ///
    /// A re-plan is a correction to what is left, not a rewrite of what
    /// happened. Steps already completed stay exactly as they were and in the
    /// order they were done, so the count never goes backwards and the learner
    /// never sees a step they finished turn into a different one. The model can
    /// add, drop or reword anything ahead of where they are.
    func setPlan(_ steps: [String], index: Int) {
        let completed = Array(plan.prefix(planIndex))
        let ahead = steps.filter { !completed.contains($0) }
        plan = plan.isEmpty ? steps : completed + ahead
        let wanted = index >= 0 ? index : planIndex
        planIndex = max(completed.count, min(wanted, max(plan.count - 1, 0)))
        setThinking(thinking, step: currentStep, text: currentText)
        // The panel has to grow to hold the list; do it where the plan changes,
        // never on a timer, so no feedback loop can form.
        if let anchor = lastPoint { tooltip?.setFrame(tooltipFrame(for: anchor), display: true) }
    }

    /// Where the lesson is in that route: "Step 2 of 5" beats a bare label,
    /// because it tells the learner how much is left.
    private var progressLabel: String {
        guard plan.count > 1 else { return currentStep }
        return "Step \(planIndex + 1) of \(plan.count)"
    }

    private var upcomingStep: String? {
        guard planIndex + 1 < plan.count else { return nil }
        return plan[planIndex + 1]
    }

    /// Move the lesson to a planned step.
    ///
    /// A negative index means "no opinion" — the host sends that when a guide
    /// carries no step_index, and clamping it to zero is what made the counter
    /// snap back to Step 1 on every step that forgot to say where it was.
    func advancePlan(to index: Int?) {
        guard let index, index >= 0, !plan.isEmpty else { return }
        planIndex = max(0, min(index, plan.count - 1))
    }

    func setThinking(_ value: Bool, step: String, text: String) {
        thinking = value
        currentStep = step
        currentText = text
        cursor?.contentView = NSHostingView(rootView: CallaCursor(size: cursorPointSize, thinking: value))
        tooltip?.contentView = NSHostingView(rootView:
            CallaTooltip(accent: accent, step: plan.count > 1 ? progressLabel : step,
                         text: text, thinking: value,
                         startAsking: askingRequested, onEvent: Self.emit))
    }

    /// Puts the narration away and leaves the pointer on screen. Calla is still
    /// active — the helper is still running — so the pointer still belongs
    /// there. `quit` is what ends the session.
    /// End the lesson gently.
    ///
    /// Cutting the alpha to zero in one frame reads as the overlay being
    /// yanked, which makes a finished lesson feel like a crash. A short fade,
    /// and the pointer leaving last, gives it an ending.
    func hide() {
        narrating = false
        Shortcuts.shared.release()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            tooltip?.animator().alphaValue = 0
            hud?.animator().alphaValue = 0
        }
    }

    func status(_ text: String) {
        hud?.contentView = NSHostingView(rootView: StatusHUD(accent: accent, text: text))
    }
}


// MARK: - Shortcuts

/// Answering Calla without touching the tooltip.
///
/// The tooltip moves out from under the learner's pointer, which makes it a
/// poor thing to have to click, and reaching for it means leaving whatever they
/// were doing anyway. These are system-wide hot keys.
///
/// Carbon's RegisterEventHotKey rather than an NSEvent global monitor on
/// purpose: a global keyboard monitor needs Accessibility, and the whole point
/// of this path is that it needs nothing but Screen Recording.
@MainActor
final class Shortcuts {
    static let shared = Shortcuts()

    /// ⌥⌘⏎ did it · ⌥⌘/ ask · ⌥⌘. stop
    private static let bindings: [(id: UInt32, key: Int, event: String, label: String)] = [
        (1, kVK_Return, "next", "⌥⌘↩"),
        (2, kVK_ANSI_Slash, "ask", "⌥⌘/"),
        (3, kVK_ANSI_Period, "stop", "⌥⌘."),
    ]

    private var installed = false
    private var registered: [EventHotKeyRef] = []
    /// Combos another application already owns. Reported rather than silently
    /// swallowed, because a shortcut that does nothing is worse than none.
    private(set) var unavailable: [String] = []

    func install(onEvent: @escaping (String) -> Void) {
        guard !installed else { return }
        installed = true
        self.onEvent = onEvent

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let id = pressed.id
            DispatchQueue.main.async { MainActor.assumeIsolated { Shortcuts.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)

    }

    /// Hold the keys only while a lesson is on screen.
    ///
    /// A system-wide hot key outranks the application underneath it, so holding
    /// these all the time would quietly take three combinations away from every
    /// program on the Mac — including the one being taught. Claiming them only
    /// while the tooltip is up means a collision can last as long as a lesson
    /// and no longer.
    func claim() {
        guard installed, registered.isEmpty else { return }
        unavailable = []
        let modifiers = UInt32(optionKey | cmdKey)
        note("claiming shortcuts")
        for binding in Self.bindings {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(binding.key), modifiers,
                EventHotKeyID(signature: OSType(0x43414C41), id: binding.id),
                GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                registered.append(reference)
            } else {
                unavailable.append(binding.label)
            }
        }
        note("claimed \(registered.count) of \(Self.bindings.count)"
             + (unavailable.isEmpty ? "" : "; unavailable: \(unavailable.joined(separator: " "))"))
        if !unavailable.isEmpty {
            CallaOverlay.emit("shortcuts_unavailable", unavailable.joined(separator: " "))
        }
    }

    /// Calla's own log line. stdout belongs to the host's command channel, so
    /// anything diagnostic has to go to stderr.
    private func note(_ message: String) {
        FileHandle.standardError.write("[calla] \(message)\n".data(using: .utf8)!)
    }

    func release() {
        for reference in registered { UnregisterEventHotKey(reference) }
        registered = []
    }

    private var onEvent: ((String) -> Void)?

    fileprivate func fire(_ id: UInt32) {
        guard let binding = Self.bindings.first(where: { $0.id == id }) else { return }
        // Logged because whether a hot key arrives cannot be observed from
        // outside the process: macOS lets several applications register the
        // same combination, so a successful registration proves nothing.
        note("hotkey \(binding.label) -> \(binding.event)")
        if binding.event == "ask" {
            CallaOverlay.shared.beginAsking()
        } else {
            onEvent?(binding.event)
        }
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
    let hide_on_hover: Bool?
    let follow_focus: Bool?
    let steps: [String]?
    let index: Int?
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
        // One Core Animation run rather than sixty dispatched frames. The old
        // arc was drawn by scheduling a setFrameOrigin per frame, and anything
        // else happening on the main thread showed up as a stutter; handing the
        // whole move to the animator keeps it smooth and costs one call.
        CallaOverlay.shared.setThinking(true, step: step, text: "Moving to the next control…")
        CallaOverlay.shared.status("Calla — moving")
        let seconds = 0.5
        CallaOverlay.shared.glide(from: from, to: target, duration: seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                CallaOverlay.shared.setThinking(false, step: step, text: text)
                CallaOverlay.shared.status(status)
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
        MainActor.assumeIsolated {
            CallaOverlay.shared.prepare()
            Shortcuts.shared.install { event in CallaOverlay.emit(event, "") }
        }
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
                    CallaOverlay.shared.advancePlan(to: command.index)
                    CallaOverlay.shared.setHideOnHover(command.hide_on_hover ?? true)
                    CallaOverlay.shared.setFollowFocus(command.follow_focus ?? true)
                    CallaOverlay.shared.apply(cursorSize: command.cursor_size.map(CGFloat.init),
                                              showHUD: command.show_hud)
                    CallaOverlay.shared.adopt(owner: command.owner, window: command.window.map(cocoa))
                    Runner.shared.point(cocoa(CGPoint(x: x, y: y)),
                                        step: command.step ?? "Calla",
                                        text: command.text ?? "",
                                        status: command.status ?? "Calla")
                case "plan":
                    CallaOverlay.shared.setPlan(command.steps ?? [], index: command.index ?? 0)
                case "locate":
                    CallaOverlay.shared.locate()
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
