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

    public init(
        primaries: String? = nil,
        transfer: String? = nil,
        matrix: String? = nil,
        fullRange: Bool = false,
        hasHDRMetadata: Bool = false
    ) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.fullRange = fullRange
        self.hasHDRMetadata = hasHDRMetadata
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
        keyframeCount: Int = 0
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
}
