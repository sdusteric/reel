import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import ReelCore
import ReelEngine
import Synchronization

/// `reelctl hdr <file> [--decoder hw|sw] [--display sdr|xdr|external|headroom=X] [--display-headroom X]
/// [--setting full|limited|off] [--screenshot png] [--thumbnail] --json` (section 7.7).
///
/// Decodes one frame of a patch ramp (build/fixtures/hdr, rectangles from logs/ramps.json) and
/// reports the content classification, the Dolby Vision record and policy, the colour
/// attachments of the decoded buffer, each patch's decoded Y, Cb and Cr (mean of the 16 x 16
/// centre block) against the generated codes, the `DynamicRangePlan` for the simulated display and
/// setting, and each patch tone-mapped to 8-bit sRGB through `HDRToneMapper`. `--screenshot`
/// writes the Cmd+S image and reads the patches back from the PNG, `--thumbnail` reads the
/// reference white patch from a generated seek-bar thumbnail.
enum HdrCommand {
    struct Parameters: Encodable {
        var file: String
        var decoder: String
        var display: DisplayCapabilities
        var setting: HDRSetting
        var screenshot: String?
        var thumbnail: Bool
    }

    /// The decoded frame: the middle of the 2 s ramps, away from the first and last frames.
    static let frameTime = MediaTime.seconds(0.5)

    struct DolbyVisionRecord: Encodable {
        var profile: Int
        var level: Int
        var rpu: Bool
        var el: Bool
        var bl: Bool
        var compatibilityID: Int
        var profileName: String
        var base: DolbyVisionBase
        var tag: String
        var warning: Bool
        var videoInfoLine: String

        init(_ config: DolbyVisionConfig) {
            profile = config.profile
            level = config.level
            rpu = config.rpu
            el = config.el
            bl = config.bl
            compatibilityID = config.compatibilityID
            profileName = config.profileName
            base = DolbyVisionPolicy.base(for: config)
            tag = DolbyVisionPolicy.tag(for: config)
            warning = DolbyVisionPolicy.showsWarning(for: config)
            videoInfoLine = DolbyVisionPolicy.videoInfoLine(for: config)
        }
    }

    struct Patch: Encodable {
        var name: String
        var kind: String
        var nits: Double?
        var signal: Double?
        var expected: YCbCrCodes
        var decoded: YCbCrCodes?
        /// Largest |decoded - expected| over Y, Cb and Cr.
        var maxError: Double?
        /// Through `HDRToneMapper` (SDR frames: through ColorSync), 8-bit sRGB means.
        var toneMapped: SRGBValue?
        var toneMappedLuma: Double?
        /// Read back from the `--screenshot` PNG.
        var screenshot: SRGBValue?
        /// What the simulated display is asked to show: for `edr`, extended linear sRGB tone-mapped
        /// to the display's current headroom (1.0 = SDR white); for `toneMapToSDR` and `sdr`,
        /// the 8-bit sRGB value above divided by 255.
        var display: Display?

        struct Display: Encodable {
            var linear: [Double]?
            var srgb: SRGBValue?
            var luma: Double?
        }
    }

    /// Checks over the neutral patches, in patch order (the pass rules of section 7.7).
    struct NeutralSummary: Encodable {
        /// Tone-mapped sRGB luma of each neutral patch.
        var lumas: [Double]
        /// Strictly increasing up to the first value at 255 (or to the end).
        var increasingToClip: Bool
        /// Number of distinct rounded lumas.
        var distinctValues: Int
        /// Largest |r - g| or |g - b| on any neutral patch.
        var maxNeutralSpread: Double
        /// The first patch (0 nits or signal 0).
        var blackValue: Double?
        /// The reference white patch (203 nits, or HLG and SDR signal 0.75).
        var referenceWhiteName: String?
        var referenceWhiteValue: Double?
    }

    struct Attachments: Encodable {
        var names: [String]
        var primaries: String?
        var transfer: String?
        var matrix: String?
        var pixelFormat: String
        var fullRange: Bool
        var masteringDisplay: MasteringDisplay?
        var contentLightLevel: ContentLightLevel?
    }

    struct ScreenshotReport: Encodable {
        var path: String
        var width: Int
        var height: Int
        var iccProfile: Bool
        var colorSpace: String?
        var neutral: NeutralSummary
    }

    struct ThumbnailReport: Encodable {
        var width: Int
        var height: Int
        var patch: String
        var value: SRGBValue
        var luma: Double
        var decoder: String?
    }

    struct Report: Encodable {
        var file: String
        var requestedDecoder: String
        var decoder: String
        var frameTime: Double
        var kind: DynamicRange.Kind
        var ramp: String
        var dolbyVision: DolbyVisionRecord?
        var display: DisplayCapabilities
        var setting: HDRSetting
        var plan: DynamicRangePlan
        var presentation: DynamicRangePresentation
        var sourceHeadroom: Double?
        var attachments: Attachments
        var patches: [Patch]
        var toneMapped: NeutralSummary
        /// The neutral patches through `CIToneMapHeadroom` (source headroom to 1.0) instead of
        /// ColorSync's PQ conversion, for comparison only (section 7.7's first choice).
        var headroomCurveLumas: [Double]?
        var maxCodeError: Double?
        var screenshot: ScreenshotReport?
        var thumbnail: ThumbnailReport?
    }

    static func run(_ arguments: CommandArguments) throws -> Int32 {
        let parameters = try parse(arguments)
        let report = try measure(parameters, decoder: try arguments.decoder())
        if arguments.json {
            try printJSON(report)
        } else {
            printText(report)
        }
        return 0
    }

    static func parse(_ arguments: CommandArguments) throws -> Parameters {
        let url = try arguments.file()
        let display = try displayCapabilities(arguments)
        let setting: HDRSetting
        if let text = arguments.options["--setting"] {
            guard let value = HDRSetting(rawValue: text.lowercased()) else {
                throw UsageError("unknown setting \(text); use full, limited or off")
            }
            setting = value
        } else {
            setting = .default
        }
        return Parameters(
            file: url.path(percentEncoded: false),
            decoder: try arguments.decoder()?.rawValue ?? "auto",
            display: display,
            setting: setting,
            screenshot: arguments.options["--screenshot"],
            thumbnail: arguments.flags.contains("--thumbnail")
        )
    }

    /// `--display` preset or `--display-headroom X` (X at least 1); the XDR display by default.
    static func displayCapabilities(_ arguments: CommandArguments) throws -> DisplayCapabilities {
        let preset = arguments.options["--display"]
        let headroom = arguments.options["--display-headroom"]
        switch (preset, headroom) {
        case (nil, nil):
            return .xdr
        case (let text?, nil):
            guard let display = DisplayCapabilities.preset(text) else {
                throw UsageError("unknown display \(text); use sdr, xdr, external or headroom=X")
            }
            return display
        case (nil, let text?):
            guard let value = Double(text), value.isFinite, value >= 1 else {
                throw UsageError("--display-headroom must be a number of at least 1")
            }
            return .headroom(value)
        case (_?, _?):
            throw UsageError("use --display or --display-headroom, not both")
        }
    }

    // MARK: Measurement

    static func measure(_ parameters: Parameters, decoder: VideoDecoderKind?) throws -> Report {
        let url = URL(filePath: parameters.file)
        let demuxer = try Demuxer(url: url)
        let info = demuxer.info
        demuxer.stop()
        let content = DynamicRange.classify(info)
        let plan = DynamicRangePlan.make(content: content, setting: parameters.setting, display: parameters.display)

        let grab = try FrameGrabber.grab(url: url, at: frameTime, decoder: decoder)
        let buffer = grab.frame.pixelBuffer
        let attachments = buffer.withUnsafeBuffer { readAttachments($0) }
        let transfer = buffer.withUnsafeBuffer { HDRToneMapper.transfer(of: $0) }
        let rampName = transfer?.rawValue ?? "sdr"
        let ramp = try RampTable.load(near: url).ramp(rampName)

        let toneMappedImage = try FrameGrabber.image(from: buffer)
        guard let raster = SRGBRaster(toneMappedImage) else { throw UsageError("cannot read the tone-mapped image") }
        let headroom = buffer.withUnsafeBuffer { HDRToneMapper.sourceHeadroom(of: $0) }

        var patches: [Patch] = []
        for entry in ramp.patches {
            let center = entry.center
            let decoded = FrameGrabber.meanCodes(buffer, centerX: center.x, centerY: center.y)
            let value = raster.mean(centerX: center.x, centerY: center.y)
            let expected = YCbCrCodes(y: Double(entry.codes.y), cb: Double(entry.codes.cb), cr: Double(entry.codes.cr))
            var maxError: Double?
            if let decoded {
                maxError = [abs(decoded.y - expected.y), abs(decoded.cb - expected.cb), abs(decoded.cr - expected.cr)].max()
            }
            let luma: Double = (value.luma * 10).rounded() / 10
            var patch = Patch(
                name: entry.name, kind: entry.kind, nits: entry.nits, signal: entry.signal, expected: expected,
                decoded: decoded, maxError: maxError, toneMapped: value.rounded, toneMappedLuma: luma
            )
            patch.display = displayValue(buffer: buffer, plan: plan, display: parameters.display, center: center, sdr: value)
            patches.append(patch)
        }

        var screenshot: ScreenshotReport?
        if let path = parameters.screenshot {
            let pngURL = URL(filePath: path).standardizedFileURL
            try Screenshot.write(frame: buffer, subtitle: nil, to: pngURL)
            let (image, icc, spaceName) = try readPNG(pngURL)
            guard let shotRaster = SRGBRaster(image) else { throw UsageError("cannot read \(path)") }
            for index in patches.indices {
                let center = ramp.patches[index].center
                patches[index].screenshot = shotRaster.mean(centerX: center.x, centerY: center.y).rounded
            }
            let values = patches.filter { $0.kind == "neutral" }.compactMap(\.screenshot)
            screenshot = ScreenshotReport(
                path: pngURL.path(percentEncoded: false), width: image.width, height: image.height,
                iccProfile: icc, colorSpace: spaceName, neutral: summarize(values, patches: patches, ramp: rampName)
            )
        }

        let thumbnail = parameters.thumbnail ? try thumbnailValue(url: url, decoder: decoder, ramp: ramp, rampName: rampName) : nil
        let neutral = summarize(patches.filter { $0.kind == "neutral" }.compactMap(\.toneMapped), patches: patches, ramp: rampName)
        var headroomCurve: [Double]?
        if transfer != nil, let curve = try? buffer.withUnsafeBuffer({ try HDRToneMapper.headroomCurveImage($0) }), let curveRaster = SRGBRaster(curve) {
            headroomCurve = ramp.patches.filter { $0.kind == "neutral" }.map { patch in
                (curveRaster.mean(centerX: patch.center.x, centerY: patch.center.y).luma * 10).rounded() / 10
            }
        }

        return Report(
            file: parameters.file,
            requestedDecoder: parameters.decoder,
            decoder: grab.frame.decoder.rawValue,
            frameTime: grab.frame.presentationTime.seconds,
            kind: content.kind,
            ramp: rampName,
            dolbyVision: info.dolbyVision.map(DolbyVisionRecord.init),
            display: parameters.display,
            setting: parameters.setting,
            plan: plan,
            presentation: plan.presentation,
            sourceHeadroom: headroom.map { (Double($0) * 1_000).rounded() / 1_000 },
            attachments: attachments,
            patches: patches,
            toneMapped: neutral,
            headroomCurveLumas: headroomCurve,
            maxCodeError: patches.compactMap(\.maxError).max(),
            screenshot: screenshot,
            thumbnail: thumbnail
        )
    }

    static func displayValue(buffer: CVReadOnlyPixelBuffer, plan: DynamicRangePlan, display: DisplayCapabilities, center: (x: Int, y: Int), sdr: SRGBValue) -> Patch.Display {
        guard plan.presentation == .edr else {
            return Patch.Display(linear: nil, srgb: sdr.rounded, luma: (sdr.luma * 10).rounded() / 10)
        }
        let rect = CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
        let linear = buffer.withUnsafeBuffer { HDRToneMapper.linearMean($0, rect: rect, targetHeadroom: Float(display.currentHeadroom)) }
        return Patch.Display(linear: linear.map { [$0.r, $0.g, $0.b].map { ($0 * 10_000).rounded() / 10_000 } }, srgb: nil, luma: nil)
    }

    static func summarize(_ values: [SRGBValue], patches: [Patch], ramp: String) -> NeutralSummary {
        let lumas = values.map { ($0.luma * 10).rounded() / 10 }
        var increasing = true
        for index in lumas.indices.dropFirst() {
            if lumas[index - 1] >= 254.5 { break }
            if lumas[index] <= lumas[index - 1] {
                increasing = false
                break
            }
        }
        let neutral = patches.filter { $0.kind == "neutral" }
        let whiteIndex = neutral.firstIndex { patch in
            ramp == "pq" ? patch.nits == HDRToneMapper.referenceWhiteNits : patch.signal == 0.75
        }
        return NeutralSummary(
            lumas: lumas,
            increasingToClip: increasing,
            distinctValues: Set(lumas.map { $0.rounded() }).count,
            maxNeutralSpread: values.map(\.neutralSpread).max() ?? 0,
            blackValue: lumas.first,
            referenceWhiteName: whiteIndex.map { neutral[$0].name },
            referenceWhiteValue: whiteIndex.flatMap { $0 < lumas.count ? lumas[$0] : nil }
        )
    }

    static func readAttachments(_ buffer: CVPixelBuffer) -> Attachments {
        let all = (CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any]) ?? [:]
        let mastering = all[kCVImageBufferMasteringDisplayColorVolumeKey as String] as? Data
        let light = all[kCVImageBufferContentLightLevelInfoKey as String] as? Data
        let format = CVPixelBufferGetPixelFormatType(buffer)
        return Attachments(
            names: all.keys.sorted(),
            primaries: all[kCVImageBufferColorPrimariesKey as String] as? String,
            transfer: all[kCVImageBufferTransferFunctionKey as String] as? String,
            matrix: all[kCVImageBufferYCbCrMatrixKey as String] as? String,
            pixelFormat: fourCC(format),
            fullRange: [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange].contains(format),
            masteringDisplay: VideoColor.masteringDisplayInfo(mastering),
            contentLightLevel: light.flatMap { data in
                AttachmentValues.maxCLL(data).map { ContentLightLevel(maxCLL: $0, maxFALL: AttachmentValues.maxFALL(data) ?? 0) }
            }
        )
    }

    static func fourCC(_ value: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func readPNG(_ url: URL) throws -> (CGImage, Bool, String?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw UsageError("cannot read \(url.path)") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let icc = properties?[kCGImagePropertyProfileName] != nil || image.colorSpace?.copyICCData() != nil
        return (image, icc, image.colorSpace?.name as String?)
    }

    /// Generates the file's seek-bar thumbnails (no cache) and reads the reference white patch
    /// from the one at `frameTime`.
    static func thumbnailValue(url: URL, decoder: VideoDecoderKind?, ramp: RampTable.Ramp, rampName: String) throws -> ThumbnailReport {
        var options = ThumbnailGenerator.Options()
        options.decoder = decoder
        let generator = ThumbnailGenerator(url: url, key: nil, cache: nil, options: options)
        generator.start()
        let report = waitFor { await generator.finished() }
        defer { generator.close() }
        guard let thumbnail = generator.thumbnail(at: frameTime),
              let source = CGImageSourceCreateWithData(thumbnail.jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let raster = SRGBRaster(image) else {
            throw UsageError("no thumbnail was generated (\(report.outcome))")
        }
        let white = ramp.patches.first { rampName == "pq" ? $0.nits == HDRToneMapper.referenceWhiteNits : $0.signal == 0.75 }
            ?? ramp.patches[0]
        let scaleX = Double(image.width) / Double(ramp.width)
        let scaleY = Double(image.height) / Double(ramp.height)
        let center = white.center
        let value = raster.mean(centerX: Int(Double(center.x) * scaleX), centerY: Int(Double(center.y) * scaleY), size: 6)
        return ThumbnailReport(
            width: image.width, height: image.height, patch: white.name, value: value.rounded,
            luma: (value.luma * 10).rounded() / 10, decoder: report.decoder?.rawValue
        )
    }

    private static func printText(_ report: Report) {
        print("file: \(report.file)")
        print("kind: \(report.kind.rawValue), decoder: \(report.decoder), ramp: \(report.ramp)")
        print("plan: layer \(report.plan.layer.rawValue), presentation \(report.presentation.rawValue), tag \(report.plan.tag ?? "none")"
            + (report.plan.tagDetail.map { " \($0)" } ?? ""))
        print("attachments: \(report.attachments.primaries ?? "-"), \(report.attachments.transfer ?? "-"), \(report.attachments.matrix ?? "-")")
        for patch in report.patches {
            let decoded = patch.decoded.map { String(format: "%.1f %.1f %.1f", $0.y, $0.cb, $0.cr) } ?? "-"
            let toned = patch.toneMapped.map { String(format: "%.0f %.0f %.0f", $0.r, $0.g, $0.b) } ?? "-"
            print("  \(patch.name): expected \(Int(patch.expected.y)) \(Int(patch.expected.cb)) \(Int(patch.expected.cr)), decoded \(decoded), sRGB \(toned)")
        }
    }
}

// MARK: reelctl color

/// `reelctl color <file> --frame N [--decoder hw|sw] [--screenshot png] --json` (M3, SDR colour
/// follows ColorSync like QuickTime). Renders video frame N through Reel's own path (decode,
/// colour attachments, `FrameGrabber.image`, drawn into sRGB by ColorSync) and through
/// `AVAssetImageGenerator` (the AVFoundation and QuickTime pipeline) into the same 8-bit sRGB
/// bitmap, and reports both values for a 6 x 4 grid of patches (16 x 16 means). Patches whose
/// block is not flat in both images (an edge between bars) are reported but left out of
/// `maxDifference`.
enum ColorCommand {
    struct Patch: Encodable {
        var name: String
        var x: Int
        var y: Int
        var reel: SRGBValue
        var quickTime: SRGBValue
        /// Largest per-channel difference.
        var difference: Double
        var flat: Bool
    }

    struct Report: Encodable {
        var file: String
        var frame: Int
        var time: Double
        var decoder: String
        var width: Int
        var height: Int
        var attachments: HdrCommand.Attachments
        /// The colour space Reel's image carries before it is drawn into sRGB.
        var reelColorSpace: String?
        var reelColorSpaceIsDeviceRGB: Bool
        var patches: [Patch]
        var maxDifference: Double
        var screenshot: String?
        var screenshotICCProfile: Bool?
    }

    static func run(_ arguments: CommandArguments) throws -> Int32 {
        let url = try arguments.file()
        let frameText = arguments.options["--frame"] ?? "0"
        guard let frame = Int(frameText), frame >= 0 else { throw UsageError("--frame must be a frame number (0 or more)") }
        let report = try measure(url: url, frame: frame, decoder: try arguments.decoder(), screenshot: arguments.options["--screenshot"])
        if arguments.json {
            try printJSON(report)
        } else {
            for patch in report.patches {
                print("\(patch.name): reel \(Int(patch.reel.r)) \(Int(patch.reel.g)) \(Int(patch.reel.b)), quicktime \(Int(patch.quickTime.r)) \(Int(patch.quickTime.g)) \(Int(patch.quickTime.b))")
            }
            print("max difference: \(report.maxDifference)")
        }
        return 0
    }

    static func measure(url: URL, frame: Int, decoder: VideoDecoderKind?, screenshot: String?) throws -> Report {
        let demuxer = try Demuxer(url: url)
        let rate = demuxer.videoFormat?.frameRate.map { $0.doubleValue } ?? 24
        demuxer.stop()
        // Frame N is matched by index in display order on each side: FFmpeg's packet times and
        // AVFoundation's edit-list timeline can differ by the B-frame delay (2 frames on a
        // B-frame mp4). Each side is asked for a quarter frame after frame N's own start.
        let quarter = MediaTime(seconds: 0.25 / max(rate, 1))
        let reelTimes = try FrameGrabber.videoFrameTimes(url: url, count: frame + 1)
        guard reelTimes.count == frame + 1 else { throw UsageError("the file has only \(reelTimes.count) video frames") }
        let target = reelTimes[frame] + quarter
        let grab = try FrameGrabber.grab(url: url, at: target, decoder: decoder)
        let reelImage = try FrameGrabber.image(from: grab.frame.pixelBuffer)
        let reference = waitFor { () -> Result<CGImage, any Error> in
            do {
                let start = try await FrameGrabber.referenceFrameTime(url: url, index: frame)
                return .success(try await FrameGrabber.referenceImage(url: url, at: start + quarter))
            } catch {
                return .failure(error)
            }
        }
        let quickTimeImage = try reference.get()
        guard let reel = SRGBRaster(reelImage), let quickTime = SRGBRaster(quickTimeImage) else {
            throw UsageError("cannot draw the frames into sRGB")
        }
        var patches: [Patch] = []
        for row in 0..<4 {
            for column in 0..<6 {
                let x = reel.width * (2 * column + 1) / 12
                let y = reel.height * (2 * row + 1) / 8
                let mine = reel.mean(centerX: x, centerY: y)
                let theirs = quickTime.mean(centerX: x * quickTime.width / max(reel.width, 1), centerY: y * quickTime.height / max(reel.height, 1))
                let difference = max(abs(mine.r - theirs.r), abs(mine.g - theirs.g), abs(mine.b - theirs.b))
                let flat = reel.range(centerX: x, centerY: y) <= 6 && quickTime.range(centerX: x, centerY: y) <= 6
                patches.append(Patch(
                    name: "r\(row + 1)c\(column + 1)", x: x, y: y, reel: mine.rounded, quickTime: theirs.rounded,
                    difference: (difference * 10).rounded() / 10, flat: flat
                ))
            }
        }
        var screenshotPath: String?
        var icc: Bool?
        if let screenshot {
            let pngURL = URL(filePath: screenshot).standardizedFileURL
            try Screenshot.write(frame: grab.frame.pixelBuffer, subtitle: nil, to: pngURL)
            screenshotPath = pngURL.path(percentEncoded: false)
            icc = try HdrCommand.readPNG(pngURL).1
        }
        let space = reelImage.colorSpace
        return Report(
            file: url.path(percentEncoded: false),
            frame: frame,
            time: grab.frame.presentationTime.seconds,
            decoder: grab.frame.decoder.rawValue,
            width: reelImage.width,
            height: reelImage.height,
            attachments: grab.frame.pixelBuffer.withUnsafeBuffer { HdrCommand.readAttachments($0) },
            reelColorSpace: space.flatMap { $0.name as String? } ?? space.map { String(describing: $0) },
            reelColorSpaceIsDeviceRGB: space.map { CFEqual($0, CGColorSpaceCreateDeviceRGB()) } ?? true,
            patches: patches,
            maxDifference: patches.filter(\.flat).map(\.difference).max() ?? 0,
            screenshot: screenshotPath,
            screenshotICCProfile: icc
        )
    }
}

// MARK: Ramp table

/// build/fixtures/logs/ramps.json (scripts/make-ramp.py).
struct RampTable: Decodable {
    struct Patch: Decodable {
        struct Rect: Decodable { var x, y, w, h: Int }
        struct Codes: Decodable { var y, cb, cr: Int }
        var name: String
        var kind: String
        var nits: Double?
        var signal: Double?
        var rect: Rect
        var codes: Codes

        var center: (x: Int, y: Int) { (rect.x + rect.w / 2, rect.y + rect.h / 2) }
    }

    struct Ramp: Decodable {
        var width: Int
        var height: Int
        var patches: [Patch]
    }

    var pq: Ramp
    var hlg: Ramp
    var sdr: Ramp

    func ramp(_ name: String) -> Ramp {
        switch name {
        case "pq": pq
        case "hlg": hlg
        default: sdr
        }
    }

    /// logs/ramps.json next to the file's folder (hdr/../logs), else under `REEL_FIXTURES`.
    static func load(near url: URL) throws -> RampTable {
        var candidates = [url.deletingLastPathComponent().deletingLastPathComponent().appending(path: "logs/ramps.json")]
        if let fixtures = ProcessInfo.processInfo.environment["REEL_FIXTURES"] {
            candidates.append(URL(filePath: fixtures).appending(path: "logs/ramps.json"))
        }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            return try JSONDecoder().decode(RampTable.self, from: Data(contentsOf: candidate))
        }
        throw UsageError("no logs/ramps.json next to \(url.path(percentEncoded: false)); run scripts/fixtures.sh")
    }
}

// MARK: Waiting

/// Runs `body` on the cooperative pool and blocks this (non-pool) thread until it returns.
/// Commands are synchronous; this lets them use the engine's async APIs.
func waitFor<Value: Sendable>(_ body: @escaping @Sendable () async -> Value) -> Value {
    let result = Mutex<Value?>(nil)
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let value = await body()
        result.withLock { $0 = value }
        done.signal()
    }
    done.wait()
    guard let value = result.withLock({ $0 }) else { fatalError("waitFor finished without a value") }
    return value
}
