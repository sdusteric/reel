import Testing
@testable import ReelEngine

@Suite struct BuildInfoTests {
    @Test func ffmpegIsLGPLWithoutGPLOrNonfree() {
        #expect(BuildInfo.ffmpegLicense == "LGPL version 2.1 or later")
        #expect(!BuildInfo.ffmpegConfiguration.contains("--enable-gpl"))
        #expect(!BuildInfo.ffmpegConfiguration.contains("--enable-nonfree"))
        #expect(BuildInfo.isLGPL)
    }

    @Test func ffmpegHasNoNetworkAndUsesVideoToolbox() {
        #expect(BuildInfo.ffmpegConfiguration.contains("--disable-network"))
        #expect(BuildInfo.ffmpegConfiguration.contains("--enable-videotoolbox"))
        #expect(BuildInfo.avformatVersion.split(separator: ".").count == 3)
        #expect(BuildInfo.libassVersion.hasPrefix("0x0170"))
    }
}
