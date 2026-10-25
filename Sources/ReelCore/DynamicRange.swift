import Foundation

/// The content's dynamic range (section 7.7), classified from the video stream's colour fields
/// and its Dolby Vision record.
public enum DynamicRange: Sendable, Hashable {
    case sdr
    /// PQ (SMPTE ST 2084).
    case hdr10
    /// HLG (ARIB STD-B67, ITU-R BT.2100).
    case hlg
    /// Dolby Vision; `base` says which layer plays.
    case dolbyVision(DolbyVisionConfig)

    public enum Kind: String, Sendable, Codable, Hashable, CaseIterable {
        case sdr, hdr10, hlg, dolbyVision
    }

    /// FFmpeg's names for the HDR transfer functions (`av_color_transfer_name`).
    public static let pqTransfer = "smpte2084"
    public static let hlgTransfer = "arib-std-b67"

    /// Classifies from colour fields: a Dolby Vision record wins, then the transfer function.
    /// Anything else (BT.709, BT.601, sRGB, unknown) is SDR.
    public static func classify(color: ColorInfo?, dolbyVision: DolbyVisionConfig?) -> DynamicRange {
        if let dolbyVision { return .dolbyVision(dolbyVision) }
        switch color?.transfer {
        case pqTransfer?: return .hdr10
        case hlgTransfer?: return .hlg
        default: return .sdr
        }
    }

    /// Classifies the selected video stream of `info`; SDR without one.
    public static func classify(_ info: MediaInfo) -> DynamicRange {
        classify(color: info.videoStream?.video?.color, dolbyVision: info.dolbyVision)
    }

    public var kind: Kind {
        switch self {
        case .sdr: .sdr
        case .hdr10: .hdr10
        case .hlg: .hlg
        case .dolbyVision: .dolbyVision
        }
    }

    public var dolbyVision: DolbyVisionConfig? {
        if case .dolbyVision(let config) = self { return config }
        return nil
    }

    /// For Dolby Vision, the layer that plays (`DolbyVisionPolicy`); nil otherwise.
    public var dolbyVisionBase: DolbyVisionBase? {
        dolbyVision.map(DolbyVisionPolicy.base(for:))
    }

    /// The picture is an HDR signal: HDR10, HLG, or Dolby Vision whose base is not SDR.
    public var isHDR: Bool {
        switch self {
        case .sdr: false
        case .hdr10, .hlg: true
        case .dolbyVision(let config): DolbyVisionPolicy.base(for: config).isHDR
        }
    }

    /// The title bar tag; nil for SDR (section 9.13).
    public var tag: String? {
        switch self {
        case .sdr: nil
        case .hdr10: "HDR10"
        case .hlg: "HLG"
        case .dolbyVision(let config): DolbyVisionPolicy.tag(for: config)
        }
    }

    /// Video Info's Range value: "SDR", "HDR10", "HLG", "Dolby Vision 8.1".
    public var rangeName: String {
        switch self {
        case .sdr: "SDR"
        case .hdr10: "HDR10"
        case .hlg: "HLG"
        case .dolbyVision(let config): "Dolby Vision \(config.profileName)"
        }
    }
}

extension DynamicRange: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, dolbyVision, base
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .sdr: self = .sdr
        case .hdr10: self = .hdr10
        case .hlg: self = .hlg
        case .dolbyVision: self = .dolbyVision(try container.decode(DolbyVisionConfig.self, forKey: .dolbyVision))
        }
    }

    /// `{"kind": "hdr10"}`, or for Dolby Vision `{"kind": "dolbyVision", "dolbyVision": {...}, "base": "hlg"}`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if let dolbyVision {
            try container.encode(dolbyVision, forKey: .dolbyVision)
            try container.encode(DolbyVisionPolicy.base(for: dolbyVision), forKey: .base)
        }
    }
}

// MARK: Video Info text

extension ColorInfo {
    /// Video Info's Colour value, e.g. "BT.2020, PQ, limited range".
    public var videoInfoDescription: String {
        let primariesName = primaries.map(ColorInfo.primariesName) ?? "Unknown primaries"
        let transferName = transfer.map(ColorInfo.transferName) ?? "unknown transfer"
        return "\(primariesName), \(transferName), \(fullRange ? "full" : "limited") range"
    }

    static func primariesName(_ name: String) -> String {
        switch name {
        case "bt2020": "BT.2020"
        case "bt709": "BT.709"
        case "smpte170m": "BT.601 (SMPTE 170M)"
        case "bt470bg": "BT.601 (PAL)"
        case "smpte432": "Display P3"
        case "smpte431": "DCI-P3"
        default: name
        }
    }

    static func transferName(_ name: String) -> String {
        switch name {
        case DynamicRange.pqTransfer: "PQ"
        case DynamicRange.hlgTransfer: "HLG"
        case "bt709", "smpte170m", "bt2020-10", "bt2020-12": "BT.709"
        case "iec61966-2-1": "sRGB"
        case "linear": "linear"
        default: name
        }
    }
}

extension MasteringDisplay {
    /// Video Info's Mastering value, e.g. "1000 nits peak, P3 D65".
    public var videoInfoDescription: String {
        let peak = "\(Int(maxLuminance.rounded())) nits peak"
        guard let primariesName else { return peak }
        return "\(peak), \(primariesName)"
    }
}

extension ContentLightLevel {
    /// Video Info's Light level value, e.g. "MaxCLL 1000, MaxFALL 400 nits".
    public var videoInfoDescription: String {
        "MaxCLL \(maxCLL), MaxFALL \(maxFALL) nits"
    }
}
