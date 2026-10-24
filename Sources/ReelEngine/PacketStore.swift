import CoreMedia
import CReelDeps
import Foundation
import ReelCore
import Synchronization

/// One compressed packet. Owns a reference to an `AVPacket` and releases it on deinit.
///
/// Unchecked Sendable: the packet and its ref-counted data are never written after init, and
/// FFmpeg buffer references may be read and released from any thread.
public final class Packet: @unchecked Sendable {
    private let raw: UnsafeMutablePointer<AVPacket>

    public let streamIndex: Int
    /// Raw timestamps in the stream time base. `nil` when the container gave none.
    public let rawPTS: Int64?
    public let rawDTS: Int64?
    public let rawDuration: Int64
    public let timeBase: Rational
    public let isKeyframe: Bool
    /// Byte position in the file, when known.
    public let position: Int64?

    /// Takes ownership of `packet` (moves its reference into a new AVPacket).
    init(moving packet: UnsafeMutablePointer<AVPacket>, timeBase: AVRational) {
        let owned = av_packet_alloc()
        guard let owned else { fatalError("av_packet_alloc failed: out of memory") }
        av_packet_move_ref(owned, packet)
        raw = owned
        streamIndex = Int(owned.pointee.stream_index)
        let noValue = reel_av_nopts()
        rawPTS = owned.pointee.pts == noValue ? nil : owned.pointee.pts
        rawDTS = owned.pointee.dts == noValue ? nil : owned.pointee.dts
        rawDuration = owned.pointee.duration
        self.timeBase = Rational(timeBase.num, timeBase.den)
        isKeyframe = (owned.pointee.flags & AV_PKT_FLAG_KEY) != 0
        position = owned.pointee.pos >= 0 ? owned.pointee.pos : nil
    }

    /// A copy of `source` with replaced payload (used for the Annex B to length-prefix rewrite).
    init?(copying source: Packet, payload: [UInt8]) {
        guard let owned = av_packet_alloc() else { return nil }
        guard av_new_packet(owned, Int32(payload.count)) >= 0 else {
            var pointer: UnsafeMutablePointer<AVPacket>? = owned
            av_packet_free(&pointer)
            return nil
        }
        payload.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { owned.pointee.data.update(from: base.assumingMemoryBound(to: UInt8.self), count: payload.count) }
        }
        av_packet_copy_props(owned, source.raw)
        raw = owned
        streamIndex = source.streamIndex
        rawPTS = source.rawPTS
        rawDTS = source.rawDTS
        rawDuration = source.rawDuration
        timeBase = source.timeBase
        isKeyframe = source.isKeyframe
        position = source.position
    }

    deinit {
        var pointer: UnsafeMutablePointer<AVPacket>? = raw
        av_packet_free(&pointer)
    }

    public var size: Int { Int(raw.pointee.size) }

    /// Read-only view of the payload. Valid while the packet is alive.
    public var bytes: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: raw.pointee.data, count: Int(raw.pointee.size))
    }

    public var data: Data { Data(bytes) }

    /// The underlying packet, for `avcodec_send_packet`. Must not be modified.
    var avPacket: UnsafePointer<AVPacket> { UnsafePointer(raw) }

    public var pts: MediaTime? { rawPTS.map(time) }
    public var dts: MediaTime? { rawDTS.map(time) }
    /// Presentation time, falling back to the decode time.
    public var time: MediaTime? { pts ?? dts }
    public var duration: MediaTime { time(rawDuration) }

    func time(_ value: Int64) -> MediaTime {
        MediaTime(value: value, timeBaseNum: timeBase.num, timeBaseDen: timeBase.den)
    }

    public var cmPTS: CMTime { (rawPTS ?? rawDTS).map(cmTime) ?? .invalid }
    public var cmDTS: CMTime { rawDTS.map(cmTime) ?? .invalid }
    public var cmDuration: CMTime { rawDuration > 0 ? cmTime(rawDuration) : .invalid }

    func cmTime(_ value: Int64) -> CMTime {
        CMTime(value: value * Int64(timeBase.num), timescale: timeBase.den)
    }

    /// A zero-copy block buffer over the payload. The block source retains this packet and
    /// releases it (and so the AVPacket reference) when Core Media frees the block.
    public func makeBlockBuffer() throws -> CMBlockBuffer {
        let retained = Unmanaged.passRetained(self)
        var source = CMBlockBufferCustomBlockSource(
            version: UInt32(kCMBlockBufferCustomBlockSourceVersion),
            AllocateBlock: nil,
            FreeBlock: { refCon, _, _ in
                guard let refCon else { return }
                Unmanaged<Packet>.fromOpaque(refCon).release()
            },
            refCon: retained.toOpaque()
        )
        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: UnsafeMutableRawPointer(raw.pointee.data),
            blockLength: size,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: &source,
            offsetToData: 0,
            dataLength: size,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == noErr, let block else {
            retained.release()
            throw MediaStatusError(status: status, operation: "CMBlockBufferCreateWithMemoryBlock")
        }
        return block
    }

    /// A ready compressed sample buffer for VideoToolbox, sharing the packet memory.
    public func makeSampleBuffer(format: CMFormatDescription) throws -> CMSampleBuffer {
        guard size > 0 else { throw MediaStatusError(status: -1, operation: "empty packet") }
        let block = try makeBlockBuffer()
        var timing = CMSampleTimingInfo(duration: cmDuration, presentationTimeStamp: cmPTS, decodeTimeStamp: cmDTS)
        var sampleSize = size
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw MediaStatusError(status: status, operation: "CMSampleBufferCreateReady")
        }
        if !isKeyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }
}

/// Compressed packets of the active streams, grouped by video GOP (design section 7.2).
///
/// The demuxer thread appends; decoders read through cursors. The store holds one contiguous
/// run of the file. A demuxer seek outside it resets the store and starts a new epoch, which
/// invalidates older cursors. It keeps up to 30 s or 192 MB behind the playhead and asks the
/// demuxer to read ahead until 20 s or 192 MB are buffered. An exact seek also sets a read-through
/// time: the demuxer reads at least that far whatever the limits, because the decoder needs every
/// packet from the keyframe to the target (a GOP can be longer than the read-ahead limit).
public final class PacketStore: Sendable {
    public struct Limits: Sendable, Hashable {
        public var behind: MediaTime
        public var behindBytes: Int
        public var ahead: MediaTime
        public var aheadBytes: Int

        public init(behind: MediaTime = .seconds(30), behindBytes: Int = 192 << 20, ahead: MediaTime = .seconds(20), aheadBytes: Int = 192 << 20) {
            self.behind = behind
            self.behindBytes = behindBytes
            self.ahead = ahead
            self.aheadBytes = aheadBytes
        }

        public static let standard = Limits()
    }

    /// A position in the store's video packets (decode order) or in one audio stream.
    public struct Cursor: Sendable, Hashable {
        public let epoch: UInt64
        public let streamIndex: Int
        /// Video: GOP serial. Audio: packet serial.
        fileprivate var major: Int
        /// Video: packet index inside the GOP. Audio: unused.
        fileprivate var minor: Int
    }

    public enum ReadResult: Sendable {
        case packet(Packet)
        /// Nothing buffered yet at this position; wait with `waitForChange`.
        case needMore
        case endOfStream
        /// The store was reset or the position was evicted; start a new cursor.
        case invalidated
    }

    struct GOP {
        var keyPTS: MediaTime
        var packets: [Packet] = []
        var bytes = 0
        var lastTime: MediaTime
    }

    struct StreamPackets {
        var base = 0
        var packets: [Packet] = []
        var bytes = 0
    }

    struct State {
        var epoch: UInt64 = 0
        var gopBase = 0
        var gops: [GOP] = []
        var audio: [Int: StreamPackets] = [:]
        var endOfFile = false
        var playhead: MediaTime = .zero
        /// Read at least this far past the playhead limits (an exact seek's target).
        var readThrough: MediaTime?
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var nextWaiter: UInt64 = 0
        var changeCount: UInt64 = 0
    }

    public let videoStreamIndex: Int?
    public let limits: Limits
    private let state = Mutex(State())
    // Boxed: reading a closure out of a Mutex with `withLock { $0 }` wraps it in two more
    // reabstraction thunks on every read, and the chain overflows the stack after a few thousand.
    private let wakeDemuxer = Mutex<SendableCallback<Void>?>(nil)

    public init(videoStreamIndex: Int?, limits: Limits = .standard) {
        self.videoStreamIndex = videoStreamIndex
        self.limits = limits
    }

    /// Called whenever the playhead moves so a waiting demuxer can read ahead again.
    func setDemuxerWake(_ wake: (@Sendable () -> Void)?) {
        wakeDemuxer.withLock { $0 = wake.map { wake in SendableCallback { wake() } } }
    }

    // MARK: Writing (demuxer thread)

    /// Starts a new epoch at a discontinuity. Returns the new epoch.
    @discardableResult
    func reset(playhead: MediaTime) -> UInt64 {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.epoch += 1
            state.gopBase += state.gops.count
            state.gops.removeAll()
            for key in state.audio.keys {
                let base = state.audio[key].map { $0.base + $0.packets.count } ?? 0
                state.audio[key] = StreamPackets(base: base)
            }
            state.endOfFile = false
            state.playhead = playhead
            return takeWaiters(&state)
        }
        waiters.forEach { $0.resume() }
        return epoch
    }

    /// Appends a packet. Video packets before the first keyframe of an epoch are dropped.
    func append(_ packet: Packet) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            if packet.streamIndex == videoStreamIndex {
                let time = packet.time ?? state.gops.last?.lastTime ?? .zero
                if packet.isKeyframe, let pts = packet.pts ?? packet.dts {
                    state.gops.append(GOP(keyPTS: pts, packets: [packet], bytes: packet.size, lastTime: time))
                } else if !state.gops.isEmpty {
                    let last = state.gops.count - 1
                    state.gops[last].packets.append(packet)
                    state.gops[last].bytes += packet.size
                    state.gops[last].lastTime = max(state.gops[last].lastTime, time)
                } else {
                    return []
                }
            } else {
                state.audio[packet.streamIndex, default: StreamPackets()].packets.append(packet)
                state.audio[packet.streamIndex, default: StreamPackets()].bytes += packet.size
            }
            evict(&state)
            return takeWaiters(&state)
        }
        waiters.forEach { $0.resume() }
    }

    func markEndOfFile() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.endOfFile = true
            return takeWaiters(&state)
        }
        waiters.forEach { $0.resume() }
    }

    // MARK: Playhead and limits

    /// Moves the playhead, evicts what fell more than the limit behind and wakes the demuxer.
    public func setPlayhead(_ time: MediaTime) {
        state.withLock { state in
            state.playhead = time
            evict(&state)
        }
        wakeDemuxer.withLock { $0 }?.call(())
    }

    /// Moves the playhead for a seek and replaces the read-through time: an exact seek passes
    /// its target, a scrub passes nil.
    public func setPlayhead(_ time: MediaTime, readThrough: MediaTime?) {
        state.withLock { state in
            state.playhead = time
            state.readThrough = readThrough
            evict(&state)
        }
        wakeDemuxer.withLock { $0 }?.call(())
    }

    /// Asks for about one more second of packets past the last one stored, whatever the limits.
    /// A reader that must see packets the read-ahead limit holds back (an exact seek still
    /// looking for its target frame) calls this before it waits.
    public func requestMoreData() {
        state.withLock { state in
            guard !state.endOfFile else { return }
            let next = (lastTime(state) ?? state.playhead) + .seconds(1)
            state.readThrough = max(state.readThrough ?? next, next)
        }
        wakeDemuxer.withLock { $0 }?.call(())
    }

    public var playhead: MediaTime { state.withLock { $0.playhead } }
    public var readThrough: MediaTime? { state.withLock { $0.readThrough } }
    public var epoch: UInt64 { state.withLock { $0.epoch } }
    public var isAtEndOfFile: Bool { state.withLock { $0.endOfFile } }

    /// True while less than the read-ahead limit is buffered past the playhead, or the stored
    /// packets do not reach the read-through time yet.
    public var wantsMoreData: Bool {
        state.withLock { state in
            guard !state.endOfFile else { return false }
            if let through = state.readThrough, (lastTime(state) ?? .zero) < through { return true }
            let ahead = aheadAmount(state)
            return ahead.time < limits.ahead && ahead.bytes < limits.aheadBytes
        }
    }

    private func lastTime(_ state: State) -> MediaTime? {
        var last = state.gops.last?.lastTime
        for stream in state.audio.values {
            if let time = stream.packets.last?.time { last = max(last ?? time, time) }
        }
        return last
    }

    private func aheadAmount(_ state: State) -> (time: MediaTime, bytes: Int) {
        guard let last = lastTime(state) else { return (.zero, 0) }
        var bytes = 0
        for gop in state.gops where gop.lastTime > state.playhead { bytes += gop.bytes }
        for stream in state.audio.values {
            for packet in stream.packets.reversed() {
                guard let time = packet.time, time > state.playhead else { break }
                bytes += packet.size
            }
        }
        return (last - state.playhead, bytes)
    }

    private func evict(_ state: inout State) {
        // A GOP may go only when the next one also starts at or before the playhead.
        var behindBytes = 0
        var behindCount = 0
        while behindCount + 1 < state.gops.count, state.gops[behindCount + 1].keyPTS <= state.playhead {
            behindBytes += state.gops[behindCount].bytes
            behindCount += 1
        }
        var dropped = 0
        while dropped < behindCount {
            let nextKey = state.gops[dropped + 1].keyPTS
            let tooOld = state.playhead - nextKey > limits.behind
            let tooBig = behindBytes > limits.behindBytes
            guard tooOld || tooBig else { break }
            behindBytes -= state.gops[dropped].bytes
            dropped += 1
        }
        if dropped > 0 {
            state.gops.removeFirst(dropped)
            state.gopBase += dropped
        }
        // Audio follows the retained video, or the time limit when there is no video.
        let audioFloor: MediaTime
        if videoStreamIndex != nil, let first = state.gops.first {
            audioFloor = first.keyPTS - .seconds(1)
        } else {
            audioFloor = state.playhead - limits.behind
        }
        for key in state.audio.keys {
            guard var stream = state.audio[key] else { continue }
            var drop = 0
            while drop < stream.packets.count, let time = stream.packets[drop].time, time + stream.packets[drop].duration < audioFloor {
                stream.bytes -= stream.packets[drop].size
                drop += 1
            }
            if drop > 0 {
                stream.packets.removeFirst(drop)
                stream.base += drop
                state.audio[key] = stream
            }
        }
    }

    // MARK: Queries

    /// Presentation range of the stored video GOPs (or audio when there is no video).
    public var storedRange: ClosedRange<MediaTime>? {
        state.withLock { state in
            if let first = state.gops.first, let last = state.gops.last {
                return first.keyPTS...max(first.keyPTS, last.lastTime)
            }
            let audioTimes = state.audio.values.compactMap { stream -> ClosedRange<MediaTime>? in
                guard let first = stream.packets.first?.time, let last = stream.packets.last?.time else { return nil }
                return first...max(first, last)
            }
            guard let lower = audioTimes.map(\.lowerBound).min(), let upper = audioTimes.map(\.upperBound).max() else { return nil }
            return lower...upper
        }
    }

    public var storedBytes: Int {
        state.withLock { state in
            state.gops.reduce(0) { $0 + $1.bytes } + state.audio.values.reduce(0) { $0 + $1.bytes }
        }
    }

    /// Key pts of the stored GOPs, in order.
    public var storedKeyframes: [MediaTime] { state.withLock { $0.gops.map(\.keyPTS) } }

    /// True when the GOP starting at `keyframe` is stored and the packets after it reach `time`
    /// (or the file ends first), so decoding to `time` needs no I/O.
    public func covers(keyframe: MediaTime, through time: MediaTime) -> Bool {
        state.withLock { state in
            guard state.gops.contains(where: { $0.keyPTS == keyframe }), let last = state.gops.last else { return false }
            return state.endOfFile || last.lastTime >= time
        }
    }

    /// The video packet with the largest pts at or before `time`, searching the GOP that starts at
    /// `keyframe` and the next one (open-GOP leading pictures are decoded after the next keyframe).
    public func videoFramePTS(atOrBefore time: MediaTime, fromKeyframe keyframe: MediaTime) -> MediaTime? {
        state.withLock { state in
            guard let index = state.gops.firstIndex(where: { $0.keyPTS == keyframe }) else { return nil }
            var best: MediaTime?
            for gop in state.gops[index..<min(index + 2, state.gops.count)] {
                for packet in gop.packets {
                    guard let pts = packet.pts, pts >= keyframe, pts <= time else { continue }
                    if best.map({ pts > $0 }) ?? true { best = pts }
                }
            }
            return best
        }
    }

    /// The video packet with the largest pts at or before `time` in the stored GOP that contains
    /// `time` (and the next one, for open-GOP leading pictures). Nil when no stored GOP starts at
    /// or before `time`. Exact only when the store reaches past `time`.
    public func videoFramePTS(atOrBefore time: MediaTime) -> MediaTime? {
        state.withLock { state in
            guard let index = state.gops.lastIndex(where: { $0.keyPTS <= time }) else { return nil }
            let keyframe = state.gops[index].keyPTS
            var best: MediaTime?
            for gop in state.gops[index..<min(index + 2, state.gops.count)] {
                for packet in gop.packets {
                    guard let pts = packet.pts, pts >= keyframe, pts <= time else { continue }
                    if best.map({ pts > $0 }) ?? true { best = pts }
                }
            }
            return best
        }
    }

    /// Video packets of the GOP starting at `keyframe`, in decode order (nil when not stored).
    public func gopPackets(keyframe: MediaTime) -> [Packet]? {
        state.withLock { state in state.gops.first { $0.keyPTS == keyframe }?.packets }
    }

    // MARK: Cursors

    /// A cursor at the GOP whose keyframe pts is `keyframe`.
    public func videoCursor(atKeyframe keyframe: MediaTime) -> Cursor? {
        guard let videoStreamIndex else { return nil }
        return state.withLock { state in
            guard let index = state.gops.firstIndex(where: { $0.keyPTS == keyframe }) else { return nil }
            return Cursor(epoch: state.epoch, streamIndex: videoStreamIndex, major: state.gopBase + index, minor: 0)
        }
    }

    /// A cursor at the first stored video packet of the current epoch.
    public func videoCursorAtStart() -> Cursor? {
        guard let videoStreamIndex else { return nil }
        return state.withLock { state in
            Cursor(epoch: state.epoch, streamIndex: videoStreamIndex, major: state.gopBase, minor: 0)
        }
    }

    /// A cursor at the last audio packet of `streamIndex` with pts at or before `time` (or the
    /// first stored one). Packets not read yet are reached by `next` as they arrive.
    public func audioCursor(streamIndex: Int, at time: MediaTime) -> Cursor {
        state.withLock { state in
            let stream = state.audio[streamIndex] ?? StreamPackets()
            var index = 0
            for (offset, packet) in stream.packets.enumerated() {
                guard let packetTime = packet.time else { continue }
                if packetTime <= time { index = offset } else { break }
            }
            return Cursor(epoch: state.epoch, streamIndex: streamIndex, major: stream.base + index, minor: 0)
        }
    }

    /// Reads the packet at `cursor` and advances it.
    public func next(_ cursor: inout Cursor) -> ReadResult {
        state.withLock { state in
            guard cursor.epoch == state.epoch else { return .invalidated }
            if cursor.streamIndex == videoStreamIndex {
                var gop = cursor.major - state.gopBase
                guard gop >= 0 else { return .invalidated }
                while gop < state.gops.count {
                    let packets = state.gops[gop].packets
                    if cursor.minor < packets.count {
                        let packet = packets[cursor.minor]
                        cursor.minor += 1
                        return .packet(packet)
                    }
                    guard gop + 1 < state.gops.count else { break }
                    gop += 1
                    cursor.major += 1
                    cursor.minor = 0
                }
                return state.endOfFile ? .endOfStream : .needMore
            }
            let stream = state.audio[cursor.streamIndex] ?? StreamPackets()
            let index = cursor.major - stream.base
            guard index >= 0 else { return .invalidated }
            if index < stream.packets.count {
                cursor.major += 1
                return .packet(stream.packets[index])
            }
            return state.endOfFile ? .endOfStream : .needMore
        }
    }

    /// Increments on every append, end of file and reset. Read it before `next` and pass it to
    /// `waitForChange(since:)` so a packet that arrives in between is not missed.
    public var changeCount: UInt64 { state.withLock { $0.changeCount } }

    /// Suspends until the store changes after `since` (a packet, end of file or a reset), or the
    /// task is cancelled.
    public func waitForChange(since: UInt64) async {
        let id = state.withLock { state -> UInt64 in
            defer { state.nextWaiter += 1 }
            return state.nextWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.changeCount != since || Task.isCancelled { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }

    /// Blocking variant of `next` for threads: waits up to `timeout` for a packet.
    public func nextBlocking(_ cursor: inout Cursor, timeout: Duration = .seconds(5)) -> ReadResult {
        let deadline = ContinuousClock.now + timeout
        while true {
            let result = next(&cursor)
            guard case .needMore = result, ContinuousClock.now < deadline else { return result }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private func takeWaiters(_ state: inout State) -> [CheckedContinuation<Void, Never>] {
        state.changeCount &+= 1
        let waiters = Array(state.waiters.values)
        state.waiters.removeAll()
        return waiters
    }
}
