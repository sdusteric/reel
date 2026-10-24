import AudioToolbox
import CoreMedia
import CReelDeps
import Foundation
import Testing
@testable import ReelEngine

@Suite struct ChannelLayoutTests {
    /// FFmpeg's own channel order for a named layout.
    private func channels(_ name: String) throws -> [AVChannel] {
        var layout = AVChannelLayout()
        try FFmpegError.check(av_channel_layout_from_string(&layout, name), "av_channel_layout_from_string")
        defer { av_channel_layout_uninit(&layout) }
        return ChannelLayout.channels(of: layout)
    }

    @Test func stereoAndMonoMapToTheirPlainLabels() throws {
        #expect(ChannelLayout.labels(for: try channels("stereo")) == [kAudioChannelLabel_Left, kAudioChannelLabel_Right])
        #expect(ChannelLayout.labels(for: try channels("mono")) == [kAudioChannelLabel_Mono])
    }

    @Test func sideFivePointOneKeepsFFmpegOrder() throws {
        let order = try channels("5.1(side)")
        #expect(order == [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER, AV_CHAN_LOW_FREQUENCY, AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT])
        #expect(ChannelLayout.labels(for: order) == [
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
            kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
        ])
    }

    @Test func backChannelsBecomeSurroundsWhenThereAreNoSides() throws {
        let order = try channels("5.1")
        #expect(order == [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER, AV_CHAN_LOW_FREQUENCY, AV_CHAN_BACK_LEFT, AV_CHAN_BACK_RIGHT])
        #expect(ChannelLayout.labels(for: order) == [
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
            kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
        ])
    }

    @Test func backChannelsBecomeRearSurroundsWhenSidesExist() throws {
        let order = try channels("7.1")
        #expect(order == [
            AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER, AV_CHAN_LOW_FREQUENCY,
            AV_CHAN_BACK_LEFT, AV_CHAN_BACK_RIGHT, AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT,
        ])
        #expect(ChannelLayout.labels(for: order) == [
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
            kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
            kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
        ])
    }

    @Test func unspecifiedOrderFallsBackToTheDefaultLayoutForTheCount() {
        var layout = AVChannelLayout()
        layout.order = AV_CHANNEL_ORDER_UNSPEC
        layout.nb_channels = 2
        #expect(ChannelLayout.channels(of: layout) == [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT])
    }

    @Test func layoutDataUsesChannelDescriptionsThatCoreAudioUnderstands() throws {
        let stereo = ChannelLayout.layoutData(labels: ChannelLayout.labels(for: try channels("stereo")))
        #expect(ChannelLayout.labels(inLayoutData: stereo) == [kAudioChannelLabel_Left, kAudioChannelLabel_Right])
        #expect(ChannelLayout.equivalentTag(forLayoutData: stereo) == kAudioChannelLayoutTag_Stereo)

        let surround = ChannelLayout.layoutData(labels: ChannelLayout.labels(for: try channels("5.1(side)")))
        #expect(ChannelLayout.equivalentTag(forLayoutData: surround) == kAudioChannelLayoutTag_MPEG_5_1_A)

        let mono = ChannelLayout.layoutData(labels: ChannelLayout.labels(for: try channels("mono")))
        #expect(ChannelLayout.equivalentTag(forLayoutData: mono) == kAudioChannelLayoutTag_Mono)

        let raw = surround.withUnsafeBytes { $0.load(as: AudioChannelLayout.self) }
        #expect(raw.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions)
        #expect(raw.mNumberChannelDescriptions == 6)
    }

    @Test func formatDescriptionIsPackedFloat32AtTheSourceRate() throws {
        let labels = ChannelLayout.labels(for: try channels("5.1(side)"))
        let description = try ChannelLayout.formatDescription(sampleRate: 44_100, labels: labels)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mSampleRate == 44_100)
        #expect(asbd.mFormatID == kAudioFormatLinearPCM)
        #expect(asbd.mFormatFlags == kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        #expect(asbd.mBitsPerChannel == 32)
        #expect(asbd.mChannelsPerFrame == 6)
        #expect(asbd.mBytesPerFrame == 24)
        #expect(asbd.mBytesPerPacket == 24)
        #expect(asbd.mFramesPerPacket == 1)
        var size = 0
        let layout = try #require(CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size))
        #expect(ChannelLayout.labels(inLayoutData: Data(bytes: layout, count: size)) == labels)
    }

    @Test func decodedAC3FivePointOneCarriesItsLayout() throws {
        let reader = try AudioFixtureReader(url: try AudioTestMedia.fixture("hevc10_1080p24.mkv"))
        let decoder = try reader.makeDecoder()
        var buffers: [DecodedAudioBuffer] = []
        while buffers.isEmpty, let packet = reader.nextPacket() {
            buffers += try decoder.decode(packet)
        }
        let buffer = try #require(buffers.first)
        #expect(decoder.channelCount == 6)
        #expect(decoder.sampleRate == 44_100)
        #expect(decoder.channelLabels == [
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
            kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
        ])
        let description = try #require(buffer.sampleBuffer.formatDescription)
        var size = 0
        let layout = try #require(CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size))
        #expect(layout.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions)
        #expect(buffer.channelCount == 6)
        #expect(buffer.interleavedSamples().count == buffer.frameCount * 6)
    }
}
