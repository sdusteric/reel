import CoreGraphics
import CReelDeps
import Foundation
import ReelCore

/// One PGS or DVD object as a premultiplied BGRA image, positioned on the decoder's canvas.
public struct BitmapSubtitleRect: Sendable {
    public let image: CGImage
    /// Top-left origin, canvas pixels.
    public let rect: PixelRect

    public init(image: CGImage, rect: PixelRect) {
        self.image = image
        self.rect = rect
    }
}

/// A decoded display set: what a PGS or DVD track shows from `start` until `end`, or until the
/// next display set when `end` is nil. No rects means the screen is cleared.
public struct BitmapDisplaySet: Sendable {
    public var start: MediaTime
    public var end: MediaTime?
    public var rects: [BitmapSubtitleRect]
    /// The canvas the rects are positioned on (1920x1080 for BluRay); 0 when unknown.
    public var canvasWidth: Int
    public var canvasHeight: Int

    public init(start: MediaTime, end: MediaTime?, rects: [BitmapSubtitleRect], canvasWidth: Int, canvasHeight: Int) {
        self.start = start
        self.end = end
        self.rects = rects
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }

    public var isClear: Bool { rects.isEmpty }

    /// The union of the rects on the canvas.
    public var bounds: PixelRect? {
        rects.map(\.rect).reduce(nil) { partial, rect in partial.map { $0.union(rect) } ?? rect }
    }
}

/// The display sets of one bitmap track in time order, with the PGS rules for what is visible.
public struct BitmapSubtitleTimeline: Sendable {
    public private(set) var sets: [BitmapDisplaySet] = []

    public init(_ sets: [BitmapDisplaySet] = []) {
        for set in sets { insert(set) }
    }

    /// Adds a display set; one with the same start replaces the earlier one (a re-read after seek).
    public mutating func insert(_ set: BitmapDisplaySet) {
        if let same = sets.firstIndex(where: { $0.start == set.start }) {
            sets[same] = set
            return
        }
        let position = sets.firstIndex { $0.start > set.start } ?? sets.endIndex
        sets.insert(set, at: position)
    }

    /// The display set showing at `time`: the last one starting at or before it, unless it is a
    /// clear or its own end (DVD sets carry one) has passed.
    public func active(at time: MediaTime) -> BitmapDisplaySet? {
        guard let index = sets.lastIndex(where: { $0.start <= time }) else { return nil }
        let set = sets[index]
        if set.isClear { return nil }
        if let end = set.end, time >= end { return nil }
        return set
    }

    /// Drops sets that ended before `time`, keeping the one that may still be showing.
    public mutating func prune(before time: MediaTime) {
        guard let keep = sets.lastIndex(where: { $0.start <= time }) else { return }
        sets.removeFirst(keep)
    }

    public var count: Int { sets.count }
}

/// PAL8 conversion, canvas to video scaling and the lift rule for bitmap tracks (sections 8.1, 8.5).
public enum BitmapSubtitles {
    /// Converts one `AVSubtitleRect` (PAL8 indices in `data[0]`, ARGB palette in `data[1]`) to a
    /// premultiplied BGRA image; the palette is expanded once per rect.
    static func rect(from pointer: UnsafeMutablePointer<AVSubtitleRect>) -> BitmapSubtitleRect? {
        let rect = pointer.pointee
        guard rect.w > 0, rect.h > 0, let indices = rect.data.0 else { return nil }
        let width = Int(rect.w)
        let height = Int(rect.h)
        let bytesPerRow = width * 4
        guard let data = CFDataCreateMutable(nil, bytesPerRow * height) else { return nil }
        CFDataSetLength(data, bytesPerRow * height)
        guard let destination = CFDataGetMutableBytePtr(data) else { return nil }
        let palette = rect.data.1.map { UnsafeRawPointer($0).assumingMemoryBound(to: UInt32.self) }
        reel_expand_pal8(indices, rect.linesize.0, palette, rect.nb_colors, rect.w, rect.h, destination, bytesPerRow)
        guard let image = premultipliedImage(data: data, width: width, height: height, bytesPerRow: bytesPerRow) else { return nil }
        return BitmapSubtitleRect(image: image, rect: PixelRect(x: Int(rect.x), y: Int(rect.y), width: width, height: height))
    }

    /// A CGImage over premultiplied BGRA bytes (little-endian, alpha first).
    static func premultipliedImage(data: CFData, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Where a canvas rect lands in the output: the canvas is scaled to `videoRect` (output pixels,
    /// top-left origin). A zero canvas means the rects are already in video pixels of that size.
    public static func place(_ rect: PixelRect, canvasWidth: Int, canvasHeight: Int, videoRect: PixelRect) -> PixelRect {
        let sourceWidth = canvasWidth > 0 ? canvasWidth : videoRect.width
        let sourceHeight = canvasHeight > 0 ? canvasHeight : videoRect.height
        guard sourceWidth > 0, sourceHeight > 0 else { return rect }
        let scaleX = Double(videoRect.width) / Double(sourceWidth)
        let scaleY = Double(videoRect.height) / Double(sourceHeight)
        let minX = Double(videoRect.x) + Double(rect.x) * scaleX
        let minY = Double(videoRect.y) + Double(rect.y) * scaleY
        let maxX = Double(videoRect.x) + Double(rect.x + rect.width) * scaleX
        let maxY = Double(videoRect.y) + Double(rect.y + rect.height) * scaleY
        return PixelRect(
            x: Int(minX.rounded()),
            y: Int(minY.rounded()),
            width: Int(maxX.rounded()) - Int(minX.rounded()),
            height: Int(maxY.rounded()) - Int(minY.rounded())
        )
    }

    /// The vertical shift (negative is up) that keeps a bitmap above the controller: only a set
    /// whose bounds lie in the bottom third of the frame moves, as one image, so its bottom edge
    /// sits `bottomInset` pixels above the frame bottom.
    public static func liftOffset(bounds: PixelRect, frameHeight: Int, bottomInset: Double?) -> Int {
        guard let bottomInset, bottomInset > 0, frameHeight > 0 else { return 0 }
        guard Double(bounds.y) >= Double(frameHeight) * 2 / 3 else { return 0 }
        let limit = Double(frameHeight) - bottomInset
        let bottom = Double(bounds.y + bounds.height)
        guard bottom > limit else { return 0 }
        return -Int((bottom - limit).rounded(.up))
    }

    /// Every display set of a bitmap stream, read through a private demux of `url`. For tools and
    /// tests; the player reads bitmap packets from its own demuxer instead (they are not prefetched).
    public static func decodeAll(url: URL, streamIndex: Int) throws -> (timeline: BitmapSubtitleTimeline, canvasWidth: Int, canvasHeight: Int) {
        let source = try MediaSource(url: url)
        guard let stream = source.stream(streamIndex) else { throw EngineError.noPlayableStream }
        for index in 0..<source.streamCount where index != streamIndex {
            source.stream(index)?.pointee.discard = AVDISCARD_ALL
        }
        let decoder = try SubtitleDecoder(
            parameters: stream.pointee.codecpar,
            streamIndex: streamIndex,
            timeBase: Rational(stream.pointee.time_base.num, stream.pointee.time_base.den)
        )
        guard decoder.isBitmap else { throw EngineError.unsupportedCodec("\(decoder.codecName) is not a bitmap subtitle codec") }
        var timeline = BitmapSubtitleTimeline()
        while let packet = try source.readPacket() {
            guard packet.streamIndex == streamIndex else { continue }
            do {
                if let set = try decoder.decodeBitmap(packet) { timeline.insert(set) }
            } catch {
                // A damaged display set is skipped; the rest of the track plays (section 8.7).
                continue
            }
        }
        let canvas = decoder.canvasSize
        return (timeline, canvas?.width ?? 0, canvas?.height ?? 0)
    }
}
