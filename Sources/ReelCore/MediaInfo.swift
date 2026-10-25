import Foundation

public enum StreamKind: String, Sendable, Codable, Hashable {
    case video, audio, subtitle, data, attachment, unknown
}

/// Which video decoder a stream uses.
public enum VideoDecoderKind: String, Sendable, Codable, Hashable {
    /// Direct VTDecompressionSession.
    case hardware
    /// libavcodec (dav1d for AV1).
    case software
}

/// Colour description taken from codecpar or, when unspecified there, from a decoded frame.
/// Values are FFmpeg enum names (`av_color_primaries_name` and friends), e.g. "bt709", "smpte2084".
public struct ColorInfo: Sendable, Codable, Hashable {
    public var primaries: String?
    public var transfer: String?
    public var matrix: String?
    public var fullRange: Bool
    /// Mastering display metadata or content light level is present.
    public var hasHDRMetadata: Bool
    /// (M3) SMPTE ST 2086 mastering display colour volume, when the stream carries it.
    public var mastering: MasteringDisplay?
    /// (M3) CTA-861.3 content light level (MaxCLL, MaxFALL), when the stream carries it.
    public var contentLight: ContentLightLevel?

    public init(
        primaries: String? = nil,
        transfer: String? = nil,
        matrix: String? = nil,
        fullRange: Bool = false,
        hasHDRMetadata: Bool = false,
        mastering: MasteringDisplay? = nil,
        contentLight: ContentLightLevel? = nil
    ) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.fullRange = fullRange
        self.hasHDRMetadata = hasHDRMetadata
        self.mastering = mastering
        self.contentLight = contentLight
    }
}

/// A CIE 1931 xy chromaticity.
public struct Chromaticity: Sendable, Codable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Mastering display colour volume (SMPTE ST 2086), luminance in nits.
public struct MasteringDisplay: Sendable, Codable, Hashable {
    public var red: Chromaticity
    public var green: Chromaticity
    public var blue: Chromaticity
    public var whitePoint: Chromaticity
    public var minLuminance: Double
    public var maxLuminance: Double

    public init(
        red: Chromaticity,
        green: Chromaticity,
        blue: Chromaticity,
        whitePoint: Chromaticity,
        minLuminance: Double,
        maxLuminance: Double
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.whitePoint = whitePoint
        self.minLuminance = minLuminance
        self.maxLuminance = maxLuminance
    }

    /// Display P3 primaries with a D65 white point, the usual mastering display.
    public static func p3D65(minLuminance: Double = 0.0001, maxLuminance: Double = 1_000) -> MasteringDisplay {
        MasteringDisplay(
            red: Chromaticity(x: 0.680, y: 0.320),
            green: Chromaticity(x: 0.265, y: 0.690),
            blue: Chromaticity(x: 0.150, y: 0.060),
            whitePoint: Chromaticity(x: 0.3127, y: 0.3290),
            minLuminance: minLuminance,
            maxLuminance: maxLuminance
        )
    }

    /// "P3 D65", "BT.2020" or "BT.709" when the primaries match one within 0.005, else nil.
    public var primariesName: String? {
        let known: [(String, [Chromaticity])] = [
            ("P3 D65", [.init(x: 0.680, y: 0.320), .init(x: 0.265, y: 0.690), .init(x: 0.150, y: 0.060), .init(x: 0.3127, y: 0.3290)]),
            ("BT.2020", [.init(x: 0.708, y: 0.292), .init(x: 0.170, y: 0.797), .init(x: 0.131, y: 0.046), .init(x: 0.3127, y: 0.3290)]),
            ("BT.709", [.init(x: 0.640, y: 0.330), .init(x: 0.300, y: 0.600), .init(x: 0.150, y: 0.060), .init(x: 0.3127, y: 0.3290)]),
        ]
        let mine = [red, green, blue, whitePoint]
        for (name, points) in known where zip(mine, points).allSatisfy({ abs($0.x - $1.x) <= 0.005 && abs($0.y - $1.y) <= 0.005 }) {
            return name
        }
        return nil
    }
}

/// Content light level (CTA-861.3), in nits.
public struct ContentLightLevel: Sendable, Codable, Hashable {
    /// MaxCLL: the brightest pixel of the programme.
    public var maxCLL: Int
    /// MaxFALL: the brightest frame average.
    public var maxFALL: Int

    public init(maxCLL: Int, maxFALL: Int) {
        self.maxCLL = maxCLL
        self.maxFALL = maxFALL
    }
}

/// The Dolby Vision decoder configuration record (`dvcC`, `dvvC`, `dvwC` in MP4, the
/// `BlockAdditionMapping` in Matroska), as FFmpeg exports it in `AV_PKT_DATA_DOVI_CONF`.
public struct DolbyVisionConfig: Sendable, Codable, Hashable {
    /// `dv_profile`: 5, 7, 8, 9 or 10.
    public var profile: Int
    /// `dv_level`: 1 to 13.
    public var level: Int
    /// An RPU (NAL type 62) is present.
    public var rpu: Bool
    /// An enhancement layer (NAL type 63) is present.
    public var el: Bool
    /// A base layer is present.
    public var bl: Bool
    /// `dv_bl_signal_compatibility_id`: what the base layer is without Dolby Vision (section 7.8).
    public var compatibilityID: Int

    public init(profile: Int, level: Int, rpu: Bool, el: Bool, bl: Bool, compatibilityID: Int) {
        self.profile = profile
        self.level = level
        self.rpu = rpu
        self.el = el
        self.bl = bl
        self.compatibilityID = compatibilityID
    }

    /// "8.1" for profile 8 with compatibility 1, "5" when the id is 0.
    public var profileName: String {
        compatibilityID == 0 ? "\(profile)" : "\(profile).\(compatibilityID)"
    }
}

public struct VideoParameters: Sendable, Codable, Hashable {
    /// Coded size in pixels.
    public var width: Int
    public var height: Int
    public var pixelAspect: Rational?
    public var frameRate: Rational?
    public var bitDepth: Int
    /// Display matrix rotation, clockwise degrees: 0, 90, 180 or 270.
    public var rotation: Int
    public var color: ColorInfo

    public init(
        width: Int,
        height: Int,
        pixelAspect: Rational? = nil,
        frameRate: Rational? = nil,
        bitDepth: Int = 8,
        rotation: Int = 0,
        color: ColorInfo = ColorInfo()
    ) {
        self.width = width
        self.height = height
        self.pixelAspect = pixelAspect
        self.frameRate = frameRate
        self.bitDepth = bitDepth
        self.rotation = rotation
        self.color = color
    }

    /// Size after pixel aspect ratio and rotation, in pixels.
    public var displaySize: (width: Int, height: Int) {
        var displayWidth = Double(width)
        if let pixelAspect, pixelAspect.isValid {
            displayWidth *= pixelAspect.doubleValue
        }
        let roundedWidth = Int(displayWidth.rounded())
        if rotation == 90 || rotation == 270 {
            return (height, roundedWidth)
        }
        return (roundedWidth, height)
    }

    /// Duration of one frame, when the frame rate is known.
    public var frameDuration: MediaTime? {
        guard let frameRate, frameRate.isValid else { return nil }
        return MediaTime(value: 1, timeBaseNum: frameRate.den, timeBaseDen: frameRate.num)
    }
}

public struct AudioParameters: Sendable, Codable, Hashable {
    public var sampleRate: Int
    public var channels: Int
    /// FFmpeg layout description, e.g. "5.1(side)".
    public var channelLayout: String?

    public init(sampleRate: Int, channels: Int, channelLayout: String? = nil) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.channelLayout = channelLayout
    }
}

public struct StreamInfo: Sendable, Codable, Hashable, Identifiable {
    /// The container's stream index.
    public var index: Int
    public var kind: StreamKind
    /// FFmpeg codec name, e.g. "hevc", "av1", "aac".
    public var codec: String
    public var profile: String?
    public var timeBase: Rational
    public var startTime: MediaTime?
    public var duration: MediaTime?
    public var bitRate: Int?
    public var language: String?
    public var title: String?
    public var isDefault: Bool
    public var isForced: Bool
    /// `AV_DISPOSITION_HEARING_IMPAIRED` (SDH subtitles).
    public var isHearingImpaired: Bool
    public var isAttachedPicture: Bool
    public var video: VideoParameters?
    public var audio: AudioParameters?

    public var id: Int { index }

    public init(
        index: Int,
        kind: StreamKind,
        codec: String,
        profile: String? = nil,
        timeBase: Rational,
        startTime: MediaTime? = nil,
        duration: MediaTime? = nil,
        bitRate: Int? = nil,
        language: String? = nil,
        title: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        isHearingImpaired: Bool = false,
        isAttachedPicture: Bool = false,
        video: VideoParameters? = nil,
        audio: AudioParameters? = nil
    ) {
        self.index = index
        self.kind = kind
        self.codec = codec
        self.profile = profile
        self.timeBase = timeBase
        self.startTime = startTime
        self.duration = duration
        self.bitRate = bitRate
        self.language = language
        self.title = title
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isAttachedPicture = isAttachedPicture
        self.video = video
        self.audio = audio
    }
}

/// What the engine knows about an opened file.
public struct MediaInfo: Sendable, Codable, Hashable {
    public var url: URL
    /// FFmpeg demuxer name, e.g. "matroska,webm".
    public var formatName: String
    public var duration: MediaTime?
    public var startTime: MediaTime?
    public var bitRate: Int?
    public var fileSize: Int64?
    public var streams: [StreamInfo]
    /// Container index of the selected video stream.
    public var videoStreamIndex: Int?
    /// Container index of the selected audio stream.
    public var audioStreamIndex: Int?
    public var videoDecoder: VideoDecoderKind?
    public var keyframeCount: Int
    /// (M3) The video stream's Dolby Vision configuration record, when it has one (section 7.8).
    /// Absent in JSON written before M3.
    public var dolbyVision: DolbyVisionConfig?

    public init(
        url: URL,
        formatName: String,
        duration: MediaTime? = nil,
        startTime: MediaTime? = nil,
        bitRate: Int? = nil,
        fileSize: Int64? = nil,
        streams: [StreamInfo] = [],
        videoStreamIndex: Int? = nil,
        audioStreamIndex: Int? = nil,
        videoDecoder: VideoDecoderKind? = nil,
        keyframeCount: Int = 0,
        dolbyVision: DolbyVisionConfig? = nil
    ) {
        self.url = url
        self.formatName = formatName
        self.duration = duration
        self.startTime = startTime
        self.bitRate = bitRate
        self.fileSize = fileSize
        self.streams = streams
        self.videoStreamIndex = videoStreamIndex
        self.audioStreamIndex = audioStreamIndex
        self.videoDecoder = videoDecoder
        self.keyframeCount = keyframeCount
        self.dolbyVision = dolbyVision
    }

    public var videoStream: StreamInfo? {
        guard let videoStreamIndex else { return nil }
        return streams.first { $0.index == videoStreamIndex }
    }

    public var audioStream: StreamInfo? {
        guard let audioStreamIndex else { return nil }
        return streams.first { $0.index == audioStreamIndex }
    }

    public var title: String { url.lastPathComponent }

    public func streams(of kind: StreamKind) -> [StreamInfo] {
        streams.filter { $0.kind == kind }
    }
}
