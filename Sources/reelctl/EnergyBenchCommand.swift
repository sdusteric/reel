import CoreFoundation
import Foundation
import ReelCore
import ReelEngine
import Synchronization

/// `reelctl energy-bench <file> --mode play|paused|occluded [--seconds N] [--warmup N] [--no-tile-check] --json`
/// (design section 7.9). One `PlaybackEngine`, no audio renderer (the synchronizer follows the
/// host clock) and the engine's standalone display layer. It samples `proc_pid_rusage` of this
/// process and of the `VTDecoderXPCService` processes that appeared after the engine opened the
/// file, before and after a window that starts after the warm-up, and the engine's counters over
/// the same window.
enum EnergyBenchCommand {
    enum Mode: String, Encodable, CaseIterable {
        case play, paused, occluded
    }

    struct Parameters: Encodable {
        var file: String
        var mode: Mode
        var seconds: Double
        var warmup: Double
        var decoder: String
        /// The VP9 tile check of section 7.10 runs (off with `--no-tile-check`, to measure it).
        var tileCheck: Bool
    }

    /// The VP9 tile check over the window (section 7.10).
    struct TileCheckUsage: Encodable {
        var packetsChecked: Int
        var packetsDamaged: Int
        var cpuMs: Double
        /// Share of one core over the window.
        var cpuPercent: Double
    }

    struct XPCUsage: Encodable {
        var pid: Int32
        var cpuPercent: Double
        var wakeupsPerSecond: Double
        var billedEnergyNJ: UInt64
    }

    struct Report: Encodable {
        var file: String
        var mode: Mode
        var seconds: Double
        var warmup: Double
        var decoder: String?
        /// Which video sink consumed frames: the engine's standalone `AVSampleBufferDisplayLayer`.
        var sink: String
        var audioRenderer: Bool
        var cpuPercent: Double
        var wakeupsPerSecond: Double
        var billedEnergyNJ: UInt64
        var instructions: UInt64
        var usage: ProcessUsage.Delta
        /// The decoder service started for this engine; null when none was found.
        var xpc: XPCUsage?
        /// Engine counters over the window.
        var counters: EnergyCounters
        /// VP9 only: the tile check's share of the window; null for other codecs.
        var vp9TileCheck: TileCheckUsage?
        /// Video frames the display layer accepted over the window.
        var framesPresented: Int
        /// Frames a real-time playback of the window decodes (0 while paused).
        var framesExpected: Int
        /// Occluded: frames decoded from the first second of occlusion (plus `occlusionSettle`)
        /// to the end of the window.
        var framesDecodedAfterFirstSecond: Int?
        /// Occluded: milliseconds from clearing the flag to the exact frame at the clock.
        var resyncMs: Double?
        var resyncLandedPTS: Double?
        var finalState: String
    }

    static let defaultSeconds: Double = 20
    static let defaultWarmup: Double = 5
    static let xpcServiceName = "VTDecoderXPCService"
    static let occlusionSettle = 0.1

    /// Runs the bench on the main run loop: the engine needs the main actor for its display layer,
    /// and `main.swift` calls commands synchronously.
    static func run(_ arguments: CommandArguments) throws -> Int32 {
        let parameters = try parse(arguments)
        let url = try arguments.file()
        let decoder = try arguments.decoder()
        let outcome = Mutex<Result<Report, any Error>?>(nil)
        Task.detached {
            let result: Result<Report, any Error>
            do {
                result = .success(try await bench(url: url, parameters: parameters, decoder: decoder))
            } catch {
                result = .failure(error)
            }
            outcome.withLock { $0 = result }
            DispatchQueue.main.async { CFRunLoopStop(CFRunLoopGetMain()) }
        }
        while outcome.withLock({ $0 == nil }) {
            CFRunLoopRun()
        }
        let report = try outcome.withLock { $0! }.get()
        if arguments.json {
            try printJSON(report)
        } else {
            print(String(
                format: "%@ %@: cpu %.2f%%, %.1f wakeups/s, %d frames decoded, %d packets, %d time events",
                report.mode.rawValue, url.lastPathComponent, report.cpuPercent, report.wakeupsPerSecond,
                report.counters.framesDecoded, report.counters.packetsRead, report.counters.timeEvents
            ))
        }
        return 0
    }

    private final class FrameCounter: Sendable {
        let presented = Atomic<Int>(0)
    }

    static func bench(url: URL, parameters: Parameters, decoder: VideoDecoderKind?) async throws -> Report {
        let existing = ProcessUsage.pids(named: xpcServiceName)
        var configuration = headlessConfiguration(decoder: decoder)
        configuration.checksVP9Tiles = parameters.tileCheck
        let engine = PlaybackEngine(configuration: configuration)
        let counter = FrameCounter()
        await engine.setFrameObserver { _ in counter.presented.add(1, ordering: .relaxed) }
        // The bench has no pointer: paused thumbnails follow the policy's idle branch.
        await engine.setPointerRecent(false)
        let info = try await engine.open(url)
        let videoDecoder = await engine.videoDecoderKind
        let started = ProcessUsage.pids(named: xpcServiceName).subtracting(existing)
        switch parameters.mode {
        case .play, .occluded:
            await engine.play()
        case .paused:
            // Play briefly, as a person does before pausing, so the pause follows real playback.
            await engine.play()
            try await Task.sleep(for: .seconds(1))
            await engine.pause()
        }
        try await Task.sleep(for: .seconds(parameters.warmup))

        let xpcStart = started.compactMap { ProcessUsage.sample($0) }
        let countersStart = await engine.energyCounters()
        let tileStart = engine.vp9TileCheckTotals
        let presentedStart = counter.presented.load(ordering: .relaxed)
        guard let selfStart = ProcessUsage.sample() else { throw UsageError("proc_pid_rusage failed for this process") }

        var afterFirstSecond: EnergyCounters?
        if parameters.mode == .occluded {
            await engine.setOccluded(true)
            // The engine stops feeding the decoder at 1 s; frames VideoToolbox already holds come
            // out within a few milliseconds, so the count starts after a short settle.
            let first = min(EnergyPolicy.occlusionDelay + occlusionSettle, parameters.seconds)
            try await Task.sleep(for: .seconds(first))
            afterFirstSecond = await engine.energyCounters()
            try await Task.sleep(for: .seconds(parameters.seconds - first))
        } else {
            try await Task.sleep(for: .seconds(parameters.seconds))
        }

        guard let selfEnd = ProcessUsage.sample() else { throw UsageError("proc_pid_rusage failed for this process") }
        let countersEnd = await engine.energyCounters()
        let tileEnd = engine.vp9TileCheckTotals
        let presentedEnd = counter.presented.load(ordering: .relaxed)
        let xpcEnd = xpcStart.compactMap { start in ProcessUsage.sample(start.pid).map { (start, $0) } }

        var resync: SeekReport?
        if parameters.mode == .occluded {
            resync = await engine.setOccludedAndWait(false)
        }
        let finalState = await engine.playbackState
        await engine.close()

        let usage = selfEnd.since(selfStart)
        let tileCheck = tileEnd.map { end -> TileCheckUsage in
            let start = tileStart ?? (0, 0, 0)
            let cpuMs = end.cpuMilliseconds - start.cpuMilliseconds
            return TileCheckUsage(
                packetsChecked: end.checked - start.checked,
                packetsDamaged: end.damaged - start.damaged,
                cpuMs: cpuMs,
                cpuPercent: cpuMs / (parameters.seconds * 1_000) * 100
            )
        }
        let window = countersEnd - countersStart
        // The busiest new decoder service is the one this engine uses.
        let xpc = xpcEnd.map { start, end -> XPCUsage in
            let delta = end.since(start)
            return XPCUsage(pid: end.pid, cpuPercent: delta.cpuPercent, wakeupsPerSecond: delta.wakeupsPerSecond, billedEnergyNJ: delta.billedEnergyNJ)
        }.max { $0.cpuPercent < $1.cpuPercent }
        let fps = info.videoStream?.video?.frameRate.flatMap { $0.isValid ? Double($0.num) / Double($0.den) : nil } ?? 0
        let expected: Int
        switch parameters.mode {
        case .play: expected = Int((fps * parameters.seconds).rounded())
        case .paused, .occluded: expected = 0
        }
        return Report(
            file: parameters.file,
            mode: parameters.mode,
            seconds: parameters.seconds,
            warmup: parameters.warmup,
            decoder: videoDecoder?.rawValue,
            sink: "displayLayer",
            audioRenderer: false,
            cpuPercent: usage.cpuPercent,
            wakeupsPerSecond: usage.wakeupsPerSecond,
            billedEnergyNJ: usage.billedEnergyNJ,
            instructions: usage.instructions,
            usage: usage,
            xpc: xpc,
            counters: window,
            vp9TileCheck: tileCheck,
            framesPresented: presentedEnd - presentedStart,
            framesExpected: expected,
            framesDecodedAfterFirstSecond: afterFirstSecond.map { countersEnd.framesDecoded - $0.framesDecoded },
            resyncMs: resync?.targetMilliseconds,
            resyncLandedPTS: resync?.landedPTS?.seconds,
            finalState: finalState.rawValue
        )
    }

    static func parse(_ arguments: CommandArguments) throws -> Parameters {
        let url = try arguments.file()
        guard let text = arguments.options["--mode"] else { throw UsageError("energy-bench needs --mode play|paused|occluded") }
        guard let mode = Mode(rawValue: text.lowercased()) else {
            throw UsageError("unknown mode \(text); use play, paused or occluded")
        }
        let warmup: Double
        if let value = arguments.options["--warmup"] {
            guard let parsed = Double(value), parsed.isFinite, parsed >= 0 else { throw UsageError("--warmup must be 0 or more") }
            warmup = parsed
        } else {
            warmup = defaultWarmup
        }
        return Parameters(
            file: url.path(percentEncoded: false),
            mode: mode,
            seconds: try arguments.double("--seconds", default: defaultSeconds),
            warmup: warmup,
            decoder: try arguments.decoder()?.rawValue ?? "auto",
            tileCheck: !arguments.flags.contains("--no-tile-check")
        )
    }
}
