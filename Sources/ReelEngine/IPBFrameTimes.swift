import CReelDeps
import Foundation

/// Video packets whose times a `MediaSource` rewrites before handing them out.
protocol VideoPacketRetiming: AnyObject {
    /// True once the source's times have been rewritten.
    var isRepairing: Bool { get }
    /// Takes the next video packet in decode order; returns the packets ready to hand out.
    func push(_ packet: Packet) -> [Packet]
    /// Hands out every held packet (end of file).
    func drain() -> [Packet]
    /// Forgets the held packets (a seek).
    func reset()
}

/// Presentation times for I/P/B streams whose container leaves some out: MPEG-4 Part 2 (XviD,
/// DivX) in AVI, and MPEG-1 and MPEG-2 video in program streams (DVD .vob, .mpg) and raw (.m2v).
/// AVI stores only decode times, a program stream stamps only some pictures (often not the I and
/// P ones), a raw stream none. A seek needs a pts on every picture to find its target.
///
/// A missing pts follows FFmpeg's own decode: a B-picture is shown at its own decode time, an I or
/// P-picture at the decode time of the next one that is not a B-picture. In MPEG-1/2 streams the
/// pts that are there are kept; in AVI every packet gets these times (FFmpeg's guesses for the
/// first packets differ from them by a frame). Packed bitstream AVI files (a P and a B-VOP in one packet) are left as they are. Not thread
/// safe: owned by one `MediaSource`.
final class IPBFrameTimes: VideoPacketRetiming {
    private enum Kind {
        case reference
        case bidirectional
        case packed
    }

    private enum Syntax {
        /// VOP start code 00 00 01 B6, coding type in the next two bits: 0 I, 1 P, 2 B, 3 S.
        case mpeg4
        /// Picture start code 00 00 01 00, then temporal_reference (10 bits) and the coding type
        /// (3 bits): 1 I, 2 P, 3 B, 4 D.
        case mpeg12
    }

    private let syntax: Syntax
    /// A reference picture without a pts, waiting for the next one, then the B-pictures read after it.
    private var held: [Packet] = []
    private var passing = false
    private(set) var isRepairing = false

    init?(stream: UnsafeMutablePointer<AVStream>, formatName: String) {
        switch (formatName, stream.pointee.codecpar?.pointee.codec_id) {
        case ("avi", AV_CODEC_ID_MPEG4):
            syntax = .mpeg4
        case ("mpeg", AV_CODEC_ID_MPEG2VIDEO), ("mpeg", AV_CODEC_ID_MPEG1VIDEO),
             ("mpegvideo", AV_CODEC_ID_MPEG2VIDEO), ("mpegvideo", AV_CODEC_ID_MPEG1VIDEO):
            syntax = .mpeg12
        default:
            return nil
        }
    }

    func push(_ packet: Packet) -> [Packet] {
        if passing { return [packet] }
        guard let dts = packet.rawDTS, let kind = kind(of: packet) else { return drain() + [packet] }
        switch kind {
        case .packed:
            passing = true
            return drain() + [packet]
        case .bidirectional:
            let timed = packet.rawPTS == nil || syntax == .mpeg4 ? timed(packet, pts: dts) : packet
            if held.isEmpty { return [timed] }
            held.append(timed)
            return []
        case .reference:
            var ready: [Packet] = []
            if let reference = held.first {
                ready = [timed(reference, pts: dts)] + held.dropFirst()
                held = []
            }
            if packet.rawPTS != nil, syntax == .mpeg12 { return ready + [packet] }
            held = [packet]
            return ready
        }
    }

    func drain() -> [Packet] {
        guard let reference = held.first else { return [] }
        // The last reference has no next one: it is shown one frame after the last packet read.
        let last = held.compactMap(\.rawDTS).max() ?? 0
        let ready = [timed(reference, pts: last + max(reference.rawDuration, 1))] + held.dropFirst()
        held = []
        return ready
    }

    func reset() {
        held = []
    }

    private func timed(_ packet: Packet, pts: Int64) -> Packet {
        guard packet.rawPTS != pts else { return packet }
        isRepairing = true
        return Packet(referencing: packet, pts: pts) ?? packet
    }

    private func kind(of packet: Packet) -> Kind? {
        let bytes = packet.bytes
        var found: Kind?
        var index = 0
        while index + 5 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                switch syntax {
                case .mpeg4 where bytes[index + 3] == 0xB6:
                    if found != nil { return .packed }
                    found = (bytes[index + 4] >> 6) == 2 ? .bidirectional : .reference
                case .mpeg12 where bytes[index + 3] == 0x00:
                    // The second field of a field-coded frame has its own header; the first decides.
                    return ((bytes[index + 5] >> 3) & 0x07) == 3 ? .bidirectional : .reference
                default:
                    break
                }
                index += 3
                continue
            }
            index += 1
        }
        return found
    }
}
