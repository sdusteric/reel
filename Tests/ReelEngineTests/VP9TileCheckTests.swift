import CReelDeps
import Foundation
import ReelCore
import Synchronization
import Testing
@testable import ReelEngine

/// The VP9 tile check (section 7.10): damage inside VP9 tile data that VideoToolbox, libavcodec
/// and libvpx all decode without an error shows as nonzero padding after the tile's last symbol.
@Suite struct VP9TileCheckTests {
    /// The video packets of `url` in decode order and the stream's parameters.
    static func videoPackets(_ url: URL, limit: Int = .max) throws -> (parameters: CodecParameters, packets: [Packet]) {
        var context: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&context, url.path(percentEncoded: false), nil, nil), "avformat_open_input")
        defer { avformat_close_input(&context) }
        let format = try #require(context)
        try FFmpegError.check(avformat_find_stream_info(format, nil), "avformat_find_stream_info")
        let index = try FFmpegError.check(av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0), "av_find_best_stream")
        let stream = try #require(format.pointee.streams[Int(index)])
        let parameters = try CodecParameters(copying: stream)
        var packets: [Packet] = []
        var raw = av_packet_alloc()
        defer { av_packet_free(&raw) }
        let packet = try #require(raw)
        while packets.count < limit, av_read_frame(format, packet) >= 0 {
            if packet.pointee.stream_index == index {
                packets.append(Packet(moving: packet, timeBase: stream.pointee.time_base))
            } else {
                av_packet_unref(packet)
            }
        }
        return (parameters, packets)
    }

    /// A budget that never runs out, so every packet is parsed.
    static let unlimited = CheckBudget(share: 1, allowanceNanos: .max / 4, debtLimitNanos: .max / 4)

    static func verdicts(_ path: String, limit: Int = .max) throws -> (check: VP9TileCheck, packets: [Packet], verdicts: [VP9TileCheck.Verdict]) {
        let (parameters, packets) = try videoPackets(fixtureURL(path), limit: limit)
        let check = try #require(VP9TileCheck(parameters: parameters, budget: unlimited))
        return (check, packets, packets.map { check.inspect($0, mayStart: true) })
    }

    @Test(arguments: ["corpus/vp9.webm", "hdr/pq_ramp_vp9.webm", "vp9_2160p60.webm"])
    func intactStreamsPassEveryPacket(_ path: String) throws {
        let (check, packets, verdicts) = try VP9TileCheckTests.verdicts(path, limit: 600)
        #expect(verdicts.allSatisfy { $0 == .clean }, "\(verdicts.filter { $0 != .clean }.count) of \(packets.count) not clean")
        #expect(check.totals.checked == packets.count)
        #expect(!check.isDisabled)
    }

    /// The 4 KB overwrite of overwrite50 lands in the tile data of the hidden alt-ref frame at
    /// 0.792 s; the other overwrites are found too. After the damaged packet the check waits for
    /// the next keyframe, as playback does.
    @Test func theOverwrittenPacketIsFoundAndNothingElse() throws {
        let (_, packets, verdicts) = try VP9TileCheckTests.verdicts("corpus/vp9.overwrite50.webm")
        let damaged = zip(packets, verdicts).filter { $0.1 == .damaged }.map(\.0)
        #expect(damaged.count == 1)
        let at = try #require(damaged.first?.time)
        #expect(abs(at.seconds - 0.792) < 0.01, "damage found at \(at)")
        let index = try #require(verdicts.firstIndex(of: .damaged))
        let resume = try #require(packets[(index + 1)...].firstIndex { $0.isKeyframe })
        #expect(verdicts[(index + 1)..<resume].allSatisfy { $0 == .unchecked })
        #expect(verdicts[resume...].allSatisfy { $0 == .clean })
        for path in ["corpus/vp9.overwrite25.webm", "corpus/vp9.overwrite75.webm"] {
            #expect(try VP9TileCheckTests.verdicts(path).verdicts.contains(.damaged), "\(path)")
        }
    }

    @Test func aCheckStartsOnlyAtAKeyframeThatIsOutput() throws {
        let (parameters, packets) = try VP9TileCheckTests.videoPackets(fixtureURL("corpus/vp9.webm"))
        let check = try #require(VP9TileCheck(parameters: parameters, budget: VP9TileCheckTests.unlimited))
        // Seek pre-roll (not output) is never parsed.
        #expect(check.inspect(packets[0], mayStart: false) == .unchecked)
        // Mid-GOP: waits for the next keyframe.
        let next = try #require(packets[1...].firstIndex { $0.isKeyframe })
        #expect(packets[1..<next].map { check.inspect($0, mayStart: true) }.allSatisfy { $0 == .unchecked })
        #expect(check.inspect(packets[next], mayStart: true) == .clean)
        #expect(check.inspect(packets[next + 1], mayStart: true) == .clean)
        // A packet skipped elsewhere: the check pauses until the next keyframe.
        check.pause()
        #expect(check.inspect(packets[next + 3], mayStart: true) == .unchecked)
        #expect(check.totals.checked == 2)
    }

    @Test func theBudgetHoldsTheCheckToItsShareOfACore() throws {
        let (parameters, packets) = try VP9TileCheckTests.videoPackets(fixtureURL("vp9_2160p60.webm"), limit: 600)
        // Playback time advances one frame (1/60 s) per packet; the 4K60 parse costs far more
        // than 2% of a core, so most GOPs go unchecked once the allowance is spent.
        let clock = ManualClock()
        let budget = CheckBudget(share: 0.02, allowanceNanos: 20_000_000, debtLimitNanos: 10_000_000)
        let made = VP9TileCheck(parameters: parameters, budget: budget) { clock.now }
        let check = try #require(made)
        var verdicts: [VP9TileCheck.Verdict] = []
        for packet in packets {
            clock.advance(16_666_667)
            verdicts.append(check.inspect(packet, mayStart: true))
        }
        let checked = check.totals.checked
        #expect(checked > 0 && checked < packets.count, "\(checked) of \(packets.count)")
        #expect(!verdicts.contains(.damaged))
        let elapsed = Int64(packets.count) * 16_666_667
        // Spent at most the allowance, the share and one packet over the debt limit.
        #expect(check.totals.cpuNanos < 20_000_000 + elapsed / 50 + 10_000_000 + 50_000_000, "\(check.totals.cpuNanos) ns")
    }

    /// An encoder that does not zero its padding (the spec requires it; libvpx does) turns the
    /// check off at the first keyframe instead of reporting every frame as damaged.
    @Test func nonzeroPaddingOnTheFirstKeyframeTurnsTheCheckOff() throws {
        let (parameters, packets) = try VP9TileCheckTests.videoPackets(fixtureURL("corpus/vp9.webm"))
        var payload = [UInt8](packets[0].bytes)
        let last = try #require(payload.lastIndex { $0 == 0 })
        payload[last] = 0x01
        let altered = try #require(Packet(copying: packets[0], payload: payload))
        let check = try #require(VP9TileCheck(parameters: parameters, budget: VP9TileCheckTests.unlimited))
        #expect(check.inspect(altered, mayStart: true) == .unchecked)
        #expect(check.isDisabled)
        #expect(check.inspect(packets[1], mayStart: true) == .unchecked)
    }

    /// Played by the engine on VideoToolbox: the damaged alt-ref frame is skipped to the next
    /// keyframe and counted, and the intact file is checked without a damaged frame.
    @Test func playbackCountsTheDamageVideoToolboxDoesNotReport() async throws {
        let (_, damaged, end, info) = try await RobustnessTests.playToEnd(fixtureURL("corpus/vp9.overwrite50.webm"))
        #expect(info.videoDecoder == .hardware)
        #expect(damaged > 0)
        let duration = (info.startTime ?? .zero) + (info.duration ?? .zero)
        let reached = try #require(end)
        #expect(reached + .seconds(1) >= duration)

        let engine = TestEngines.make()
        let log = EventLog()
        log.start(engine.events)
        _ = try await engine.open(fixtureURL("corpus/vp9.webm"))
        await engine.setRate(4)
        await engine.play()
        #expect(await log.wait(timeout: .seconds(20)) { log in log.all.contains { $0 == .ended } })
        let totals = try #require(engine.vp9TileCheckTotals)
        #expect(totals.checked > 0)
        #expect(totals.damaged == 0)
        #expect(engine.damagedFrames == 0)
        await engine.close()
    }
}

/// A clock the test moves by hand.
final class ManualClock: Sendable {
    private let value = Mutex<UInt64>(1_000_000_000)
    var now: UInt64 { value.withLock { $0 } }
    func advance(_ nanos: UInt64) { value.withLock { $0 += nanos } }
}
