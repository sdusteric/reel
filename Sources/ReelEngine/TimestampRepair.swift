import CReelDeps
import Foundation

/// Rebuilds presentation times for H.264 and HEVC streams whose container gives decode-order
/// times: an MP4 without a `ctts` box (as in many x265 remuxes), an MKV remuxed from one, or an
/// AVI (dts only). With B-frames those times rise in decode order, so frames sorted by them come
/// out in decode order.
///
/// Packets are handed out in decode order, as read. Each gets its time once `window` later ones
/// are read: the held packet with the lowest picture order count takes the smallest container
/// time not yet given out. Times that go back in decode order are real presentation times: the
/// first one turns the repair off for good. Not thread safe: owned by one `MediaSource`.
final class TimestampRepair: VideoPacketRetiming {
    /// No picture is displayed after more than 16 pictures that follow it in decode order (the
    /// largest HEVC and H.264 DPB), so the smallest count in a larger window is the next shown.
    static let window = 16

    private enum Mode {
        case undecided
        case repairing
        case passing
    }

    private struct Held {
        let packet: Packet
        let order: Int
        var pts: Int64?
    }

    private let codecID: AVCodecID
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var parser: UnsafeMutablePointer<AVCodecParserContext>?
    private var mode = Mode.undecided
    /// Packets in decode order, until every one before them has its time.
    private var held: [Held] = []
    /// Container times not given out yet, ascending (they are read in decode order).
    private var slots: [Int64] = []
    private var unassigned = 0
    /// Container time of the last packet read since the last seek.
    private var lastTime: Int64?

    /// Nil for codecs without B-frame reordering or a stream that declares no reorder delay.
    init?(stream: UnsafeMutablePointer<AVStream>) {
        guard let parameters = stream.pointee.codecpar else { return nil }
        codecID = parameters.pointee.codec_id
        guard codecID == AV_CODEC_ID_HEVC || codecID == AV_CODEC_ID_H264, parameters.pointee.video_delay > 0 else { return nil }
        guard let context = avcodec_alloc_context3(nil) else { return nil }
        codecContext = context
        guard avcodec_parameters_to_context(context, parameters) >= 0 else { return nil }
        guard makeParser() else { return nil }
    }

    deinit {
        if let parser { av_parser_close(parser) }
        avcodec_free_context(&codecContext)
    }

    var isRepairing: Bool { mode == .repairing }

    /// Takes the next video packet in decode order; returns the packets ready to hand out.
    func push(_ packet: Packet) -> [Packet] {
        if mode == .passing { return [packet] }
        let time = packet.rawPTS ?? packet.rawDTS
        if let time, let lastTime, time <= lastTime {
            // The container's times already put frames in display order.
            mode = .passing
            let earlier = drainAsRead()
            return earlier + [packet]
        }
        lastTime = time
        guard let time, let order = pictureOrder(packet) else {
            if mode == .undecided {
                mode = .passing
                return drainAsRead() + [packet]
            }
            // A slice header that does not parse: hand out what is held and this packet as it is.
            return drain() + [packet]
        }
        var ready: [Packet] = []
        // An IDR resets the picture order count, and everything before it is shown first.
        if packet.isKeyframe, let highest = held.filter({ $0.pts == nil }).map(\.order).max(), order <= highest {
            ready = drain()
        }
        held.append(Held(packet: packet, order: order))
        slots.append(time)
        unassigned += 1
        while unassigned > Self.window {
            mode = .repairing
            assignNext()
        }
        return ready + releaseAssigned()
    }

    /// Hands out every held packet (end of file).
    func drain() -> [Packet] {
        if mode == .undecided, !held.isEmpty { mode = .repairing }
        while unassigned > 0 { assignNext() }
        return releaseAssigned()
    }

    /// Forgets the held packets (a seek). The decision about the file is kept.
    func reset() {
        clear()
        if let parser { av_parser_close(parser) }
        parser = nil
        if mode != .passing { _ = makeParser() }
    }

    private func clear() {
        held.removeAll()
        slots.removeAll()
        unassigned = 0
        lastTime = nil
    }

    /// Hands out the held packets with the times they had when read, or were given.
    private func drainAsRead() -> [Packet] {
        let ready = held.map { held in
            held.pts.flatMap { $0 == held.packet.rawPTS ? nil : Packet(referencing: held.packet, pts: $0) } ?? held.packet
        }
        clear()
        return ready
    }

    private func assignNext() {
        var best: Int?
        for index in held.indices where held[index].pts == nil {
            if best.map({ held[index].order < held[$0].order }) ?? true { best = index }
        }
        guard let best else { return }
        held[best].pts = slots.removeFirst()
        unassigned -= 1
    }

    private func releaseAssigned() -> [Packet] {
        var ready: [Packet] = []
        while let first = held.first, let pts = first.pts {
            held.removeFirst()
            if pts == first.packet.rawPTS {
                ready.append(first.packet)
            } else {
                ready.append(Packet(referencing: first.packet, pts: pts) ?? first.packet)
            }
        }
        return ready
    }

    private func makeParser() -> Bool {
        guard let created = av_parser_init(codecID) else { return false }
        created.pointee.flags |= PARSER_FLAG_COMPLETE_FRAMES
        parser = created
        return true
    }

    /// The picture order count from the slice header, through FFmpeg's parser.
    private func pictureOrder(_ packet: Packet) -> Int? {
        guard let parser, let codecContext, packet.size > 0 else { return nil }
        var output: UnsafeMutablePointer<UInt8>?
        var outputSize: Int32 = 0
        let bytes = packet.bytes
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
        parser.pointee.output_picture_number = Int32.min
        _ = av_parser_parse2(
            parser, codecContext, &output, &outputSize, base, Int32(bytes.count),
            reel_av_nopts(), reel_av_nopts(), 0
        )
        let order = parser.pointee.output_picture_number
        return order == Int32.min ? nil : Int(order)
    }
}
