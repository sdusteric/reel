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

/// Presentation times for MPEG-4 Part 2 (XviD, DivX) in AVI. AVI stores only decode times: with
/// B-frames FFmpeg infers pts for some packets while reading on and for none after a seek, and
/// the seek needs them to find its target.
///
/// The times follow FFmpeg's own decode: a B-VOP is shown at its own decode time, an I, P or S-VOP
/// at the decode time of the next one that is not a B-VOP. Packed bitstream files (a P and a B-VOP
/// in one packet) are left as they are. Not thread safe: owned by one `MediaSource`.
final class MPEG4AVIFrameTimes: VideoPacketRetiming {
    private enum Kind {
        case reference
        case bidirectional
        case packed
    }

    /// The reference VOP waiting for the next one, then the B-VOPs read after it.
    private var held: [Packet] = []
    private var passing = false
    private(set) var isRepairing = false

    init?(stream: UnsafeMutablePointer<AVStream>, formatName: String) {
        guard formatName == "avi", stream.pointee.codecpar?.pointee.codec_id == AV_CODEC_ID_MPEG4 else { return nil }
    }

    func push(_ packet: Packet) -> [Packet] {
        if passing { return [packet] }
        guard let dts = packet.rawDTS, let kind = Self.kind(of: packet) else { return drain() + [packet] }
        switch kind {
        case .packed:
            passing = true
            return drain() + [packet]
        case .bidirectional:
            let timed = Self.timed(packet, pts: dts)
            if held.isEmpty { return [timed] }
            held.append(timed)
            return []
        case .reference:
            var ready: [Packet] = []
            if let reference = held.first {
                isRepairing = true
                ready = [Self.timed(reference, pts: dts)] + held.dropFirst()
            }
            held = [packet]
            return ready
        }
    }

    func drain() -> [Packet] {
        guard let reference = held.first else { return [] }
        // The last reference has no next one: it is shown one frame after the last packet read.
        let last = held.compactMap(\.rawDTS).max() ?? 0
        let ready = [Self.timed(reference, pts: last + max(reference.rawDuration, 1))] + held.dropFirst()
        held = []
        return ready
    }

    func reset() {
        held = []
    }

    private static func timed(_ packet: Packet, pts: Int64) -> Packet {
        packet.rawPTS == pts ? packet : Packet(referencing: packet, pts: pts) ?? packet
    }

    /// The VOP coding type after the VOP start code (00 00 01 B6): 0 I, 1 P, 2 B, 3 S (GMC).
    private static func kind(of packet: Packet) -> Kind? {
        let bytes = packet.bytes
        var found: Kind?
        var index = 0
        while index + 4 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1, bytes[index + 3] == 0xB6 {
                if found != nil { return .packed }
                found = (bytes[index + 4] >> 6) == 2 ? .bidirectional : .reference
                index += 4
            }
            index += 1
        }
        return found
    }
}
