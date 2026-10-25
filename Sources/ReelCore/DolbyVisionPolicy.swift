import Foundation

/// The layer Reel plays for a Dolby Vision stream (section 7.8). Reel never applies the RPU, so
/// what is shown is the base layer as its compatibility id describes it.
public enum DolbyVisionBase: String, Sendable, Codable, Hashable, CaseIterable {
    /// PQ with the stream's mastering metadata (compatibility 1 and 6).
    case hdr10
    /// HLG (compatibility 4).
    case hlg
    /// BT.709 SDR (compatibility 2).
    case sdr
    /// No compatible base (compatibility 0: profile 5 and 10.0, or an unknown id). The decoded
    /// base is IPT and its colours are wrong without the RPU.
    case unsupported

    /// The base is shown as HDR (PQ or HLG signal). Profile 5 is PQ-coded IPT, so it counts too.
    public var isHDR: Bool { self != .sdr }
}

/// Maps a Dolby Vision configuration to what plays and how Reel labels it (section 7.8, D56).
public enum DolbyVisionPolicy {
    /// The note shown on open for a stream without a compatible base (section 9.13).
    public static let noteTitle = "Dolby Vision profile 5 can't be shown correctly"
    public static let noteBody = "Reel plays the picture without its Dolby Vision colour data, so colours look wrong, "
        + "often green or purple. Profile 8 files play correctly."
    public static let noteShowInfoButton = "Show Info"
    public static let noteOKButton = "OK"
    /// The note closes by itself after this many seconds, and is shown once per file per session.
    public static let noteSeconds: Double = 10

    public static func base(for config: DolbyVisionConfig) -> DolbyVisionBase {
        switch config.compatibilityID {
        case 1, 6: .hdr10
        case 4: .hlg
        case 2: .sdr
        default: .unsupported
        }
    }

    /// The title bar tag: "Dolby Vision", or "Dolby Vision 5" (the profile) without a compatible base.
    public static func tag(for config: DolbyVisionConfig) -> String {
        base(for: config) == .unsupported ? "Dolby Vision \(config.profile)" : "Dolby Vision"
    }

    /// The warning glyph on the tag and the note on open.
    public static func showsWarning(for config: DolbyVisionConfig) -> Bool {
        base(for: config) == .unsupported
    }

    /// The second line of Video Info's Range row: which layer plays.
    public static func videoInfoLine(for config: DolbyVisionConfig) -> String {
        switch base(for: config) {
        case .hdr10: "Playing the HDR10 base layer. The Dolby Vision layer is not applied."
        case .hlg: "Playing the HLG base layer. The Dolby Vision layer is not applied."
        case .sdr: "Playing the SDR base layer. The Dolby Vision layer is not applied."
        case .unsupported: "Playing the base layer without its Dolby Vision colour data, so colours are wrong."
        }
    }
}
