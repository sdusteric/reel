import CReelDeps
import Darwin
import Foundation
import ReelCore
import Synchronization

/// Damage inside VP9 tile data that VideoToolbox decodes without an error (section 7.10).
///
/// A parse-only libavcodec VP9 decoder (FFmpeg patched by `scripts/patches/ffmpeg-vp9-tile-check.patch`:
/// `skip_idct` at `AVDISCARD_ALL` reads the symbols and reconstructs nothing) runs beside the
/// hardware decoder and checks the VP9 spec's rule that the bits after a tile's last symbol are
/// zero. Damaged tile data leaves the boolean decoder somewhere else, so the padding is not zero.
///
/// The check follows the decoder from a keyframe: every packet after it must be inspected in
/// decode order, or the check pauses until the next keyframe. Its CPU time is held to a
/// `CheckBudget` (2% of one core on average).
final class VP9TileCheck: Sendable {
    enum Verdict: Equatable, Sendable {
        /// Parsed, and every tile ends in zero padding.
        case clean
        /// The packet's tile data is damaged (or it could not be parsed).
        case damaged
        /// Not checked: waiting for a keyframe, out of budget, or the check is off for this file.
        case unchecked
    }

    private struct State {
        var context: UnsafeMutablePointer<AVCodecContext>?
        var frame: UnsafeMutablePointer<AVFrame>?
        var budget: CheckBudget
        /// Every packet since the last keyframe went through the parser.
        var synced = false
        /// A keyframe has passed the padding rule: the encoder writes zero padding.
        var conformanceSeen = false
        var disabled = false
        var checked = 0
        var damaged = 0
        var cpuNanos: Int64 = 0
    }

    private let state: Mutex<State>
    private let now: @Sendable () -> UInt64

    /// Nil when libavcodec cannot open a VP9 decoder for `parameters`.
    init?(parameters: CodecParameters, budget: CheckBudget = CheckBudget(), now: @escaping @Sendable () -> UInt64 = monotonicNanos) {
        guard parameters.pointer.pointee.codec_id == AV_CODEC_ID_VP9,
              let codec = avcodec_find_decoder(AV_CODEC_ID_VP9),
              let context = avcodec_alloc_context3(codec) else { return nil }
        var owned: UnsafeMutablePointer<AVCodecContext>? = context
        guard avcodec_parameters_to_context(context, parameters.pointer) >= 0 else {
            avcodec_free_context(&owned)
            return nil
        }
        context.pointee.thread_count = 1
        context.pointee.skip_idct = AVDISCARD_ALL
        context.pointee.err_recognition |= AV_EF_BITSTREAM
        guard avcodec_open2(context, codec, nil) >= 0, let frame = av_frame_alloc() else {
            avcodec_free_context(&owned)
            return nil
        }
        state = Mutex(State(context: context, frame: frame, budget: budget))
        self.now = now
    }

    deinit {
        state.withLock { state in
            avcodec_free_context(&state.context)
            av_frame_free(&state.frame)
        }
    }

    /// Packets parsed, packets found damaged and CPU time spent since open.
    var totals: (checked: Int, damaged: Int, cpuNanos: Int64) {
        state.withLock { ($0.checked, $0.damaged, $0.cpuNanos) }
    }

    var isDisabled: Bool { state.withLock { $0.disabled } }

    /// The next packet inspected does not follow the last one in decode order (a seek, a packet
    /// skipped or decoded elsewhere): the check waits for a keyframe.
    func pause() {
        state.withLock { $0.synced = false }
    }

    /// Parses `packet`, the next one in decode order. A check starts only at a keyframe and only
    /// when `mayStart` (the caller outputs it, so no seek pre-roll is parsed).
    func inspect(_ packet: Packet, mayStart: Bool) -> Verdict {
        let time = now()
        return state.withLock { state -> Verdict in
            state.budget.refill(now: time)
            guard !state.disabled, let context = state.context, let frame = state.frame else { return .unchecked }
            if !state.synced {
                guard packet.isKeyframe, mayStart, state.budget.mayStart else { return .unchecked }
                avcodec_flush_buffers(context)
                state.synced = true
            } else if packet.isKeyframe ? !state.budget.mayStart : state.budget.isOverdrawn {
                state.synced = false
                return .unchecked
            }
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let code = VP9TileCheck.parse(packet, context: context, frame: frame)
            let spent = Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- start)
            state.budget.spend(spent)
            state.cpuNanos += spent
            state.checked += 1
            if code >= 0 {
                if packet.isKeyframe { state.conformanceSeen = true }
                return .clean
            }
            state.synced = false
            if code == reel_averror(EBADMSG), packet.isKeyframe, !state.conformanceSeen {
                // Before any keyframe has passed, nonzero padding means an encoder that does not
                // zero it (the spec requires it, libvpx does): the check is off for this file.
                trace("VP9 tile check off: the first keyframe has nonzero padding")
                state.disabled = true
                return .unchecked
            }
            if code != reel_averror(EBADMSG), code != reel_averror_invaliddata() {
                trace("VP9 tile check off: \(FFmpegError.message(for: code))")
                state.disabled = true
                return .unchecked
            }
            state.damaged += 1
            trace("VP9 tile check: damaged packet at \(packet.time?.description ?? "-") (\(FFmpegError.message(for: code)))")
            return .damaged
        }
    }

    /// Sends one packet and takes every frame it produces; returns the first error, else 0.
    private static func parse(_ packet: Packet, context: UnsafeMutablePointer<AVCodecContext>, frame: UnsafeMutablePointer<AVFrame>) -> Int32 {
        var result = avcodec_send_packet(context, packet.avPacket)
        if result == reel_averror_eagain() { result = 0 }
        while true {
            let received = avcodec_receive_frame(context, frame)
            if received == reel_averror_eagain() || received == reel_averror_eof() { break }
            if received < 0 {
                if result >= 0 { result = received }
                break
            }
            av_frame_unref(frame)
        }
        return min(result, 0)
    }
}
