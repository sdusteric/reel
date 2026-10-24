import CoreMedia
import CoreVideo
import Foundation
import ReelCore
import ReelEngine
import Synchronization

/// `reelctl av-sync <file> [--json]` (design section 14): plays a sync fixture (a white frame and
/// a 1 kHz beep at every whole second) through the engine's audio and video paths with no audio
/// renderer attached, finds flash frames and beep onsets (sample-accurate, from the engine's audio
/// pts) and reports the largest |beep onset - flash pts|, over the whole file and after random
/// exact seeks. The engine runs faster than real time; timestamps do not depend on the rate.
enum AVSyncCommand {
    static let limitMilliseconds = 20.0
    /// Onsets and flashes this close after a seek target may be cut in half by the seek itself.
    static let seekGuard = MediaTime.milliseconds(60)
    static let seekWindow = MediaTime.milliseconds(2_200)

    struct Phase: Encodable {
        var pairs: Int
        var flashes: Int
        var onsets: Int
        var maxAbsMilliseconds: Double?
        var meanMilliseconds: Double?
        var differencesMilliseconds: [Double]
    }

    struct Report: Encodable {
        var file: String
        var rate: Double
        var sequential: Phase
        var seeks: Int
        var seekTargets: [Double]
        var afterSeeks: Phase
        var limitMilliseconds: Double
        var failures: [String]
        var pass: Bool
    }

    struct Event: Sendable {
        var time: MediaTime
        var generation: UInt64
    }

    /// Collects flash frames and beep onsets from the engine's observers.
    final class Collector: Sendable {
        static let flashLuma = 0.5
        static let beepLevel: Float = 0.1
        static let beepGap = MediaTime.milliseconds(300)

        let flashes = Mutex<[Event]>([])
        let onsets = Mutex<[Event]>([])
        private let lastLoud = Mutex<(generation: UInt64, time: MediaTime?)>((0, nil))

        func video(_ frame: DecodedFrame) {
            guard let time = MediaTime(frame.presentationTime), let luma = Collector.meanLuma(frame.pixelBuffer),
                  luma > Collector.flashLuma else { return }
            flashes.withLock { $0.append(Event(time: time, generation: frame.generation)) }
        }

        func audio(_ buffer: DecodedAudioBuffer, generation: UInt64) {
            let samples = buffer.interleavedSamples()
            let channels = max(buffer.channelCount, 1)
            guard samples.count >= buffer.frameCount * channels else { return }
            var found: [Event] = []
            lastLoud.withLock { state in
                if state.generation != generation { state = (generation, nil) }
                for index in 0..<buffer.frameCount where abs(samples[index * channels]) > Collector.beepLevel {
                    let time = MediaTime(value: buffer.startSample + Int64(index), timeBaseNum: 1, timeBaseDen: Int32(buffer.sampleRate))
                    if state.time.map({ time - $0 > Collector.beepGap }) ?? true {
                        found.append(Event(time: time, generation: generation))
                    }
                    state.time = time
                }
            }
            if !found.isEmpty { onsets.withLock { $0.append(contentsOf: found) } }
        }

        /// Mean of every eighth luma sample in both directions, 0 to 1.
        static func meanLuma(_ pixelBuffer: CVReadOnlyPixelBuffer) -> Double? {
            pixelBuffer.withUnsafeBuffer { buffer -> Double? in
                guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
                let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
                let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                let format = CVPixelBufferGetPixelFormatType(buffer)
                let sixteenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                var sum = 0.0
                var count = 0
                for row in Swift.stride(from: 0, to: height, by: 8) {
                    let line = base.advanced(by: row * stride)
                    for column in Swift.stride(from: 0, to: width, by: 8) {
                        if sixteenBit {
                            sum += Double(line.assumingMemoryBound(to: UInt16.self)[column] >> 6) / 1023
                        } else {
                            sum += Double(line.assumingMemoryBound(to: UInt8.self)[column]) / 255
                        }
                        count += 1
                    }
                }
                return count > 0 ? sum / Double(count) : nil
            }
        }

        func clear() {
            flashes.withLock { $0.removeAll() }
            onsets.withLock { $0.removeAll() }
        }
    }

    /// Pairs each flash with the nearest beep onset within half a second.
    static func analyze(flashes: [MediaTime], onsets: [MediaTime]) -> Phase {
        var differences: [Double] = []
        for flash in flashes {
            guard let nearest = onsets.min(by: { abs(($0 - flash).microseconds) < abs(($1 - flash).microseconds) }),
                  abs((nearest - flash).microseconds) < 500_000 else { continue }
            differences.append((nearest - flash).milliseconds)
        }
        return Phase(
            pairs: differences.count,
            flashes: flashes.count,
            onsets: onsets.count,
            maxAbsMilliseconds: differences.map(abs).max(),
            meanMilliseconds: differences.isEmpty ? nil : differences.reduce(0, +) / Double(differences.count),
            differencesMilliseconds: differences
        )
    }

    static func run(_ arguments: CommandArguments) async throws -> Int32 {
        let url = try arguments.file()
        let seeks = try arguments.int("--seeks", default: 10)
        let rate = try arguments.double("--rate", default: 8)
        var random = SplitMix64(seed: UInt64(try arguments.int("--seed", default: 11)))
        let report = try await measure(url, seeks: seeks, rate: rate, random: &random)
        if arguments.json {
            try printJSON(report)
        } else {
            func describe(_ phase: Phase) -> String {
                String(format: "%d pairs, max |beep - flash| %.2f ms, mean %.2f ms", phase.pairs, phase.maxAbsMilliseconds ?? -1, phase.meanMilliseconds ?? 0)
            }
            print("\(report.file)")
            print("sequential: \(describe(report.sequential))")
            print("after \(report.seeks) exact seeks: \(describe(report.afterSeeks))")
            for failure in report.failures { print("FAIL: \(failure)") }
            print(report.pass ? "PASS" : "FAIL")
        }
        return report.pass ? 0 : 1
    }

    static func measure(_ url: URL, seeks: Int, rate: Double, random: inout SplitMix64) async throws -> Report {
        let collector = Collector()
        let engine = PlaybackEngine(configuration: headlessConfiguration(decoder: nil))
        await engine.setFrameObserver { collector.video($0) }
        await engine.setAudioObserver { collector.audio($0, generation: $1) }
        let info = try await engine.open(url)
        let start = await engine.startTime
        let end = (info.startTime ?? .zero) + (info.duration ?? .seconds(20))
        var failures: [String] = []

        // The whole file from the first frame.
        let openGeneration = await engine.currentGeneration
        await engine.setPlaybackRate(Float(rate))
        await engine.play()
        let deadline = ContinuousClock.now + .seconds((end - start).seconds / rate + 15)
        while await engine.playbackState != .ended, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        if await engine.playbackState != .ended { failures.append("playback did not reach the end") }
        let sequential = analyze(
            flashes: collector.flashes.withLock { $0 }.filter { $0.generation == openGeneration }.map(\.time),
            onsets: collector.onsets.withLock { $0 }.filter { $0.generation == openGeneration }.map(\.time)
        )

        // Random exact seeks, each followed by about two seconds of playback.
        var targets: [MediaTime] = []
        var seekFlashes: [MediaTime] = []
        var seekOnsets: [MediaTime] = []
        let low = start + .milliseconds(500)
        let span = UInt64(max((end - .seconds(3) - low).microseconds, 1))
        for _ in 0..<seeks {
            let target = low + MediaTime(microseconds: Int64(random.next() % span))
            targets.append(target)
            collector.clear()
            guard let report = await engine.seekAndWait(.exact(target)), !report.cancelled else {
                failures.append("exact seek to \(target) did not land")
                continue
            }
            await engine.play()
            let windowEnd = target + seekWindow
            let seekDeadline = ContinuousClock.now + .seconds(seekWindow.seconds / rate + 5)
            while engine.currentTime < windowEnd, ContinuousClock.now < seekDeadline, await engine.playbackState != .ended {
                try await Task.sleep(for: .milliseconds(10))
            }
            await engine.pause()
            let generation = report.generation
            let earliest = target + seekGuard
            let latest = windowEnd - .milliseconds(200)
            seekFlashes += collector.flashes.withLock { $0 }
                .filter { $0.generation == generation && $0.time >= earliest && $0.time <= latest }.map(\.time)
            seekOnsets += collector.onsets.withLock { $0 }
                .filter { $0.generation == generation && $0.time >= earliest }.map(\.time)
        }
        await engine.close()
        let afterSeeks = analyze(flashes: seekFlashes, onsets: seekOnsets)

        let expectedPairs = Int((end - start).seconds) - 1
        if sequential.pairs < expectedPairs {
            failures.append("only \(sequential.pairs) flash and beep pairs over the file, expected at least \(expectedPairs)")
        }
        if afterSeeks.pairs < seeks {
            failures.append("only \(afterSeeks.pairs) pairs after \(seeks) seeks")
        }
        for (name, phase) in [("sequential", sequential), ("after seeks", afterSeeks)] {
            if let worst = phase.maxAbsMilliseconds, worst > limitMilliseconds {
                failures.append(String(format: "%@: max |beep - flash| %.2f ms is over %.0f ms", name, worst, limitMilliseconds))
            }
        }
        return Report(
            file: url.path(percentEncoded: false),
            rate: rate,
            sequential: sequential,
            seeks: seeks,
            seekTargets: targets.map(\.seconds),
            afterSeeks: afterSeeks,
            limitMilliseconds: limitMilliseconds,
            failures: failures,
            pass: failures.isEmpty
        )
    }
}
