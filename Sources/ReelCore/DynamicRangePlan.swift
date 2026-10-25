import Foundation

/// Settings, High dynamic range (section 11.1, D51).
public enum HDRSetting: String, Sendable, Codable, Hashable, CaseIterable {
    /// The display layer asks for the whole EDR headroom (`.high`). The default.
    case full
    /// `.constrainedHigh`: highlights stay closer to the desktop's brightness.
    case limited
    /// `.standard`: the system tone-maps HDR to standard range.
    case off

    public static let `default` = HDRSetting.full

    /// The popup item title.
    public var title: String {
        switch self {
        case .full: "Full"
        case .limited: "Limited"
        case .off: "Off"
        }
    }

    /// The explanation under the Settings row (mockup png/27).
    public static let settingsExplanation = "Full uses the display's whole HDR range. Limited keeps highlights "
        + "closer to the desktop's brightness. Off tone-maps HDR to standard range."
}

/// `CALayer.DynamicRange` without QuartzCore, so ReelCore stays Foundation only.
public enum LayerDynamicRange: String, Sendable, Codable, Hashable, CaseIterable {
    case high, constrainedHigh, standard
}

/// What Reel knows about the display the window is on (`DisplayRangeMonitor` in the app reads
/// the `NSScreen` values; tests and `reelctl hdr` use the presets).
public struct DisplayCapabilities: Sendable, Codable, Hashable {
    public var name: String
    /// `maximumPotentialExtendedDynamicRangeColorComponentValue`: 1.0 on an SDR display.
    public var potentialHeadroom: Double
    /// `maximumExtendedDynamicRangeColorComponentValue`: the headroom now (brightness dependent).
    public var currentHeadroom: Double
    /// `maximumReferenceExtendedDynamicRangeColorComponentValue`; nil or 0 when not in reference mode.
    public var referenceHeadroom: Double?

    public init(name: String, potentialHeadroom: Double, currentHeadroom: Double, referenceHeadroom: Double? = nil) {
        self.name = name
        self.potentialHeadroom = DisplayCapabilities.sanitized(potentialHeadroom)
        self.currentHeadroom = DisplayCapabilities.sanitized(currentHeadroom)
        self.referenceHeadroom = referenceHeadroom
    }

    /// The display can show any EDR headroom at all. Potential headroom 1.0 means SDR.
    public var supportsEDR: Bool { potentialHeadroom > 1.0 + 1e-3 }

    /// An SDR display (an external monitor, or one with HDR off in System Settings).
    public static let sdr = DisplayCapabilities(name: "SDR display", potentialHeadroom: 1, currentHeadroom: 1)
    /// The built-in Liquid Retina XDR display at about half brightness.
    public static let xdr = DisplayCapabilities(name: "Built-in XDR display", potentialHeadroom: 16, currentHeadroom: 3.2)
    /// An external HDR display with HDR on in System Settings.
    public static let external = DisplayCapabilities(name: "External HDR display", potentialHeadroom: 4, currentHeadroom: 4)

    /// A display with `headroom` both as its potential and current value.
    public static func headroom(_ headroom: Double) -> DisplayCapabilities {
        let value = sanitized(headroom)
        let name = value > 1.0 + 1e-3 ? "HDR display" : "SDR display"
        return DisplayCapabilities(name: name, potentialHeadroom: value, currentHeadroom: value)
    }

    /// `reelctl hdr --display sdr|xdr|external|headroom=X`; nil for anything else.
    public static func preset(_ text: String) -> DisplayCapabilities? {
        switch text.lowercased() {
        case "sdr": return .sdr
        case "xdr": return .xdr
        case "external": return .external
        default:
            guard text.lowercased().hasPrefix("headroom="),
                  let value = Double(text.dropFirst("headroom=".count)), value.isFinite, value >= 1 else { return nil }
            return .headroom(value)
        }
    }

    /// The headroom meter's fill in Video Info: current over potential, 0 to 1.
    public var headroomFraction: Double {
        guard potentialHeadroom > 0 else { return 0 }
        return min(max(currentHeadroom / potentialHeadroom, 0), 1)
    }

    private static func sanitized(_ value: Double) -> Double {
        value.isFinite ? max(value, 1) : 1
    }
}

/// One row of Video Info: key, value and an optional second line (section 9.13).
public struct VideoInfoRow: Sendable, Codable, Hashable {
    public var key: String
    public var value: String
    public var detail: String?

    public init(key: String, value: String, detail: String? = nil) {
        self.key = key
        self.value = value
        self.detail = detail
    }
}

/// How the picture reaches the screen (section 7.7), for reports, Video Info and the tag.
public enum DynamicRangePresentation: String, Sendable, Codable, Hashable {
    /// SDR content, shown as is.
    case sdr
    /// HDR content with EDR headroom: the window server maps it to the current headroom.
    case edr
    /// HDR content tone-mapped to SDR by the system (setting Off, or a display without headroom).
    case toneMapToSDR
}

/// The presentation plan for one file on one display (section 7.7 table, 9.13). Pure: the app
/// applies `layer` to the display layer's `preferredDynamicRange` and `overlay` to the subtitle
/// layer and the chrome, and shows the tag and Video Info rows.
public struct DynamicRangePlan: Sendable, Codable, Hashable {
    public var content: DynamicRange
    public var setting: HDRSetting
    /// The display layer. Depends on the content and the setting only, so moving the window
    /// between displays never reconfigures it.
    public var layer: LayerDynamicRange
    /// Subtitles, chrome and panels: always `.standard` (SDR white, D52).
    public var overlay: LayerDynamicRange
    public var presentation: DynamicRangePresentation
    /// The title bar tag; nil for SDR content.
    public var tag: String?
    /// "SDR" after the tag when the HDR picture is tone-mapped (setting Off, or potential headroom 1.0).
    public var tagDetail: String?
    /// The warning glyph on the tag (Dolby Vision without a compatible base).
    public var warning: Bool
    /// Show the profile 5 note on open (section 9.13).
    public var note: Bool
    /// The tag's tooltip; nil without a tag.
    public var tagTooltip: String?
    /// The tag's accessibility label, e.g. "Dynamic range, HDR10, tone-mapped to standard range".
    public var accessibilityLabel: String?
    /// Video Info's Range, Display and Headroom rows.
    public var videoInfo: [VideoInfoRow]

    public static let sdrDetail = "SDR"
    public static let toneMappedDisplayTooltip = "This display shows standard dynamic range, so the HDR picture is tone-mapped to fit it."
    public static let toneMappedSettingTooltip = "High dynamic range is off in Settings, so the HDR picture is tone-mapped to standard range."
    public static let hdrTooltip = "High dynamic range. Click for details."

    public static func make(content: DynamicRange, setting: HDRSetting, display: DisplayCapabilities) -> DynamicRangePlan {
        let hdr = content.isHDR
        let layer: LayerDynamicRange
        if hdr {
            switch setting {
            case .full: layer = .high
            case .limited: layer = .constrainedHigh
            case .off: layer = .standard
            }
        } else {
            layer = .standard
        }
        let toneMapped = hdr && (setting == .off || !display.supportsEDR)
        let presentation: DynamicRangePresentation = hdr ? (toneMapped ? .toneMapToSDR : .edr) : .sdr
        let tag = content.tag
        let tagDetail = tag != nil && toneMapped ? sdrDetail : nil
        let warning = content.dolbyVision.map(DolbyVisionPolicy.showsWarning(for:)) ?? false

        var tooltip: String?
        var accessibility: String?
        if let tag {
            if toneMapped {
                tooltip = setting == .off ? toneMappedSettingTooltip : toneMappedDisplayTooltip
            } else {
                tooltip = hdrTooltip
            }
            accessibility = "Dynamic range, \(tag)" + (tagDetail != nil ? ", tone-mapped to standard range" : "")
        }

        var rows = [VideoInfoRow(key: "Range", value: content.rangeName, detail: content.dolbyVision.map(DolbyVisionPolicy.videoInfoLine(for:)))]
        rows.append(VideoInfoRow(key: "Display", value: "\(display.name), \(display.supportsEDR ? "HDR" : "SDR")"))
        rows.append(VideoInfoRow(key: "Headroom", value: headroomText(display)))

        return DynamicRangePlan(
            content: content,
            setting: setting,
            layer: layer,
            overlay: .standard,
            presentation: presentation,
            tag: tag,
            tagDetail: tagDetail,
            warning: warning,
            note: warning,
            tagTooltip: tooltip,
            accessibilityLabel: accessibility,
            videoInfo: rows
        )
    }

    /// "3.2× now, 16× at most".
    public static func headroomText(_ display: DisplayCapabilities) -> String {
        "\(multiplier(display.currentHeadroom)) now, \(multiplier(display.potentialHeadroom)) at most"
    }

    /// "16×" for whole numbers, else one decimal ("3.2×").
    static func multiplier(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return "\(Int(rounded))\u{00D7}" }
        return String(format: "%.1f\u{00D7}", rounded)
    }
}
