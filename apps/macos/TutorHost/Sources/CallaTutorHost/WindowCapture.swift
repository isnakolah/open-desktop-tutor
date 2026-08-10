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
    /// Long edge of the encoded image. Large enough for a model to read UI
    /// labels, small enough to keep the envelope well inside the frame ceiling.
    static let maxLongEdge: CGFloat = 1600
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

    static func capture(bundleID: String, processID: pid_t) async throws -> Capture {
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

        let scale = min(1, maxLongEdge / max(window.frame.width, window.frame.height))
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

    /// In-memory only: no file is written at any point.
    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }
}
