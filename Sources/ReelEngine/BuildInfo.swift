import CReelDeps

/// Versions and configuration of the statically linked FFmpeg and libass.
public enum BuildInfo {
    /// `avformat_license()`; the license gate requires "LGPL version 2.1 or later".
    public static var ffmpegLicense: String { String(cString: avformat_license()) }

    /// `avformat_configuration()`: the configure flags FFmpeg was built with.
    public static var ffmpegConfiguration: String { String(cString: avformat_configuration()) }

    public static var avformatVersion: String { versionString(avformat_version()) }
    public static var avcodecVersion: String { versionString(avcodec_version()) }
    public static var avutilVersion: String { versionString(avutil_version()) }

    /// libass version as hex, e.g. "0x01705000".
    public static var libassVersion: String {
        let hex = String(ass_library_version(), radix: 16)
        return "0x" + String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }

    /// True when the license is LGPL and no GPL or nonfree component was enabled.
    public static var isLGPL: Bool {
        let configuration = ffmpegConfiguration
        return ffmpegLicense.hasPrefix("LGPL")
            && !configuration.contains("--enable-gpl")
            && !configuration.contains("--enable-nonfree")
    }

    private static func versionString(_ packed: UInt32) -> String {
        "\(packed >> 16).\((packed >> 8) & 0xff).\(packed & 0xff)"
    }
}
