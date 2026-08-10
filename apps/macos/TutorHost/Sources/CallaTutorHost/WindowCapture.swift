import AppKit
import CoreImage
import Foundation
import ScreenCaptureKit

/// Captures a single allowlisted window so a vision model can suggest where a
/// target is.
///
/// Deliberately never captures a display. SECURITY.md requires screenshots to be
/// "in-memory and allowlisted by default", and a full-screen grab would sweep in
/// every other window on the desktop. Nothing here writes to disk.
enum WindowCapture {
    /// Long edge of the encoded image when the user has expressed no
    /// preference. Large enough for a model to read UI labels, small enough to
    /// keep the envelope well inside the frame ceiling.
    static let defaultLongEdge: CGFloat = 1600
    static let jpegQuality = 0.7
    /// Encoded bytes, before base64. Kept under the 64 KiB socket frame limit's
    /// intent by bounding the image itself rather than truncating a frame.
    static let maxEncodedBytes = 3 * 1024 * 1024

    struct Capture {
        let data: Data
        let pixelWidth: Int
        let pixelHeight: Int
        /// Window bounds in Accessibility coordinates, so a normalised hint can
        /// be mapped back onto the screen.
        let windowFrame: CGRect

        var base64: String { data.base64EncodedString() }
    }

    enum Failure: Error {
        case notPermitted
        case noMatchingWindow
        case encodingFailed
    }

    /// True when Screen Recording has been granted. This is a *second* TCC
    /// permission, separate from Accessibility, and is checked without
    /// triggering capture.
    static func isPermitted() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    static func capture(bundleID: String, processID: pid_t, longEdge: CGFloat = defaultLongEdge) async throws -> Capture {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Failure.notPermitted
        }

        // Match on the owning process, not the title: titles are user data and
        // change constantly.
        let candidates = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == bundleID
                && window.owningApplication?.processID == processID
                && window.isOnScreen
                && window.frame.width > 1
                && window.frame.height > 1
        }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw Failure.noMatchingWindow
        }

        let scale = min(1, longEdge / max(window.frame.width, window.frame.height))
        let configuration = SCStreamConfiguration()
        configuration.width = Int((window.frame.width * scale).rounded())
        configuration.height = Int((window.frame.height * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

        guard let data = encodeJPEG(image), data.count <= maxEncodedBytes else {
            throw Failure.encodingFailed
        }
        return Capture(data: data,
                       pixelWidth: image.width,
                       pixelHeight: image.height,
                       windowFrame: window.frame)
    }

    /// A tiny greyscale fingerprint of the window, for noticing that the
    /// learner did something.
    ///
    /// Deliberately far too coarse to read: 32x32 greyscale is enough to see a
    /// panel open or a tab change and nowhere near enough to recover text. It
    /// never leaves this Mac either — only the verdict "this changed" does.
    static func thumbprint(bundleID: String, processID: pid_t) async throws -> [UInt8] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Failure.notPermitted
        }
        let candidates = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == bundleID
                && window.owningApplication?.processID == processID
                && window.isOnScreen && window.frame.width > 1 && window.frame.height > 1
        }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw Failure.noMatchingWindow
        }
        let configuration = SCStreamConfiguration()
        configuration.width = 96
        configuration.height = 96
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw Failure.encodingFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }

    /// Mean absolute difference between two fingerprints, 0...1.
    static func difference(_ left: [UInt8], _ right: [UInt8]) -> Double {
        guard left.count == right.count, !left.isEmpty else { return 1 }
        let total = zip(left, right).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(left.count * 255)
    }

    /// In-memory only: no file is written at any point.
    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }
}
