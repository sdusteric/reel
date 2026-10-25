import CoreGraphics
import CoreVideo
import Foundation
import ReelCore
import Testing
@testable import ReelEngine

/// Picture in Picture subtitles on HDR frames (design section 7.7, D52): white is drawn at
/// reference white, 203 nits in PQ (10-bit limited Y 573) and 75% in HLG (Y 721), never the peak.
/// Serialized: run in parallel, its synchronous decode cases filled every cooperative pool
/// thread for the first seconds of `swift test` and held back other suites' timing checks.
@Suite(.serialized) struct PiPCompositeHDRTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var fixture: HDRFixture
        var decoder: VideoDecoderKind
        var testDescription: String { "\(fixture.rawValue) \(decoder.rawValue)" }
    }

    static let cases: [Case] = [HDRFixture.pqHEVCMKV, .hlgHEVCMP4, .pqAV1, .sdrH264].flatMap { fixture in
        [VideoDecoderKind.hardware, .software].map { Case(fixture: fixture, decoder: $0) }
    }

    static func white(width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test(arguments: cases)
    func subtitleWhiteLandsOnReferenceWhite(_ item: Case) throws {
        let ramps = try RampSet.load()
        let ramp = ramps[item.fixture.ramp]
        let expected: Double = switch item.fixture.ramp {
        case .pq: 573
        case .hlg: 721
        case .sdr: 235
        }
        let frame = try FrameGrabber.grab(url: item.fixture.url(), at: .seconds(0.5), decoder: item.decoder).frame
        let black = ramp.patches[0]
        // A subtitle box over the black patch, rendered for a half-size frame (it is scaled).
        let box = PixelRect(x: black.center.x / 2 - 24, y: black.center.y / 2 - 12, width: 48, height: 24)
        let compositor = PiPFrameCompositor()
        let output = compositor.composite(
            frame, subtitle: SubtitleBitmap(image: try Self.white(width: 48, height: 24), rect: box),
            renderedWidth: frame.width / 2, renderedHeight: frame.height / 2
        )
        #expect(compositor.statistics.composited == 1)
        let under = try #require(FrameGrabber.meanCodes(output.pixelBuffer, centerX: black.center.x, centerY: black.center.y, size: 8))
        #expect(abs(under.y - expected) <= 8, "Y under the subtitle is \(under.y), reference white is \(expected)")
        #expect(abs(under.cb - under.cr) <= 8, "white stays neutral: Cb \(under.cb), Cr \(under.cr)")
        // Pixels away from the subtitle are the frame's own.
        for patch in ramp.patches.dropFirst(2) {
            let before = try #require(FrameGrabber.meanCodes(frame.pixelBuffer, centerX: patch.center.x, centerY: patch.center.y))
            let after = try #require(FrameGrabber.meanCodes(output.pixelBuffer, centerX: patch.center.x, centerY: patch.center.y))
            #expect(before == after, "\(patch.name) changed")
        }
        let transfer = output.pixelBuffer.withUnsafeBuffer { HDRToneMapper.transfer(of: $0) }
        #expect(transfer == frame.pixelBuffer.withUnsafeBuffer { HDRToneMapper.transfer(of: $0) })
    }
}
