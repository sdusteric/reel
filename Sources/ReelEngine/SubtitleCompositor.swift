import CoreGraphics
import CReelDeps
import Foundation

/// An integer pixel rectangle with a top-left origin (libass and PGS coordinates).
public struct PixelRect: Sendable, Hashable, Codable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var centerX: Double { Double(x) + Double(width) / 2 }

    public func union(_ other: PixelRect) -> PixelRect {
        let minX = min(x, other.x)
        let minY = min(y, other.y)
        return PixelRect(x: minX, y: minY, width: max(maxX, other.maxX) - minX, height: max(maxY, other.maxY) - minY)
    }

    public func offsetBy(dx: Int = 0, dy: Int = 0) -> PixelRect {
        PixelRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    public var description: String { "(\(x), \(y), \(width)x\(height))" }
}

/// A rendered subtitle: one premultiplied BGRA image and where it goes in the output frame
/// (output pixels, top-left origin). The subtitle layer sets the image as its contents.
public struct SubtitleBitmap: Sendable {
    public var image: CGImage
    public var rect: PixelRect

    public init(image: CGImage, rect: PixelRect) {
        self.image = image
        self.rect = rect
    }
}

/// Blends libass's `ASS_Image` list into one premultiplied BGRA image over the union of the
/// images' rects (section 8.6). `changed == 0` returns the previous image, `changed == 1` with
/// every image moved by the same offset returns it at the new position, anything else re-blends.
///
/// Not thread-safe: used on the renderer's queue.
public final class SubtitleCompositor {
    private struct Placement: Equatable {
        var x: Int32
        var y: Int32
        var width: Int32
        var height: Int32
    }

    private var placements: [Placement] = []
    private var last: SubtitleBitmap?
    /// How many times the image list was blended (for tests of the `changed` rules).
    public private(set) var blendCount = 0

    public init() {}

    /// Forgets the previous image, e.g. after the track or the frame size changed.
    public func reset() {
        placements = []
        last = nil
    }

    public func composite(_ head: UnsafeMutablePointer<ASS_Image>?, changed: Int32) -> SubtitleBitmap? {
        guard let head else {
            reset()
            return nil
        }
        if changed == 0, let last { return last }
        var current: [Placement] = []
        var node: UnsafeMutablePointer<ASS_Image>? = head
        while let image = node {
            let value = image.pointee
            if value.w > 0, value.h > 0 {
                current.append(Placement(x: value.dst_x, y: value.dst_y, width: value.w, height: value.h))
            }
            node = value.next
        }
        guard !current.isEmpty else {
            reset()
            return nil
        }
        if changed == 1, let last, let offset = SubtitleCompositor.uniformOffset(from: placements, to: current) {
            let moved = SubtitleBitmap(image: last.image, rect: last.rect.offsetBy(dx: offset.dx, dy: offset.dy))
            self.last = moved
            placements = current
            return moved
        }
        let bitmap = blend(head, placements: current)
        placements = bitmap == nil ? [] : current
        last = bitmap
        return bitmap
    }

    private static func uniformOffset(from old: [Placement], to new: [Placement]) -> (dx: Int, dy: Int)? {
        guard old.count == new.count, let first = old.first, let firstNew = new.first else { return nil }
        let dx = firstNew.x - first.x
        let dy = firstNew.y - first.y
        for (before, after) in zip(old, new) {
            guard before.width == after.width, before.height == after.height,
                  after.x - before.x == dx, after.y - before.y == dy else { return nil }
        }
        return (Int(dx), Int(dy))
    }

    private func blend(_ head: UnsafeMutablePointer<ASS_Image>, placements: [Placement]) -> SubtitleBitmap? {
        let bounds = placements
            .map { PixelRect(x: Int($0.x), y: Int($0.y), width: Int($0.width), height: Int($0.height)) }
            .dropFirst()
            .reduce(PixelRect(x: Int(placements[0].x), y: Int(placements[0].y), width: Int(placements[0].width), height: Int(placements[0].height))) { $0.union($1) }
        guard !bounds.isEmpty else { return nil }
        let bytesPerRow = bounds.width * 4
        let length = bytesPerRow * bounds.height
        guard let data = CFDataCreateMutable(nil, length) else { return nil }
        // CFDataSetLength zero-fills, so the canvas starts transparent.
        CFDataSetLength(data, length)
        guard let pixels = CFDataGetMutableBytePtr(data) else { return nil }
        var node: UnsafeMutablePointer<ASS_Image>? = head
        while let image = node {
            reel_blend_ass_image(image, pixels, bytesPerRow, Int32(bounds.x), Int32(bounds.y))
            node = image.pointee.next
        }
        blendCount += 1
        guard let image = BitmapSubtitles.premultipliedImage(data: data, width: bounds.width, height: bounds.height, bytesPerRow: bytesPerRow) else {
            return nil
        }
        return SubtitleBitmap(image: image, rect: bounds)
    }
}

/// Ink measurement and preview compositing for rendered subtitles (reelctl subs and tests).
public enum SubtitleInk {
    public struct Measurement: Sendable, Hashable {
        /// Output pixels with alpha above zero.
        public var pixels: Int
        /// Their bounding box in output pixels, top-left origin.
        public var bounds: PixelRect?
    }

    /// Counts the visible pixels of `pieces` (images drawn into their rects, scaled when the sizes
    /// differ), clipped to the frame.
    public static func measure(_ pieces: [(CGImage, PixelRect)], frameWidth: Int, frameHeight: Int) -> Measurement {
        var pixels = 0
        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min
        for (image, rect) in pieces where !rect.isEmpty {
            guard let bytes = rasterize(image, width: rect.width, height: rect.height) else { continue }
            bytes.withUnsafeBufferPointer { buffer in
                for row in 0..<rect.height {
                    let y = rect.y + row
                    guard y >= 0, y < frameHeight else { continue }
                    let base = row * rect.width * 4
                    for column in 0..<rect.width where buffer[base + column * 4 + 3] > 0 {
                        let x = rect.x + column
                        guard x >= 0, x < frameWidth else { continue }
                        pixels += 1
                        minX = min(minX, x)
                        maxX = max(maxX, x)
                        minY = min(minY, y)
                        maxY = max(maxY, y)
                    }
                }
            }
        }
        guard pixels > 0 else { return Measurement(pixels: 0, bounds: nil) }
        return Measurement(pixels: pixels, bounds: PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }

    /// The pieces over a frame of solid grey (0 to 1), or over transparency when `grey` is nil.
    public static func composite(_ pieces: [(CGImage, PixelRect)], frameWidth: Int, frameHeight: Int, grey: Double?) -> CGImage? {
        guard let context = context(width: frameWidth, height: frameHeight) else { return nil }
        if let grey {
            context.setFillColor(CGColor(gray: grey, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
        }
        for (image, rect) in pieces {
            // Core Graphics has a bottom-left origin.
            context.draw(image, in: CGRect(x: rect.x, y: frameHeight - rect.maxY, width: rect.width, height: rect.height))
        }
        return context.makeImage()
    }

    /// Premultiplied BGRA bytes of `image` drawn at `width` x `height`, rows top first.
    static func rasterize(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                  ) else { return false }
            context.interpolationQuality = width == image.width && height == image.height ? .none : .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }
}
