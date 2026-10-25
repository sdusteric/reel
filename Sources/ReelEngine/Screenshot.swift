import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import ReelCore
import UniformTypeIdentifiers

/// Cmd+S (design section 9.12, D43): the frame on screen at the video's native size with the
/// subtitle composited, as a PNG named `<stem> <hh-mm-ss>.png` in
/// `ReelEnvironment.screenshotsDirectory`. Silent; the app confirms with the OSD.
public enum Screenshot {
    /// "Northern.Line.S01E02 00-31-04.png" for a frame at 31:04.
    public static func fileName(stem: String, position: MediaTime) -> String {
        let total = max(0, Int(position.seconds.rounded(.down)))
        let clock = String(format: "%02d-%02d-%02d", total / 3_600, total / 60 % 60, total % 60)
        return "\(stem) \(clock).png"
    }

    /// `name` in `directory`, or "<name> 2.png", "<name> 3.png" when taken.
    public static func availableURL(in directory: URL, name: String) -> URL {
        let fileManager = FileManager.default
        var url = directory.appending(path: name, directoryHint: .notDirectory)
        let base = (name as NSString).deletingPathExtension
        var counter = 2
        while fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            url = directory.appending(path: "\(base) \(counter).png", directoryHint: .notDirectory)
            counter += 1
        }
        return url
    }

    /// The frame with `subtitle` (drawn for a frame of the same pixel size) over it, as an sRGB
    /// image. The frame is drawn through ColorSync from the colour space its attachments gave it
    /// (an HDR frame arrives already tone-mapped), and the subtitle after it, at full white.
    public static func compose(frame: CGImage, subtitle: SubtitleBitmap?) -> CGImage? {
        let width = frame.width
        let height = frame.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let subtitle else { return context.makeImage() }
        let rect = subtitle.rect
        // Core Graphics has a bottom-left origin; the subtitle rect is top-left.
        context.draw(subtitle.image, in: CGRect(x: rect.x, y: height - rect.maxY, width: rect.width, height: rect.height))
        return context.makeImage()
    }

    /// Writes a PNG. The image's colour space (sRGB after `compose`) is embedded as an ICC profile.
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw EngineError.io("cannot create \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EngineError.io("cannot write \(url.lastPathComponent)") }
    }

    /// The screenshot image: tone-mapped when HDR, converted to sRGB, subtitle on top.
    public static func image(frame: CVReadOnlyPixelBuffer, subtitle: SubtitleBitmap?) throws -> CGImage {
        let image = try FrameGrabber.image(from: frame)
        guard let composed = compose(frame: image, subtitle: subtitle) else { throw EngineError.io("cannot draw the screenshot") }
        return composed
    }

    /// Converts, composites and writes to `url` exactly (reelctl hdr --screenshot).
    public static func write(frame: CVReadOnlyPixelBuffer, subtitle: SubtitleBitmap?, to url: URL) throws {
        try writePNG(image(frame: frame, subtitle: subtitle), to: url)
    }

    /// Converts, composites and writes; returns the file written.
    public static func save(frame: CVReadOnlyPixelBuffer, subtitle: SubtitleBitmap?, directory: URL, stem: String, position: MediaTime) throws -> URL {
        let composed = try image(frame: frame, subtitle: subtitle)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = availableURL(in: directory, name: fileName(stem: stem, position: position))
        try writePNG(composed, to: url)
        return url
    }
}
