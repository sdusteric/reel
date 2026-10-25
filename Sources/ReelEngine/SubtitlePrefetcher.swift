import CReelDeps
import Foundation
import ReelCore
import Synchronization

/// Decodes the packets of one text track into a `SubtitleTrackStore`. The prefetcher and the main
/// demuxer each feed the same track through their own feed; they agree on the charset through the
/// store, so the first one to find invalid text moves both (section 8.3).
///
/// Not thread-safe: one owner at a time.
public final class SubtitleTextFeed {
    public let track: TrackID
    public let decoder: SubtitleDecoder
    private let store: SubtitleTrackStore

    public init(decoder: SubtitleDecoder, track: TrackID, store: SubtitleTrackStore) {
        self.decoder = decoder
        self.track = track
        self.store = store
        store.begin(
            track,
            header: decoder.header,
            format: decoder.format,
            charset: decoder.charset,
            recognised: decoder.charsetRecognised,
            fontFamily: decoder.fontFamily
        )
    }

    public func feed(_ packet: Packet) throws {
        try feed(SubtitleSourcePacket(packet))
    }

    public func feed(_ packet: SubtitleSourcePacket) throws {
        try adoptStoreCharset()
        let before = decoder.charset
        switch try decoder.decodeText(packet) {
        case .added(let events):
            store.add(events, to: track)
        case .replaced(let events, let charset):
            let stored = store.charset(of: track) ?? before
            if charset != stored, decoder.charset(charset, isLaterThan: stored) {
                store.reset(track, charset: charset, recognised: decoder.charsetRecognised, header: decoder.header)
            }
            store.add(events, to: track)
        }
    }

    /// Another feed of this track already moved to a later charset: follow it.
    private func adoptStoreCharset() throws {
        guard let stored = store.charset(of: track), decoder.charset(stored, isLaterThan: decoder.charset) else { return }
        store.add(try decoder.adopt(stored), to: track)
    }
}

/// Reads every text subtitle event of a file in the background (design section 8.1, D34): a
/// second `AVFormatContext` with every other stream set to `AVDISCARD_ALL`, read through on its
/// own utility-priority thread, feeding a `SubtitleTrackStore`. Bitmap tracks are not prefetched.
public final class SubtitlePrefetcher: Sendable {
    public struct Outcome: Sendable, Hashable {
        /// Text tracks found, as embedded stream indices.
        public var streams: [Int]
        public var packets: Int
        public var cancelled: Bool
        public var error: String?
        public var elapsed: Duration
    }

    private struct WaitState {
        var outcome: Outcome?
        var waiters: [CheckedContinuation<Outcome, Never>] = []
        var started = false
    }

    public let url: URL
    private let store: SubtitleTrackStore
    private let wanted: Set<Int>?
    private let cancelled = Atomic<Bool>(false)
    private let waitState = Mutex(WaitState())

    /// - Parameter streams: the stream indices to read; nil reads every text subtitle stream.
    public init(url: URL, store: SubtitleTrackStore, streams: Set<Int>? = nil) {
        self.url = url
        self.store = store
        wanted = streams
    }

    /// Starts the background read once.
    public func start() {
        let first = waitState.withLock { state -> Bool in
            defer { state.started = true }
            return !state.started
        }
        guard first else { return }
        let thread = Thread { [self] in
            let outcome = run()
            let waiters = waitState.withLock { state -> [CheckedContinuation<Outcome, Never>] in
                state.outcome = outcome
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume(returning: outcome) }
        }
        thread.name = "reel.subtitle-prefetch"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Stops the read at the next packet or I/O wait. Events read so far stay in the store.
    public func cancel() {
        cancelled.store(true, ordering: .relaxed)
    }

    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    public var outcome: Outcome? { waitState.withLock { $0.outcome } }

    public var isFinished: Bool { outcome != nil }

    /// Waits until the read finished or was cancelled.
    public func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            let done = waitState.withLock { state -> Outcome? in
                if let outcome = state.outcome { return outcome }
                state.waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    // MARK: The read

    private func run() -> Outcome {
        let started = ContinuousClock.now
        var outcome = Outcome(streams: [], packets: 0, cancelled: false, error: nil, elapsed: .zero)
        guard var context = avformat_alloc_context() else {
            outcome.error = "avformat_alloc_context failed"
            return outcome
        }
        // Lets cancel() break out of a long read between subtitle packets.
        context.pointee.interrupt_callback.callback = { opaque in
            guard let opaque else { return 0 }
            return Unmanaged<SubtitlePrefetcher>.fromOpaque(opaque).takeUnretainedValue().isCancelled ? 1 : 0
        }
        context.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(self).toOpaque()
        var optional: UnsafeMutablePointer<AVFormatContext>? = context
        let status = avformat_open_input(&optional, url.path(percentEncoded: false), nil, nil)
        guard status >= 0, let opened = optional else {
            // avformat_open_input frees the context on failure.
            outcome.cancelled = isCancelled
            if !outcome.cancelled { outcome.error = FFmpegError(code: status, operation: "avformat_open_input").description }
            outcome.elapsed = ContinuousClock.now - started
            return outcome
        }
        context = opened
        defer {
            var closing: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&closing)
        }
        var feeds: [Int: SubtitleTextFeed] = [:]
        for index in 0..<Int(context.pointee.nb_streams) {
            guard let stream = context.pointee.streams[index] else { continue }
            if let feed = makeFeed(stream, index: index) {
                feeds[index] = feed
            } else {
                stream.pointee.discard = AVDISCARD_ALL
            }
        }
        outcome.streams = feeds.keys.sorted()
        if !feeds.isEmpty {
            outcome.packets = read(context, feeds: feeds, error: &outcome.error)
        }
        outcome.cancelled = isCancelled
        if !outcome.cancelled, outcome.error == nil {
            for index in outcome.streams { store.markComplete(.embedded(streamIndex: index)) }
        }
        outcome.elapsed = ContinuousClock.now - started
        return outcome
    }

    private func makeFeed(_ stream: UnsafeMutablePointer<AVStream>, index: Int) -> SubtitleTextFeed? {
        let parameters = stream.pointee.codecpar.pointee
        guard parameters.codec_type == AVMEDIA_TYPE_SUBTITLE, wanted?.contains(index) ?? true else { return nil }
        let format = SubtitleFormat(codec: String(cString: avcodec_get_name(parameters.codec_id)))
        guard format.isText else { return nil }
        var title: String?
        if let entry = av_dict_get(stream.pointee.metadata, "title", nil, 0), let value = entry.pointee.value {
            title = String(cString: value)
        }
        var language: String?
        if let entry = av_dict_get(stream.pointee.metadata, "language", nil, 0), let value = entry.pointee.value {
            language = String(cString: value)
        }
        guard let decoder = try? SubtitleDecoder(
            parameters: stream.pointee.codecpar,
            streamIndex: index,
            timeBase: Rational(stream.pointee.time_base.num, stream.pointee.time_base.den),
            fileName: url.lastPathComponent,
            title: title,
            language: language,
            charset: store.charset(of: .embedded(streamIndex: index))
        ) else { return nil }
        return SubtitleTextFeed(decoder: decoder, track: .embedded(streamIndex: index), store: store)
    }

    private func read(_ context: UnsafeMutablePointer<AVFormatContext>, feeds: [Int: SubtitleTextFeed], error: inout String?) -> Int {
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else {
            error = "av_packet_alloc failed"
            return 0
        }
        var count = 0
        while !isCancelled {
            let status = av_read_frame(context, packet)
            if status == reel_averror_eof() { break }
            if status == reel_averror_eagain() { continue }
            if status < 0 {
                if !isCancelled { error = FFmpegError(code: status, operation: "av_read_frame").description }
                break
            }
            defer { av_packet_unref(packet) }
            guard let feed = feeds[Int(packet.pointee.stream_index)] else { continue }
            let noValue = reel_av_nopts()
            let source = SubtitleSourcePacket(
                data: packet.pointee.data.map { Data(bytes: $0, count: Int(packet.pointee.size)) } ?? Data(),
                pts: packet.pointee.pts == noValue ? nil : packet.pointee.pts,
                duration: packet.pointee.duration
            )
            // A malformed event is skipped; the rest of the track plays (section 8.7).
            try? feed.feed(source)
            count += 1
        }
        return count
    }
}
