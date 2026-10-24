import AudioToolbox
import CoreMedia
import CReelDeps
import Foundation
import ReelCore

/// Maps FFmpeg channel layouts to Core Audio channel descriptions (design section 7.4).
///
/// Samples stay in FFmpeg's native order (FL FR FC LFE, then backs and sides) and the layout
/// describes that order with `kAudioChannelLayoutTag_UseChannelDescriptions`, so nothing is
/// reordered. BL/BR become LeftSurround/RightSurround when the layout has no side channels
/// (5.1 back), and RearSurroundLeft/Right when sides exist too (7.1).
public enum ChannelLayout {
    /// The channels of `layout` in stream order. Layouts without a native order (unspecified or
    /// custom) are reported as FFmpeg's default layout for their channel count.
    public static func channels(of layout: AVChannelLayout) -> [AVChannel] {
        var source = layout
        let count = Int(source.nb_channels)
        guard count > 0 else { return [] }
        if source.order == AV_CHANNEL_ORDER_NATIVE {
            return (0..<count).map { av_channel_layout_channel_from_index(&source, UInt32($0)) }
        }
        var fallback = AVChannelLayout()
        av_channel_layout_default(&fallback, Int32(count))
        defer { av_channel_layout_uninit(&fallback) }
        return (0..<count).map { av_channel_layout_channel_from_index(&fallback, UInt32($0)) }
    }

    /// Core Audio labels for channels in FFmpeg native order.
    public static func labels(for channels: [AVChannel]) -> [AudioChannelLabel] {
        if channels == [AV_CHAN_FRONT_CENTER] { return [kAudioChannelLabel_Mono] }
        let hasSide = channels.contains(AV_CHAN_SIDE_LEFT) || channels.contains(AV_CHAN_SIDE_RIGHT)
        let hasBack = channels.contains(AV_CHAN_BACK_LEFT) || channels.contains(AV_CHAN_BACK_RIGHT)
        return channels.map { label(for: $0, hasSideAndBack: hasSide && hasBack) }
    }

    /// One channel's label. `hasSideAndBack` selects the 7.1 naming for BL/BR.
    public static func label(for channel: AVChannel, hasSideAndBack: Bool) -> AudioChannelLabel {
        switch channel {
        case AV_CHAN_FRONT_LEFT: kAudioChannelLabel_Left
        case AV_CHAN_FRONT_RIGHT: kAudioChannelLabel_Right
        case AV_CHAN_FRONT_CENTER: kAudioChannelLabel_Center
        case AV_CHAN_LOW_FREQUENCY: kAudioChannelLabel_LFEScreen
        case AV_CHAN_BACK_LEFT: hasSideAndBack ? kAudioChannelLabel_RearSurroundLeft : kAudioChannelLabel_LeftSurround
        case AV_CHAN_BACK_RIGHT: hasSideAndBack ? kAudioChannelLabel_RearSurroundRight : kAudioChannelLabel_RightSurround
        case AV_CHAN_SIDE_LEFT: kAudioChannelLabel_LeftSurround
        case AV_CHAN_SIDE_RIGHT: kAudioChannelLabel_RightSurround
        case AV_CHAN_FRONT_LEFT_OF_CENTER: kAudioChannelLabel_LeftCenter
        case AV_CHAN_FRONT_RIGHT_OF_CENTER: kAudioChannelLabel_RightCenter
        case AV_CHAN_BACK_CENTER: kAudioChannelLabel_CenterSurround
        case AV_CHAN_TOP_CENTER: kAudioChannelLabel_TopCenterSurround
        case AV_CHAN_TOP_FRONT_LEFT: kAudioChannelLabel_VerticalHeightLeft
        case AV_CHAN_TOP_FRONT_CENTER: kAudioChannelLabel_VerticalHeightCenter
        case AV_CHAN_TOP_FRONT_RIGHT: kAudioChannelLabel_VerticalHeightRight
        case AV_CHAN_TOP_BACK_LEFT: kAudioChannelLabel_TopBackLeft
        case AV_CHAN_TOP_BACK_CENTER: kAudioChannelLabel_TopBackCenter
        case AV_CHAN_TOP_BACK_RIGHT: kAudioChannelLabel_TopBackRight
        case AV_CHAN_STEREO_LEFT: kAudioChannelLabel_LeftTotal
        case AV_CHAN_STEREO_RIGHT: kAudioChannelLabel_RightTotal
        case AV_CHAN_WIDE_LEFT: kAudioChannelLabel_LeftWide
        case AV_CHAN_WIDE_RIGHT: kAudioChannelLabel_RightWide
        case AV_CHAN_LOW_FREQUENCY_2: kAudioChannelLabel_LFE2
        default: kAudioChannelLabel_Unknown
        }
    }

    /// An `AudioChannelLayout` with one description per label, as raw bytes (the struct has a
    /// variable-length trailing array).
    public static func layoutData(labels: [AudioChannelLabel]) -> Data {
        let count = labels.count
        let size = MemoryLayout<AudioChannelLayout>.size
            + max(0, count - 1) * MemoryLayout<AudioChannelDescription>.stride
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let layout = base.assumingMemoryBound(to: AudioChannelLayout.self)
            layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            layout.pointee.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
            layout.pointee.mNumberChannelDescriptions = UInt32(count)
            let descriptionsOffset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) ?? 12
            let descriptions = (base + descriptionsOffset).bindMemory(to: AudioChannelDescription.self, capacity: count)
            for (index, label) in labels.enumerated() {
                descriptions[index] = AudioChannelDescription(
                    mChannelLabel: label,
                    mChannelFlags: AudioChannelFlags(rawValue: 0),
                    mCoordinates: (0, 0, 0)
                )
            }
        }
        return data
    }

    /// The labels stored in a layout built by `layoutData(labels:)`.
    public static func labels(inLayoutData data: Data) -> [AudioChannelLabel] {
        data.withUnsafeBytes { raw -> [AudioChannelLabel] in
            guard let base = raw.baseAddress, raw.count >= MemoryLayout<AudioChannelLayout>.size else { return [] }
            let layout = base.assumingMemoryBound(to: AudioChannelLayout.self)
            let count = Int(layout.pointee.mNumberChannelDescriptions)
            let descriptionsOffset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) ?? 12
            let available = (raw.count - descriptionsOffset) / MemoryLayout<AudioChannelDescription>.stride
            let descriptions = (base + descriptionsOffset).assumingMemoryBound(to: AudioChannelDescription.self)
            return (0..<min(count, available)).map { descriptions[$0].mChannelLabel }
        }
    }

    /// The Core Audio layout tag equivalent to `data`, when Core Audio knows one (e.g. Stereo,
    /// MPEG_5_1_A). Used by tests and probe output to confirm the descriptions are understood.
    public static func equivalentTag(forLayoutData data: Data) -> AudioChannelLayoutTag? {
        var tag: AudioChannelLayoutTag = 0
        var size = UInt32(MemoryLayout<AudioChannelLayoutTag>.size)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return AudioFormatGetProperty(kAudioFormatProperty_TagForChannelLayout, UInt32(data.count), base, &size, &tag)
        }
        return status == noErr ? tag : nil
    }

    /// FFmpeg's name for a layout, e.g. "5.1(side)".
    public static func describe(_ layout: AVChannelLayout) -> String {
        var source = layout
        var buffer = [CChar](repeating: 0, count: 128)
        let written = av_channel_layout_describe(&source, &buffer, buffer.count)
        guard written >= 0 else { return "\(layout.nb_channels) channels" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The LPCM format Reel enqueues: interleaved float32 at the source rate, LinearPCM with
    /// IsFloat | IsPacked, 32 bits, 4 x channels bytes per frame.
    public static func streamDescription(sampleRate: Int, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    /// A Core Media format description for interleaved float32 with the given channel labels.
    public static func formatDescription(sampleRate: Int, labels: [AudioChannelLabel]) throws -> CMAudioFormatDescription {
        var asbd = streamDescription(sampleRate: sampleRate, channels: labels.count)
        let layout = layoutData(labels: labels)
        var description: CMAudioFormatDescription?
        let status = layout.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: raw.count,
                layout: base.assumingMemoryBound(to: AudioChannelLayout.self),
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else {
            throw EngineError.decoderFailed("CMAudioFormatDescriptionCreate failed (\(status))")
        }
        return description
    }
}
