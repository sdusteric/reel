import CoreGraphics
import CReelDeps
import Foundation
import ReelCore
import Testing
@testable import ReelEngine

@Suite struct BitmapSubtitleTests {
    struct RectLog: Decodable {
        struct Entry: Decodable {
            var start: Double
            var end: Double
            var x: Int
            var y: Int
            var width: Int
            var height: Int
        }

        var canvasWidth: Int
        var canvasHeight: Int
        var rects: [Entry]

        enum CodingKeys: String, CodingKey {
            case canvasWidth = "canvas_width"
            case canvasHeight = "canvas_height"
            case rects
        }
    }

    /// subs_pgs.mkv: video is stream 0, the PGS track stream 1.
    static let pgsStream = 1

    static func rectLog() throws -> RectLog {
        try JSONDecoder().decode(RectLog.self, from: Data(contentsOf: subtitleFixture("logs/pgs_rects.json")))
    }

    @Test func pgsRectsMatchTheFixtureLogWithinTwoPixels() throws {
        let log = try Self.rectLog()
        let decoded = try BitmapSubtitles.decodeAll(url: subtitleFixture("subs_pgs.mkv"), streamIndex: Self.pgsStream)
        #expect(decoded.canvasWidth == log.canvasWidth && decoded.canvasHeight == log.canvasHeight)
        #expect(decoded.timeline.sets.filter { !$0.isClear }.count == log.rects.count)
        let video = PixelRect(x: 0, y: 0, width: 1920, height: 1080)
        for entry in log.rects {
            let set = try #require(decoded.timeline.active(at: .seconds((entry.start + entry.end) / 2)))
            #expect(abs(set.start.seconds - entry.start) < 0.01)
            let rect = try #require(set.rects.first)
            let placed = BitmapSubtitles.place(rect.rect, canvasWidth: set.canvasWidth, canvasHeight: set.canvasHeight, videoRect: video)
            let ink = try #require(SubtitleInk.measure([(rect.image, placed)], frameWidth: 1920, frameHeight: 1080).bounds)
            #expect(abs(ink.x - entry.x) <= 2 && abs(ink.y - entry.y) <= 2, "ink \(ink) vs \(entry)")
            #expect(abs(ink.width - entry.width) <= 2 && abs(ink.height - entry.height) <= 2, "ink \(ink) vs \(entry)")
        }
    }

    @Test func emptyDisplaySetClearsTheScreen() throws {
        let decoded = try BitmapSubtitles.decodeAll(url: subtitleFixture("subs_pgs.mkv"), streamIndex: Self.pgsStream)
        #expect(decoded.timeline.active(at: .seconds(0.5)) == nil)
        #expect(decoded.timeline.active(at: .seconds(2)) != nil)
        #expect(decoded.timeline.active(at: .seconds(3.5)) == nil)
        #expect(decoded.timeline.active(at: .seconds(5)) != nil)
        #expect(decoded.timeline.active(at: .seconds(7)) == nil)
        // PGS sets carry no end time: they last until the next display set.
        #expect(decoded.timeline.sets.allSatisfy { $0.end == nil })
    }

    @Test func explicitEndTimeHidesADisplaySet() throws {
        let image = try Self.solidImage()
        var timeline = BitmapSubtitleTimeline()
        timeline.insert(BitmapDisplaySet(start: .seconds(1), end: .seconds(2), rects: [BitmapSubtitleRect(image: image, rect: PixelRect(x: 0, y: 0, width: 2, height: 2))], canvasWidth: 720, canvasHeight: 480))
        #expect(timeline.active(at: .seconds(1.5)) != nil)
        #expect(timeline.active(at: .seconds(2.5)) == nil)
        // The same start again replaces the set (a re-read after a seek).
        timeline.insert(BitmapDisplaySet(start: .seconds(1), end: nil, rects: [], canvasWidth: 720, canvasHeight: 480))
        #expect(timeline.count == 1)
        #expect(timeline.active(at: .seconds(1.5)) == nil)
    }

    @Test func canvasScalesToTheVideoRect() {
        let video = PixelRect(x: 0, y: 60, width: 1280, height: 600)
        let placed = BitmapSubtitles.place(PixelRect(x: 660, y: 900, width: 600, height: 90), canvasWidth: 1920, canvasHeight: 1080, videoRect: video)
        #expect(placed == PixelRect(x: 440, y: 560, width: 400, height: 50))
        // A DVD canvas of 720x480 fills a 1920x1080 video rect.
        let dvd = BitmapSubtitles.place(PixelRect(x: 0, y: 0, width: 720, height: 480), canvasWidth: 720, canvasHeight: 480, videoRect: PixelRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(dvd == PixelRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    @Test func liftMovesOnlyBitmapsInTheBottomThird() {
        let bottom = PixelRect(x: 660, y: 900, width: 600, height: 90)
        #expect(BitmapSubtitles.liftOffset(bounds: bottom, frameHeight: 1080, bottomInset: nil) == 0)
        #expect(BitmapSubtitles.liftOffset(bounds: bottom, frameHeight: 1080, bottomInset: 200) == -110)
        #expect(BitmapSubtitles.liftOffset(bounds: bottom, frameHeight: 1080, bottomInset: 50) == 0)
        let top = PixelRect(x: 660, y: 100, width: 600, height: 90)
        #expect(BitmapSubtitles.liftOffset(bounds: top, frameHeight: 1080, bottomInset: 200) == 0)
    }

    @Test func paletteExpansionPremultipliesAlpha() {
        let palette: [UInt32] = [0x0000_0000, 0xFFFF_FFFF, 0x80FF_0000, 0xFF00_80FF]
        let indices: [UInt8] = [0, 1, 2, 3, 9]
        var output = [UInt8](repeating: 0xAA, count: indices.count * 4)
        indices.withUnsafeBufferPointer { input in
            palette.withUnsafeBufferPointer { colors in
                output.withUnsafeMutableBufferPointer { out in
                    reel_expand_pal8(input.baseAddress, Int32(indices.count), colors.baseAddress, Int32(palette.count), Int32(indices.count), 1, out.baseAddress, indices.count * 4)
                }
            }
        }
        #expect(Array(output[0..<4]) == [0, 0, 0, 0])
        #expect(Array(output[4..<8]) == [255, 255, 255, 255])
        // Half-transparent red: premultiplied red 128 of 128 alpha.
        #expect(Array(output[8..<12]) == [0, 0, 128, 128])
        #expect(Array(output[12..<16]) == [255, 128, 0, 255])
        // An index past the palette is transparent.
        #expect(Array(output[16..<20]) == [0, 0, 0, 0])
    }

    @Test func pgsDecodedRectHasTheFixtureFrameInk() throws {
        let decoded = try BitmapSubtitles.decodeAll(url: subtitleFixture("subs_pgs.mkv"), streamIndex: Self.pgsStream)
        let set = try #require(decoded.timeline.active(at: .seconds(2)))
        let rect = try #require(set.rects.first)
        #expect(rect.image.width == 600 && rect.image.height == 90)
        let ink = SubtitleInk.measure([(rect.image, rect.rect)], frameWidth: 1920, frameHeight: 1080)
        // The frame and the blocks are opaque, the gaps transparent.
        #expect(ink.pixels > 600 * 6 && ink.pixels < 600 * 90)
        #expect(set.bounds == PixelRect(x: 660, y: 900, width: 600, height: 90))
    }

    /// A 2x2 opaque white image.
    static func solidImage() throws -> CGImage {
        let data = try #require(CFDataCreateMutable(nil, 16))
        CFDataSetLength(data, 16)
        try #require(CFDataGetMutableBytePtr(data)).update(repeating: 255, count: 16)
        return try #require(BitmapSubtitles.premultipliedImage(data: data, width: 2, height: 2, bytesPerRow: 8))
    }
}
