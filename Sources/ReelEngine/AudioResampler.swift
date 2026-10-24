import CReelDeps
import Foundation
import ReelCore

/// swresample from a decoder's output format to interleaved float32 at the same rate and in the
/// same channel order (design section 7.4). No remixing and no rate change: only the sample
/// format and planar-to-interleaved layout change, so there is no resampler delay.
final class AudioResampler {
    let sampleRate: Int
    let channelCount: Int
    /// The channels in output order (FFmpeg native order, or the default layout for the count).
    let channels: [AVChannel]
    private let inputFormat: AVSampleFormat
    private var inputLayout: AVChannelLayout
    private var context: OpaquePointer?

    /// Configures for frames shaped like `frame`.
    convenience init(matching frame: UnsafePointer<AVFrame>) throws {
        try self.init(
            layout: frame.pointee.ch_layout,
            format: AVSampleFormat(rawValue: frame.pointee.format),
            sampleRate: Int(frame.pointee.sample_rate)
        )
    }

    init(layout: AVChannelLayout, format: AVSampleFormat, sampleRate: Int) throws {
        guard layout.nb_channels > 0, sampleRate > 0 else {
            throw EngineError.decoderFailed("audio frame has \(layout.nb_channels) channels at \(sampleRate) Hz")
        }
        self.sampleRate = sampleRate
        self.channelCount = Int(layout.nb_channels)
        self.inputFormat = format
        self.channels = ChannelLayout.channels(of: layout)

        // A layout without native order is treated as the default layout for its channel count on
        // both sides, so swresample never remixes.
        var source = layout
        var working = AVChannelLayout()
        if source.order == AV_CHANNEL_ORDER_NATIVE {
            av_channel_layout_copy(&working, &source)
        } else {
            av_channel_layout_default(&working, layout.nb_channels)
        }
        self.inputLayout = working

        var swr: OpaquePointer?
        var status = swr_alloc_set_opts2(
            &swr,
            &working, AV_SAMPLE_FMT_FLT, Int32(sampleRate),
            &working, format, Int32(sampleRate),
            0, nil
        )
        if status >= 0 { status = swr_init(swr) }
        guard status >= 0, swr != nil else {
            swr_free(&swr)
            throw EngineError.decoderFailed("swresample setup: \(FFmpegError.message(for: status))")
        }
        self.context = swr
    }

    deinit {
        swr_free(&context)
        av_channel_layout_uninit(&inputLayout)
    }

    /// True when `frame` has the format this resampler was built for.
    func accepts(_ frame: UnsafePointer<AVFrame>) -> Bool {
        guard Int(frame.pointee.sample_rate) == sampleRate,
              frame.pointee.format == inputFormat.rawValue,
              Int(frame.pointee.ch_layout.nb_channels) == channelCount else { return false }
        if inputLayout.order == AV_CHANNEL_ORDER_NATIVE {
            var incoming = frame.pointee.ch_layout
            return av_channel_layout_compare(&inputLayout, &incoming) == 0
        }
        return frame.pointee.ch_layout.order != AV_CHANNEL_ORDER_NATIVE
    }

    /// Converts `frame` and appends its interleaved samples to `output`. Returns the frame count.
    @discardableResult
    func convert(_ frame: UnsafePointer<AVFrame>, appendingTo output: inout [Float]) throws -> Int {
        let inputFrames = Int(frame.pointee.nb_samples)
        guard inputFrames > 0 else { return 0 }
        let capacity = Int(swr_get_out_samples(context, Int32(inputFrames)))
        guard capacity >= 0 else {
            throw EngineError.decoderFailed("swresample capacity: \(FFmpegError.message(for: Int32(capacity)))")
        }
        let start = output.count
        output.append(contentsOf: repeatElement(0, count: max(capacity, inputFrames) * channelCount))
        let converted = output.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            var outPlane: UnsafeMutablePointer<UInt8>? = UnsafeMutableRawPointer(base + start)
                .assumingMemoryBound(to: UInt8.self)
            return withUnsafePointer(to: &outPlane) { outPlanes in
                frame.pointee.extended_data.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: channelCount) { inPlanes in
                    swr_convert(context, outPlanes, Int32(max(capacity, inputFrames)), inPlanes, Int32(inputFrames))
                }
            }
        }
        guard converted >= 0 else {
            output.removeSubrange(start...)
            throw EngineError.decoderFailed("swresample: \(FFmpegError.message(for: converted))")
        }
        output.removeSubrange((start + Int(converted) * channelCount)...)
        return Int(converted)
    }

    /// Drops any internal state after a seek.
    func reset() {
        swr_close(context)
        _ = swr_init(context)
    }
}
