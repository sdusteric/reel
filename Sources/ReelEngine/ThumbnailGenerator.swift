import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ReelCore
import Synchronization
import VideoToolbox

/// Seek-bar thumbnails from keyframes only (design section 9.4, D38).
///
/// A background thread at utility priority opens its own `MediaSource` and its own
/// `VTDecompressionSession` (BGRA, 384 wide, VideoToolbox scales), takes the keyframe list from the
/// container index, plans at most 400 of them and decodes them coarse to fine with up to four
/// frames in flight. Each frame becomes a JPEG (quality 0.75) in a `ThumbnailPack` stored in the
/// `ThumbnailCache`. Codecs VideoToolbox cannot decode go through `SoftwareVideoDecoder`.
///
/// The engine calls `pause()` and `resume()` around seeks, so thumbnails never compete with a seek
/// for the disk or the decoder, and `close()` when the file closes; a stopped run leaves a partial
/// pack that the next run resumes.
public final class ThumbnailGenerator: Sendable {
    public struct Options: Sendable, Hashable {
        public var width: Int
        public var maximumCount: Int
        public var jpegQuality: Double
        public var maximumInFlight: Int
        /// Forces a decoder; nil uses VideoToolbox when it can decode the codec.
        public var decoder: VideoDecoderKind?
        /// A partial pack is written after this many new thumbnails, so a crash loses little.
        public var partialSaveInterval: Int

        public init(
            width: Int = ThumbnailPack.standardWidth,
            maximumCount: Int = ThumbnailPack.maximumCount,
            jpegQuality: Double = 0.75,
            maximumInFlight: Int = 4,
            decoder: VideoDecoderKind? = nil,
            partialSaveInterval: Int = 64
        ) {
            self.width = width
            self.maximumCount = maximumCount
            self.jpegQuality = jpegQuality
            self.maximumInFlight = maximumInFlight
            self.decoder = decoder
            self.partialSaveInterval = partialSaveInterval
        }

        public static let standard = Options()
    }

    public enum Outcome: String, Sendable, Hashable {
        case completed, cancelled, failed
    }

    /// Timing of one thumbnail, on the uptime clock in nanoseconds.
    public struct Completion: Sendable, Hashable {
        public var slot: Int
        public var pts: MediaTime
        /// When reading its keyframe packet started.
        public var startedNanos: UInt64
        /// When its JPEG was stored.
        public var finishedNanos: UInt64
    }

    public struct Report: Sendable {
        public var outcome: Outcome
        public var error: String?
        public var decoder: VideoDecoderKind?
        public var codec: String?
        /// Keyframes known to the generator (container index, or a scan without one).
        public var keyframesTotal = 0
        /// Thumbnails planned: min(keyframesTotal, maximumCount).
        public var planned = 0
        /// Decoded in this run.
        public var generated = 0
        /// Taken from a partial pack of an earlier run.
        public var resumed = 0
        /// The finished pack was loaded from the cache; nothing was decoded.
        public var fromCache = false
        public var failedSlots = 0
        /// Times VideoToolbox failed and software decode took over.
        public var softwareFallbacks = 0
        public var width = 0
        public var height = 0
        public var startedNanos: UInt64 = 0
        /// Open, format description, decoder session and its priming decode.
        public var setupNanos: UInt64?
        /// Parts of setup: `MediaSource` open, first packets and format description, decoder
        /// session, and the priming decode of the first keyframe (VideoToolbox only).
        public var openNanos: UInt64?
        public var formatNanos: UInt64?
        public var sessionNanos: UInt64?
        public var primeNanos: UInt64?
        /// Keyframe list and plan (a full scan only when the container has no complete index).
        public var planNanos: UInt64?
        public var firstSubmitNanos: UInt64?
        public var finishedNanos: UInt64 = 0
        /// In completion order.
        public var completions: [Completion] = []

        init(outcome: Outcome) {
            self.outcome = outcome
        }

        public var setupMilliseconds: Double? { setupNanos.map { Double($0) / 1e6 } }

        /// For the k-th completion: time from the first submit to it, divided by k.
        public var amortisedMilliseconds: [Double] {
            guard let first = firstSubmitNanos else { return [] }
            return completions.enumerated().map { index, completion in
                Double(completion.finishedNanos &- first) / 1e6 / Double(index + 1)
            }
        }

        /// From the start of reading each thumbnail's keyframe to its stored JPEG.
        public var latencyMilliseconds: [Double] {
            completions.map { Double($0.finishedNanos &- $0.startedNanos) / 1e6 }
        }

        /// From the first submit to the last completion.
        public var totalMilliseconds: Double? {
            guard let first = firstSubmitNanos, let last = completions.map(\.finishedNanos).max() else { return nil }
            return Double(last &- first) / 1e6
        }
    }

    public let url: URL
    public let key: ContentKey?
    public let cache: ThumbnailCache?
    public let options: Options
    private let shared: ThumbnailShared

    /// - Parameters:
    ///   - key: the file's content key; with `cache`, packs are loaded from and stored there.
    public init(url: URL, key: ContentKey?, cache: ThumbnailCache?, options: Options = .standard) {
        self.url = url
        self.key = key
        self.cache = cache
        self.options = options
        shared = ThumbnailShared(maximumInFlight: max(1, options.maximumInFlight))
    }

    deinit {
        close()
    }

    /// Starts generation on a background thread. Later calls do nothing.
    /// - Parameter progress: called with (done, total) after each stored thumbnail, on a
    ///   background queue.
    public func start(progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) {
        guard shared.markStarted(progress: progress) else { return }
        let shared = self.shared
        let url = self.url
        let key = self.key
        let cache = self.cache
        let options = self.options
        let thread = Thread {
            let worker = ThumbnailWorker(url: url, key: key, cache: cache, options: options, shared: shared)
            shared.finish(worker.run())
        }
        thread.name = "reel.thumbnails"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Stops submitting keyframes until the matching `resume()`; frames in flight still finish.
    /// Calls nest.
    public func pause() {
        shared.adjustPause(by: 1)
    }

    public func resume() {
        shared.adjustPause(by: -1)
    }

    /// Cancels generation. Returns at once; the thread stores a partial pack and exits.
    public func close() {
        shared.cancel()
    }

    /// Waits for the run to end (completed, cancelled or failed). Returns at once when it never
    /// started.
    public func finished() async -> Report {
        await shared.waitForReport()
    }

    /// The report once the run has ended.
    public var report: Report? { shared.state.withLock { $0.report } }

    /// Thumbnails stored and planned so far.
    public var progress: (done: Int, total: Int) {
        shared.state.withLock { ($0.done, $0.total) }
    }

    /// Thumbnail pixel size (0 until the file is open).
    public var size: (width: Int, height: Int) {
        shared.state.withLock { ($0.width, $0.height) }
    }

    /// The thumbnail of the last planned keyframe at or before `time`. While that one is not ready
    /// yet, the nearest earlier ready one within the coarse stride stands in; otherwise nil.
    public func thumbnail(at time: MediaTime) -> ThumbnailImage? {
        shared.state.withLock { state in
            if let pack = state.pack { return pack.thumbnail(atOrBefore: time) }
            guard let plan = state.plan, let slot = plan.slot(for: time) else { return nil }
            for candidate in stride(from: slot, through: max(0, slot - ThumbnailShared.standInStride + 1), by: -1) {
                if let image = state.images[candidate] { return image }
            }
            return nil
        }
    }

    /// Every stored thumbnail as a pack.
    public func pack() -> ThumbnailPack? {
        shared.snapshot()
    }

    // MARK: Testing

    /// Tests: decoded frames wait before their JPEG encode until `releaseEncodesForTesting()`, so
    /// they stay in flight and the run cannot finish. Call before `start`.
    func holdEncodesForTesting() {
        shared.setEncodesHeld(true)
    }

    func releaseEncodesForTesting() {
        shared.setEncodesHeld(false)
    }

    /// Tests: frames submitted and not yet stored.
    var inFlightForTesting: Int { shared.state.withLock { $0.inFlight } }

    /// Tests: each time generation paused (from running), with the frames then in flight.
    var pausesForTesting: [ThumbnailShared.PauseRecord] { shared.state.withLock { $0.pauses } }
}

// MARK: Shared state

/// State shared by the handle, the worker thread, the decoder callbacks and the encode queue.
final class ThumbnailShared: Sendable {
    /// A missing thumbnail is stood in for by a ready one at most this many slots earlier (the
    /// first coarse pass fills every 8th slot).
    static let standInStride = 8

    struct State {
        var started = false
        var progress: (@Sendable (Int, Int) -> Void)?
        var plan: ThumbnailPlan?
        var images: [ThumbnailImage?] = []
        var pack: ThumbnailPack?
        var width = 0
        var height = 0
        var done = 0
        var total = 0
        var completions: [ThumbnailGenerator.Completion] = []
        var pauseCount = 0
        var pauses: [PauseRecord] = []
        var encodesHeld = false
        var cancelled = false
        var inFlight = 0
        var report: ThumbnailGenerator.Report?
        var waiters: [CheckedContinuation<ThumbnailGenerator.Report, Never>] = []
    }

    struct PauseRecord: Sendable {
        var nanos: UInt64
        var inFlight: Int
    }

    let state = Mutex(State())
    let condition = NSCondition()
    let maximumInFlight: Int

    init(maximumInFlight: Int) {
        self.maximumInFlight = maximumInFlight
    }

    func markStarted(progress: (@Sendable (Int, Int) -> Void)?) -> Bool {
        state.withLock { state in
            guard !state.started else { return false }
            state.started = true
            state.progress = progress
            return true
        }
    }

    private func broadcast() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    func adjustPause(by delta: Int) {
        state.withLock { state in
            if state.pauseCount == 0, delta > 0 {
                state.pauses.append(PauseRecord(nanos: DispatchTime.now().uptimeNanoseconds, inFlight: state.inFlight))
            }
            state.pauseCount = max(0, state.pauseCount + delta)
        }
        broadcast()
    }

    func setEncodesHeld(_ held: Bool) {
        state.withLock { $0.encodesHeld = held }
        broadcast()
    }

    /// Blocks while a test holds encodes. Cancellation lets them through.
    func waitWhileEncodesHeld() {
        condition.lock()
        defer { condition.unlock() }
        while state.withLock({ $0.encodesHeld && !$0.cancelled }) {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.25))
        }
    }

    func cancel() {
        state.withLock { $0.cancelled = true }
        broadcast()
    }

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// Blocks while paused. Returns false when cancelled.
    func waitWhilePaused() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while true {
            let (paused, cancelled) = state.withLock { ($0.pauseCount > 0, $0.cancelled) }
            if cancelled { return false }
            if !paused { return true }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.25))
        }
    }

    enum Acquire {
        case acquired, cancelled, timedOut
    }

    /// Takes one in-flight slot, waiting at most `timeout` for a frame to finish.
    func acquire(timeout: TimeInterval) -> Acquire {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            let result: Acquire? = state.withLock { state in
                if state.cancelled { return .cancelled }
                if state.inFlight < maximumInFlight {
                    state.inFlight += 1
                    return .acquired
                }
                return nil
            }
            if let result { return result }
            if !condition.wait(until: deadline) { return .timedOut }
        }
    }

    func release() {
        state.withLock { $0.inFlight = max(0, $0.inFlight - 1) }
        broadcast()
    }

    /// Blocks until no frame is in flight or `timeout` passes.
    func waitUntilIdle(timeout: TimeInterval) {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while state.withLock({ $0.inFlight > 0 }) {
            if !condition.wait(until: deadline) { return }
        }
    }

    func begin(plan: ThumbnailPlan, width: Int, height: Int) {
        state.withLock { state in
            state.plan = plan
            state.images = Array(repeating: nil, count: plan.count)
            state.width = width
            state.height = height
            state.total = plan.count
        }
    }

    func install(pack: ThumbnailPack) {
        let progress = state.withLock { state -> (@Sendable (Int, Int) -> Void)? in
            state.pack = pack
            state.width = pack.width
            state.height = pack.height
            state.done = pack.count
            state.total = pack.count
            return state.progress
        }
        progress?(pack.count, pack.count)
    }

    func hasImage(_ slot: Int) -> Bool {
        state.withLock { slot < $0.images.count && $0.images[slot] != nil }
    }

    /// Stores a thumbnail. `completion` is nil for one resumed from a partial pack.
    func store(_ image: ThumbnailImage, slot: Int, completion: ThumbnailGenerator.Completion?) {
        let update = state.withLock { state -> (@Sendable (Int, Int) -> Void, Int, Int)? in
            guard slot < state.images.count, state.images[slot] == nil else { return nil }
            state.images[slot] = image
            state.done += 1
            if let completion { state.completions.append(completion) }
            return state.progress.map { ($0, state.done, state.total) }
        }
        if let (progress, done, total) = update { progress(done, total) }
    }

    var done: Int { state.withLock { $0.done } }
    var completions: [ThumbnailGenerator.Completion] { state.withLock { $0.completions } }

    func snapshot() -> ThumbnailPack? {
        state.withLock { state in
            if let pack = state.pack { return pack }
            guard state.plan != nil else { return nil }
            let images = state.images.compactMap { $0 }.map { (pts: $0.pts, jpeg: $0.jpeg) }
            return ThumbnailPack(width: state.width, height: state.height, images: images)
        }
    }

    func finish(_ report: ThumbnailGenerator.Report) {
        let waiters = state.withLock { state -> [CheckedContinuation<ThumbnailGenerator.Report, Never>] in
            state.report = report
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        waiters.forEach { $0.resume(returning: report) }
        broadcast()
    }

    func waitForReport() async -> ThumbnailGenerator.Report {
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { state -> ThumbnailGenerator.Report? in
                if let report = state.report { return report }
                if !state.started { return ThumbnailGenerator.Report(outcome: .cancelled) }
                state.waiters.append(continuation)
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
}

// MARK: Encoding

/// Turns decoded BGRA frames into JPEGs on a serial utility queue and settles each in-flight slot
/// exactly once.
final class ThumbnailSink: Sendable {
    let shared: ThumbnailShared
    let queue = DispatchQueue(label: "reel.thumbnails.encode", qos: .utility)
    let rotation: Int
    let quality: Double
    let width: Int
    let height: Int
    private let settled = Mutex<Set<Int>>([])
    private let failures = Mutex<[Int]>([])

    init(shared: ThumbnailShared, rotation: Int, quality: Double, width: Int, height: Int) {
        self.shared = shared
        self.rotation = rotation
        self.quality = quality
        self.width = width
        self.height = height
    }

    private func settle(_ slot: Int) -> Bool {
        settled.withLock { $0.insert(slot).inserted }
    }

    /// Lets `slot` be submitted again (a retry with another decoder).
    func reopen(_ slot: Int) {
        settled.withLock { _ = $0.remove(slot) }
    }

    func deliver(slot: Int, pts: MediaTime, frame: CVReadOnlyPixelBuffer, startedNanos: UInt64) {
        guard settle(slot) else { return }
        queue.async { [self] in
            defer { shared.release() }
            shared.waitWhileEncodesHeld()
            guard let jpeg = try? ThumbnailSink.encode(frame, rotation: rotation, quality: quality) else {
                failures.withLock { $0.append(slot) }
                return
            }
            let image = ThumbnailImage(jpeg: jpeg, pts: pts, width: width, height: height)
            let completion = ThumbnailGenerator.Completion(slot: slot, pts: pts, startedNanos: startedNanos, finishedNanos: DispatchTime.now().uptimeNanoseconds)
            shared.store(image, slot: slot, completion: completion)
        }
    }

    func fail(slot: Int) {
        guard settle(slot) else { return }
        failures.withLock { $0.append(slot) }
        shared.release()
    }

    /// Failed slots since the last call.
    func takeFailures() -> [Int] {
        failures.withLock { list in
            defer { list.removeAll() }
            return list
        }
    }

    var failureCount: Int { failures.withLock { $0.count } }

    /// Waits for every queued encode.
    func flush() {
        queue.sync {}
    }

    static func encode(_ frame: CVReadOnlyPixelBuffer, rotation: Int, quality: Double) throws -> Data {
        var image = try FrameGrabber.image(from: frame)
        if rotation != 0 { image = try rotated(image, clockwise: rotation) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            throw EngineError.decoderFailed("no JPEG encoder")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EngineError.decoderFailed("JPEG encode failed") }
        return data as Data
    }

    /// `image` turned `clockwise` degrees (90, 180 or 270), as the display matrix asks.
    static func rotated(_ image: CGImage, clockwise: Int) throws -> CGImage {
        let quarter = clockwise == 90 || clockwise == 270
        let width = quarter ? image.height : image.width
        let height = quarter ? image.width : image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw EngineError.decoderFailed("no context to rotate a thumbnail") }
        // Core Graphics is y-up and positive angles turn counterclockwise.
        switch clockwise {
        case 90:
            context.translateBy(x: 0, y: CGFloat(height))
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: CGFloat(width), y: CGFloat(height))
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: CGFloat(width), y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw EngineError.decoderFailed("thumbnail rotation failed") }
        return result
    }
}

// MARK: Worker

/// The generation thread's state. Lives on that thread only.
private final class ThumbnailWorker {
    /// A keyframe read after a seek counts as the planned one when its pts is at most this much
    /// earlier (mp4 index times are dts plus an estimated reorder delay).
    static let landingTolerance = MediaTime.milliseconds(250)
    /// How long a submit waits for a free in-flight slot before asking VideoToolbox to emit
    /// frames it may be holding.
    static let inFlightWait: TimeInterval = 0.25

    let url: URL
    let key: ContentKey?
    let cache: ThumbnailCache?
    let options: ThumbnailGenerator.Options
    let shared: ThumbnailShared

    private var source: MediaSource?
    private var videoIndex = 0
    private var format: VideoFormat?
    private var parameters: CodecParameters?
    private var session: VTDecompressionSession?
    private var software: SoftwareThumbnailDecoder?
    private var sink: ThumbnailSink?
    /// The first keyframe packet, read at open; used for its slot without a seek.
    private var openingKeyframe: Packet?
    /// The first keyframe decoded during setup, so the session's first-frame cost is paid there;
    /// its slot then only needs the JPEG encode.
    private var primed: (packet: Packet, frame: CVReadOnlyPixelBuffer)?
    private var report = ThumbnailGenerator.Report(outcome: .completed)
    private var decodeWidth = 0
    private var decodeHeight = 0

    init(url: URL, key: ContentKey?, cache: ThumbnailCache?, options: ThumbnailGenerator.Options, shared: ThumbnailShared) {
        self.url = url
        self.key = key
        self.cache = cache
        self.options = options
        self.shared = shared
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        software?.invalidate()
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func run() -> ThumbnailGenerator.Report {
        report.startedNanos = ThumbnailWorker.now()
        // Set here, not in a defer inside `perform`: a defer runs after the returned copy is taken.
        perform()
        report.finishedNanos = ThumbnailWorker.now()
        return report
    }

    private func perform() {
        if let key, let cache, let pack = cache.load(key) {
            shared.install(pack: pack)
            report.fromCache = true
            report.planned = pack.count
            report.width = pack.width
            report.height = pack.height
            return
        }
        do {
            try open()
            report.setupNanos = ThumbnailWorker.now() &- report.startedNanos
            let planStart = ThumbnailWorker.now()
            let plan = try makePlan()
            report.planNanos = ThumbnailWorker.now() &- planStart
            shared.begin(plan: plan, width: report.width, height: report.height)
            report.planned = plan.count
            resumePartial(plan)
            try generate(plan)
        } catch {
            report.outcome = shared.isCancelled ? .cancelled : .failed
            report.error = String(describing: error)
        }
        settle()
        report.completions = shared.completions
        report.generated = report.completions.count
        if shared.isCancelled, report.outcome == .completed, shared.done < report.planned { report.outcome = .cancelled }
        save(complete: report.outcome == .completed)
    }

    // MARK: Open

    private func open() throws {
        var mark = ThumbnailWorker.now()
        func lap() -> UInt64 {
            let now = ThumbnailWorker.now()
            defer { mark = now }
            return now &- mark
        }
        let source = try MediaSource(url: url)
        report.openNanos = lap()
        guard let videoIndex = source.videoStreamIndex, let stream = source.stream(videoIndex) else {
            throw EngineError.noPlayableStream
        }
        self.source = source
        self.videoIndex = videoIndex
        parameters = try CodecParameters(copying: stream)
        // The first keyframe gives the first thumbnail without a seek, and Annex B parameter sets.
        var bytes = 0
        while openingKeyframe == nil, bytes < 32 << 20, let packet = try source.readPacket() {
            bytes += packet.size
            if packet.streamIndex == videoIndex, packet.isKeyframe { openingKeyframe = packet }
        }
        // Without packets the builder skips its first-frame colour probe (a software decode of
        // 50 to 80 ms here); thumbnails take the stream's colour fields or the HD default.
        let format: VideoFormat
        do {
            format = try FormatDescriptionBuilder.make(stream: stream, firstPackets: [])
        } catch {
            // Annex B without parameter sets in extradata: they come from the key packet.
            format = try FormatDescriptionBuilder.make(stream: stream, firstPackets: openingKeyframe.map { [$0] } ?? [])
        }
        self.format = format
        report.codec = format.codecName
        computeSizes(format)
        report.formatNanos = lap()

        let sink = ThumbnailSink(shared: shared, rotation: format.rotation, quality: options.jpegQuality, width: report.width, height: report.height)
        self.sink = sink
        if options.decoder != .software, format.formatDescription != nil {
            if format.codec == .vp9 { FormatDescriptionBuilder.registerSupplementalDecoders() }
            do {
                session = try makeSession(format)
                report.decoder = .hardware
            } catch {
                if options.decoder == .hardware { throw error }
            }
        } else if options.decoder == .hardware {
            throw EngineError.unsupportedCodec("\(format.codecName) has no VideoToolbox format description")
        }
        if session == nil {
            software = try makeSoftware()
            report.decoder = .software
        }
        report.sessionNanos = lap()
        if let session { prime(session) }
        report.primeNanos = lap()
    }

    /// Decodes the first keyframe once, synchronously. A new VideoToolbox session's first frame
    /// costs several times a later one (18 ms for the 1.27 MB H.264 fixture keyframe, in a cold
    /// process more); without this the first window of thumbnails waits behind it.
    private func prime(_ session: VTDecompressionSession) {
        guard let opening = openingKeyframe, let format, let description = format.formatDescription,
              let sample = try? format.prepare(opening).makeSampleBuffer(format: description) else { return }
        let output = PrimedFrame()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
            if status == noErr, let imageBuffer { output.frame.withLock { $0 = CVReadOnlyPixelBuffer(fresh: imageBuffer) } }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if status == noErr, let frame = output.frame.withLock({ $0 }) { primed = (opening, frame) }
    }

    /// Thumbnail size: `options.width` wide, height from the display aspect (pixel aspect and
    /// rotation), even. The decoder outputs the unrotated size.
    private func computeSizes(_ format: VideoFormat) {
        let pixelAspect = format.pixelAspect.map { $0.isValid ? $0.doubleValue : 1 } ?? 1
        var displayWidth = Double(format.width) * pixelAspect
        var displayHeight = Double(format.height)
        let quarterTurn = format.rotation == 90 || format.rotation == 270
        if quarterTurn { swap(&displayWidth, &displayHeight) }
        let width = max(2, options.width)
        let height = max(2, Int((Double(width) * displayHeight / max(displayWidth, 1) / 2).rounded()) * 2)
        report.width = width
        report.height = height
        decodeWidth = quarterTurn ? height : width
        decodeHeight = quarterTurn ? width : height
    }

    private func makeSession(_ format: VideoFormat) throws -> VTDecompressionSession {
        guard let description = format.formatDescription else { throw EngineError.unsupportedCodec(format.codecName) }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: decodeWidth,
            kCVPixelBufferHeightKey: decodeHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw MediaStatusError(status: status, operation: "VTDecompressionSessionCreate(\(format.codecName) thumbnails)")
        }
        // Background work: no real-time deadline.
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        return session
    }

    private func makeSoftware() throws -> SoftwareThumbnailDecoder {
        guard let parameters, let format else { throw EngineError.notOpen }
        return try SoftwareThumbnailDecoder(parameters: parameters, format: format, width: decodeWidth, height: decodeHeight)
    }

    // MARK: Plan

    private func makePlan() throws -> ThumbnailPlan {
        guard let source else { throw EngineError.notOpen }
        var offset = MediaTime.zero
        if let pts = openingKeyframe?.pts, let dts = openingKeyframe?.dts { offset = pts - dts }
        var keyframes = source.indexedKeyframes(ptsOffset: offset).map(\.pts)
        if !ThumbnailWorker.indexIsComplete(keyframes, source: source) {
            keyframes = try scanKeyframes(source)
        }
        if let first = openingKeyframe?.time, !keyframes.contains(first) {
            // Index times can be a little off the real pts (dts plus an estimate): the first
            // keyframe's real pts replaces its estimate.
            let nearest = keyframes.indices.min { abs((keyframes[$0] - first).microseconds) < abs((keyframes[$1] - first).microseconds) }
            if let nearest, abs((keyframes[nearest] - first).microseconds) <= ThumbnailWorker.landingTolerance.microseconds {
                keyframes[nearest] = first
            } else {
                keyframes.append(first)
            }
        }
        let unique = Set(keyframes)
        report.keyframesTotal = unique.count
        return ThumbnailPlan(keyframes: Array(unique), duration: source.duration, maximumCount: options.maximumCount)
    }

    /// The same rule the demuxer uses: mp4 and mov index every sync sample; other containers count
    /// as complete when the index reaches the end of the file.
    static func indexIsComplete(_ keyframes: [MediaTime], source: MediaSource) -> Bool {
        if source.formatName.contains("mp4") || source.formatName.contains("mov") { return !keyframes.isEmpty }
        guard keyframes.count >= 2, let duration = source.duration else { return false }
        let sorted = keyframes.sorted()
        guard let last = sorted.last else { return false }
        let largestGap = zip(sorted.dropFirst(), sorted).map { $0 - $1 }.max() ?? .zero
        let end = (source.startTime ?? .zero) + duration
        return last + max(largestGap, .seconds(1)) + .seconds(1) >= end
    }

    /// Reads the whole file for key packets (mkv without Cues, mpegts, flv): slow, but only for
    /// files whose container lists no keyframes.
    private func scanKeyframes(_ source: MediaSource) throws -> [MediaTime] {
        try source.rewind()
        var keyframes: [MediaTime] = []
        while !shared.isCancelled, let packet = try source.readPacket() {
            if packet.streamIndex == videoIndex, packet.isKeyframe, let time = packet.time { keyframes.append(time) }
        }
        return keyframes
    }

    private func resumePartial(_ plan: ThumbnailPlan) {
        guard let key, let cache, let partial = cache.loadPartial(key),
              partial.width == report.width, partial.height == report.height else { return }
        for index in 0..<partial.count {
            let image = partial.image(at: index)
            guard let slot = plan.slot(for: image.pts + ThumbnailWorker.landingTolerance),
                  abs((plan.times[slot] - image.pts).microseconds) <= ThumbnailWorker.landingTolerance.microseconds,
                  !shared.hasImage(slot) else { continue }
            shared.store(image, slot: slot, completion: nil)
            report.resumed += 1
        }
    }

    // MARK: Generate

    private func generate(_ plan: ThumbnailPlan) throws {
        var doneAtLastSave = shared.done
        let pending = plan.order.filter { !shared.hasImage($0) }
        let opening = Array(pending.prefix(options.maximumInFlight))
        try submitOpening(opening, plan: plan)
        for slot in pending.dropFirst(opening.count) where !shared.hasImage(slot) {
            guard shared.waitWhilePaused() else { return }
            if session != nil, shared.done == report.resumed, sink?.failureCount ?? 0 >= 3 {
                // VideoToolbox failed every frame so far: software for the rest.
                try switchToSoftware()
            }
            try submit(slot: slot, time: plan.times[slot])
            if shared.done - doneAtLastSave >= options.partialSaveInterval, cache != nil {
                save(complete: false)
                doneAtLastSave = shared.done
            }
        }
        settle()
        // Retry what the hardware decoder failed with software, once.
        guard let sink else { return }
        let failed = sink.takeFailures()
        guard !failed.isEmpty, !shared.isCancelled else { return }
        if software == nil, format?.codec != .other {
            software = try? makeSoftware()
            if software != nil { report.softwareFallbacks += 1 }
        }
        guard software != nil else {
            report.failedSlots = failed.count
            return
        }
        let hardware = session
        session = nil
        defer { session = hardware }
        for slot in failed where !shared.isCancelled {
            sink.reopen(slot)
            try submit(slot: slot, time: plan.times[slot])
        }
        settle()
        report.failedSlots = sink.takeFailures().count
    }

    private func switchToSoftware() throws {
        settle()
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        software = try makeSoftware()
        report.decoder = .software
        report.softwareFallbacks += 1
        // The slots that failed so far are retried after the main pass.
    }

    /// The first window: every keyframe is read before any is decoded, then the smallest goes
    /// first. The decoder returns frames in submission order and its time grows with the packet
    /// size (a 1.3 MB H.264 intra frame takes 18 ms, a 340 KB one 7 ms), so one large opening
    /// keyframe would otherwise hold back every thumbnail behind it.
    private func submitOpening(_ slots: [Int], plan: ThumbnailPlan) throws {
        guard !slots.isEmpty, shared.waitWhilePaused() else { return }
        var reads: [(slot: Int, time: MediaTime, packet: Packet?, started: UInt64)] = []
        for slot in slots {
            let started = ThumbnailWorker.now()
            if report.firstSubmitNanos == nil { report.firstSubmitNanos = started }
            // A slot whose keyframe cannot be read fails alone; the others still get thumbnails.
            reads.append((slot, plan.times[slot], try? readKeyframe(at: plan.times[slot]), started))
        }
        for read in reads.sorted(by: { ($0.packet?.size ?? 0) < ($1.packet?.size ?? 0) }) {
            guard acquireSlot() else { return }
            dispatch(slot: read.slot, time: read.time, packet: read.packet, started: read.started)
        }
    }

    /// Takes an in-flight slot. False when cancelled.
    private func acquireSlot() -> Bool {
        while true {
            switch shared.acquire(timeout: ThumbnailWorker.inFlightWait) {
            case .acquired:
                return true
            case .cancelled:
                return false
            case .timedOut:
                if let session { VTDecompressionSessionFinishDelayedFrames(session) }
            }
        }
    }

    /// Reads, decodes and encodes one planned keyframe. Returns once the packet is submitted.
    private func submit(slot: Int, time: MediaTime) throws {
        guard sink != nil, format != nil else { throw EngineError.notOpen }
        guard acquireSlot() else { return }
        let started = ThumbnailWorker.now()
        if report.firstSubmitNanos == nil { report.firstSubmitNanos = started }
        // A slot whose keyframe cannot be read fails alone; the others still get thumbnails.
        dispatch(slot: slot, time: time, packet: try? readKeyframe(at: time), started: started)
    }

    /// Decodes and encodes one keyframe packet read for `slot`; nil fails the slot.
    private func dispatch(slot: Int, time: MediaTime, packet found: Packet?, started: UInt64) {
        guard let sink, let format else { return }
        guard let found else {
            sink.fail(slot: slot)
            return
        }
        if let primed, primed.packet === found, session != nil {
            self.primed = nil
            sink.deliver(slot: slot, pts: found.time ?? time, frame: primed.frame, startedNanos: started)
            return
        }
        let packet = format.prepare(found)
        let pts = packet.time ?? time
        if let session {
            decodeHardware(session, packet: packet, slot: slot, pts: pts, started: started, sink: sink)
        } else if let software {
            if let frame = software.decode(packet) {
                sink.deliver(slot: slot, pts: pts, frame: frame, startedNanos: started)
            } else {
                sink.fail(slot: slot)
            }
        } else {
            sink.fail(slot: slot)
        }
    }

    private func decodeHardware(_ session: VTDecompressionSession, packet: Packet, slot: Int, pts: MediaTime, started: UInt64, sink: ThumbnailSink) {
        guard let description = format?.formatDescription, let sample = try? packet.makeSampleBuffer(format: description) else {
            sink.fail(slot: slot)
            return
        }
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            if status == noErr, let imageBuffer {
                sink.deliver(slot: slot, pts: pts, frame: CVReadOnlyPixelBuffer(fresh: imageBuffer), startedNanos: started)
            } else {
                sink.fail(slot: slot)
            }
        }
        if status != noErr { sink.fail(slot: slot) }
    }

    /// The keyframe packet at `time`: a seek, then the key packet it lands on, or the first one at
    /// or after `time` minus the tolerance when the seek landed on an earlier keyframe.
    private func readKeyframe(at time: MediaTime) throws -> Packet? {
        if let opening = openingKeyframe, let openingTime = opening.time,
           abs((openingTime - time).microseconds) <= ThumbnailWorker.landingTolerance.microseconds {
            openingKeyframe = nil
            return opening
        }
        guard let source else { throw EngineError.notOpen }
        let landing = try source.seekVerified(toKeyframe: time)
        var best = landing.last { $0.streamIndex == videoIndex && $0.isKeyframe }
        let earliest = time - ThumbnailWorker.landingTolerance
        if let found = best, let foundTime = found.time, foundTime >= earliest { return found }
        // Landed earlier (or rewound to the start): read forward to the planned keyframe.
        var reads = 0
        while reads < 200_000, !shared.isCancelled, let packet = try source.readPacket() {
            reads += 1
            guard packet.streamIndex == videoIndex, let packetTime = packet.time else { continue }
            if packet.isKeyframe {
                best = packet
                if packetTime >= earliest { return packet }
            }
            if packetTime > time + .seconds(2) { break }
        }
        return best
    }

    /// Waits for every submitted frame to be decoded and encoded.
    private func settle() {
        if let session {
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        sink?.flush()
        shared.waitUntilIdle(timeout: 5)
    }

    private func save(complete: Bool) {
        guard let key, let cache, let pack = shared.snapshot(), pack.count > 0 || complete else { return }
        try? cache.store(pack, for: key, complete: complete)
    }
}

/// Receives the priming decode's frame from the VideoToolbox callback.
private final class PrimedFrame: Sendable {
    let frame = Mutex<CVReadOnlyPixelBuffer?>(nil)
}

// MARK: Software path

/// libavcodec decode of single keyframes, scaled to the thumbnail size in BGRA with a
/// `VTPixelTransferSession`. Synchronous; used on the generation thread only.
private final class SoftwareThumbnailDecoder {
    private final class Slot: Sendable {
        let frame = Mutex<DecodedFrame?>(nil)
    }

    private let decoder: SoftwareVideoDecoder
    private let slot: Slot
    private let transfer: VTPixelTransferSession
    private let width: Int
    private let height: Int

    init(parameters: CodecParameters, format: VideoFormat, width: Int, height: Int) throws {
        let slot = Slot()
        self.slot = slot
        // Two threads: one keyframe at a time gains nothing from frame threads, and this is background work.
        decoder = try SoftwareVideoDecoder(parameters: parameters, format: format, threads: 2) { event in
            if case .frame(let frame) = event { slot.frame.withLock { $0 = frame } }
        }
        var transfer: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
        guard status == noErr, let transfer else { throw MediaStatusError(status: status, operation: "VTPixelTransferSessionCreate") }
        self.transfer = transfer
        self.width = width
        self.height = height
    }

    func invalidate() {
        decoder.invalidate()
        VTPixelTransferSessionInvalidate(transfer)
    }

    /// Decodes one keyframe and returns it scaled, or nil when it did not decode.
    func decode(_ packet: Packet) -> CVReadOnlyPixelBuffer? {
        slot.frame.withLock { $0 = nil }
        guard (try? decoder.decode(packet, generation: 0, output: true)) != nil else { return nil }
        // Drain so the frame comes out without the packets that would follow it.
        decoder.drainSynchronously()
        guard let frame = slot.frame.withLock({ $0 }) else { return nil }
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &output) == kCVReturnSuccess,
              let output else { return nil }
        let status = frame.pixelBuffer.withUnsafeBuffer { source in
            VTPixelTransferSessionTransferImage(transfer, from: source, to: output)
        }
        guard status == noErr else { return nil }
        return CVReadOnlyPixelBuffer(fresh: output)
    }
}
