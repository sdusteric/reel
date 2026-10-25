import CReelDeps
import Darwin
import Foundation
import ReelCore
import ReelEngine
import Synchronization

/// `reelctl soak <file|dir> [--seed S] [--ops N] [--seconds N] [--asan-expected] --json`, or
/// `soak --list <file>...` (or `--list <paths.txt>`), and the internal `soak-one <file>` that runs
/// one file in a child process (design section 7.10, D64).
///
/// The parent runs every file in its own `reelctl soak-one` child, tracked by PID: a crash is a
/// signal exit in the report instead of the end of the run, and a child still running after 30 s
/// gets SIGTERM, then SIGKILL. The child opens the file, plays it at rate 4 on the host clock with
/// no audio renderer, runs N seeded operations, closes it and prints one JSON report.
enum SoakCommand {
    struct Parameters: Encodable {
        var files: [String]
        var seed: Int
        var ops: Int
        var seconds: Double
        var asanExpected: Bool
        var jobs: Int
    }

    static let defaultOps = 30
    static let defaultSeconds: Double = 3
    /// Children at a time (`--jobs`).
    static let defaultJobs = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    /// Files a soak run skips in a directory: the manifest, logs and hidden partial files.
    static let skippedExtensions: Set<String> = ["json", "log", "txt"]
    /// A child still running after this long is a hang (SIGTERM, then SIGKILL 2 s later).
    static let childTimeout: Duration = .seconds(30)
    /// The criteria (section 16, M3 acceptance 5).
    static let operationLimitMilliseconds: Double = 5_000
    static let leakAllowance = 2
    static let dataEndTolerance = 1.0

    // MARK: Parent

    static func run(_ arguments: CommandArguments) throws -> Int32 {
        let files = try inputFiles(arguments)
        let parameters = try parameters(arguments, files: files)
        guard let executable = Bundle.main.executableURL else { throw UsageError("cannot find the reelctl executable") }
        let manifests = ManifestCache()
        let scratch = FileManager.default.temporaryDirectory.appending(path: "reel-soak-\(getpid())-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Children run a few at a time: most of a child's wall time is spent waiting for idle
        // worker threads to retire before its leak count, which overlaps well.
        let jobs = parameters.jobs
        let children = Mutex<[Int: ChildRun]>([:])
        let slots = DispatchSemaphore(value: jobs)
        let group = DispatchGroup()
        for (position, file) in files.enumerated() {
            slots.wait()
            group.enter()
            let seed = parameters.seed &+ position
            DispatchQueue.global(qos: .userInitiated).async {
                let child = runChild(executable: executable, file: file, parameters: parameters, seed: seed, scratch: scratch, index: position)
                children.withLock { $0[position] = child }
                slots.signal()
                group.leave()
            }
        }
        group.wait()
        var results: [FileResult] = []
        for (position, file) in files.enumerated() {
            guard let child = children.withLock({ $0[position] }) else { continue }
            var result = FileResult(file: file.path(percentEncoded: false), child: child)
            result.evaluate(expectation: manifests.expectation(for: file))
            if !arguments.json {
                let status = result.problems.isEmpty ? "ok" : result.problems.joined(separator: "; ")
                print("\(file.lastPathComponent): \(result.outcome) \(status)")
            }
            results.append(result)
        }
        let report = SoakReport(parameters: parameters, files: results, totals: Totals(results))
        if arguments.json {
            try printJSON(report)
        } else {
            let totals = report.totals
            print("files \(totals.files), crashes \(totals.crashes), hangs \(totals.hangs), leaks \(totals.leaks), mismatches \(totals.mismatches), dataEnd misses \(totals.dataEndMisses), damage misses \(totals.damageMisses)")
        }
        let totals = report.totals
        return totals.crashes + totals.hangs + totals.leaks + totals.mismatches + totals.dataEndMisses + totals.damageMisses == 0 ? 0 : 1
    }

    /// Runs `soak-one` for `file` and collects its report, exit status and signal. The child's
    /// standard error goes to a file; it is copied to ours when the child crashed or a sanitizer
    /// reported something, so nothing it found is hidden.
    static func runChild(executable: URL, file: URL, parameters: Parameters, seed: Int, scratch: URL, index: Int) -> ChildRun {
        let stdoutURL = scratch.appending(path: "\(index).out.json")
        let stderrURL = scratch.appending(path: "\(index).err.log")
        FileManager.default.createFile(atPath: stdoutURL.path(percentEncoded: false), contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path(percentEncoded: false), contents: nil)
        var run = ChildRun()
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "soak-one", file.path(percentEncoded: false), "--json",
            "--seed", String(seed), "--ops", String(parameters.ops), "--seconds", String(parameters.seconds),
        ]
        var environment = ProcessInfo.processInfo.environment
        // Silent and headless whatever the caller's environment says (CLAUDE.md safety rules).
        environment.removeValue(forKey: "REEL_ALLOW_AUDIO")
        environment["REEL_NO_UPDATES"] = "1"
        environment["REEL_NO_THUMBNAILS"] = "1"
        process.environment = environment
        guard let output = try? FileHandle(forWritingTo: stdoutURL), let errors = try? FileHandle(forWritingTo: stderrURL) else {
            run.launchError = "cannot create the child's output files"
            return run
        }
        defer {
            try? output.close()
            try? errors.close()
        }
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let started = ContinuousClock.now
        do {
            try process.run()
        } catch {
            run.launchError = "\(error)"
            return run
        }
        let pid = process.processIdentifier
        run.pid = pid
        let deadline = started + childTimeout
        while process.isRunning, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            run.killed = true
            kill(pid, SIGTERM)
            let grace = ContinuousClock.now + .seconds(2)
            while process.isRunning, ContinuousClock.now < grace {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning { kill(pid, SIGKILL) }
        }
        process.waitUntilExit()
        run.wallMs = (ContinuousClock.now - started).milliseconds
        switch process.terminationReason {
        case .exit:
            run.exitStatus = process.terminationStatus
        case .uncaughtSignal:
            run.signal = process.terminationStatus
        @unknown default:
            run.exitStatus = process.terminationStatus
        }
        if let data = try? Data(contentsOf: stdoutURL), !data.isEmpty {
            run.report = try? JSONDecoder().decode(OneReport.self, from: data)
            if run.report == nil { run.launchError = "unreadable report: \(String(decoding: data.prefix(200), as: UTF8.self))" }
        }
        let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        run.sanitizerReport = stderrText.contains("AddressSanitizer") || stderrText.contains("runtime error:")
        if run.signal != nil || run.sanitizerReport || run.killed {
            let tail = stderrText.split(separator: "\n", omittingEmptySubsequences: false).suffix(200).joined(separator: "\n")
            FileHandle.standardError.write(Data("== soak-one \(file.lastPathComponent) (pid \(pid)) standard error:\n\(tail)\n".utf8))
        }
        return run
    }

    struct ChildRun: Codable {
        var pid: Int32?
        var exitStatus: Int32?
        var signal: Int32?
        var killed = false
        var wallMs: Double = 0
        var launchError: String?
        var sanitizerReport = false
        var report: OneReport?
    }

    /// The parent's view of one file.
    struct FileResult: Encodable {
        var file: String
        var outcome: String
        var exitStatus: Int32?
        var signal: Int32?
        var crashed: Bool
        var hung: Bool
        var leaked: Bool
        /// The outcome differs from the manifest's `expected`.
        var mismatch: Bool
        /// A truncated file's `dataEnd` is missing or more than 1 s off the manifest's.
        var dataEndMiss = false
        var dataEndChecked = false
        /// A zero-filled middle or 4 KB overwrite at 50% stopped short or counted no damage.
        var damageMiss = false
        var expected: String?
        var expectedDataEnd: Double?
        var problems: [String] = []
        var wallMs: Double
        var report: OneReport?
        var launchError: String?

        private enum CodingKeys: String, CodingKey {
            case file, outcome, exitStatus, signal, crashed, hung, leaked, mismatch, dataEndMiss, damageMiss
            case expected, expectedDataEnd, problems, wallMs, launchError
        }

        /// The child's report fields at the top level, with the parent's added (`exitStatus`,
        /// `signal`, the verdicts and the manifest expectation).
        func encode(to encoder: any Encoder) throws {
            try report?.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(file, forKey: .file)
            try container.encode(outcome, forKey: .outcome)
            try container.encode(exitStatus, forKey: .exitStatus)
            try container.encode(signal, forKey: .signal)
            try container.encode(crashed, forKey: .crashed)
            try container.encode(hung, forKey: .hung)
            try container.encode(leaked, forKey: .leaked)
            try container.encode(mismatch, forKey: .mismatch)
            try container.encode(dataEndMiss, forKey: .dataEndMiss)
            try container.encode(damageMiss, forKey: .damageMiss)
            try container.encode(expected, forKey: .expected)
            try container.encode(expectedDataEnd, forKey: .expectedDataEnd)
            try container.encode(problems, forKey: .problems)
            try container.encode(wallMs, forKey: .wallMs)
            try container.encodeIfPresent(launchError, forKey: .launchError)
        }

        init(file: String, child: ChildRun) {
            self.file = file
            exitStatus = child.exitStatus
            signal = child.signal
            report = child.report
            wallMs = child.wallMs
            launchError = child.launchError
            outcome = child.report?.outcome ?? (child.signal != nil ? "crashed" : child.killed ? "hung" : "noReport")
            crashed = child.signal != nil && !child.killed
            hung = child.killed || (child.report?.longestOperationMs ?? 0) > SoakCommand.operationLimitMilliseconds
            leaked = child.report.map { report in
                report.fdsAfter > report.fdsBefore + SoakCommand.leakAllowance
                    || report.threadsAfter > report.threadsBefore + SoakCommand.leakAllowance
            } ?? false
            mismatch = false
            if crashed { problems.append("crashed with signal \(child.signal ?? 0)") }
            if child.killed { problems.append("killed after \(SoakCommand.childTimeout)") }
            if child.sanitizerReport { problems.append("sanitizer report on standard error") }
            if let report = child.report {
                if report.longestOperationMs > SoakCommand.operationLimitMilliseconds {
                    problems.append("\(report.longestOperation ?? "an operation") took \(Int(report.longestOperationMs)) ms")
                }
                if leaked {
                    problems.append("fds \(report.fdsBefore) to \(report.fdsAfter), threads \(report.threadsBefore) to \(report.threadsAfter)")
                }
                if let problem = report.problem, problem.title.isEmpty || problem.explanation.isEmpty {
                    problems.append("problem \(problem.kind) has no copy")
                }
            } else if !crashed, !child.killed {
                problems.append(child.launchError ?? "no report (exit \(child.exitStatus ?? -1))")
            }
        }

        /// Compares the outcome with the manifest (corpus/manifest.json) or the built-in odd/ list.
        mutating func evaluate(expectation: Expectation?) {
            guard let expectation else { return }
            expected = expectation.outcome
            expectedDataEnd = expectation.dataEnd
            guard let report else {
                mismatch = true
                return
            }
            var reasons: [String] = []
            defer {
                mismatch = !reasons.isEmpty
                problems.append(contentsOf: reasons)
            }
            switch expectation.outcome {
            case "played":
                if report.outcome != "played" { reasons.append("expected played, got \(report.outcome)") }
            case "classified":
                if report.outcome == "played" { reasons.append("expected a classified problem, got played") }
            case "any":
                break
            default:
                if report.outcome != expectation.outcome { reasons.append("expected \(expectation.outcome), got \(report.outcome)") }
            }
            guard report.outcome == "played" else { return }
            // The data end and the damage checks are counted on their own (section 16, M3 5).
            if let expectedEnd = expectation.dataEnd {
                if let dataEnd = report.dataEnd, abs(dataEnd - expectedEnd) <= SoakCommand.dataEndTolerance {
                    dataEndChecked = true
                } else {
                    dataEndMiss = true
                    problems.append("dataEnd \(report.dataEnd.map { "\($0) s" } ?? "missing"), expected \(expectedEnd) s")
                }
            }
            if expectation.checksDamage {
                let end = report.dataEnd ?? report.durationSeconds ?? 0
                if !report.ended, report.reachedSeconds + SoakCommand.dataEndTolerance < end {
                    damageMiss = true
                    problems.append("playback stopped at \(report.reachedSeconds) s of \(end) s")
                }
                if expectation.damagesVideo, report.damagedFrames == 0 {
                    damageMiss = true
                    problems.append("no damaged frames counted")
                }
            }
        }
    }

    struct Totals: Encodable {
        var files: Int
        var crashes: Int
        var hangs: Int
        var leaks: Int
        var mismatches: Int
        var dataEndMisses: Int
        var dataEndChecks: Int
        var damageMisses: Int
        var played: Int
        var classified: Int
        var damagedFrames: Int
        var longestOperationMs: Double

        init(_ results: [FileResult]) {
            files = results.count
            crashes = results.count(where: \.crashed)
            hangs = results.count(where: \.hung)
            leaks = results.count(where: \.leaked)
            mismatches = results.count(where: \.mismatch)
            dataEndMisses = results.count(where: \.dataEndMiss)
            dataEndChecks = results.count(where: \.dataEndChecked)
            damageMisses = results.count(where: \.damageMiss)
            played = results.count { $0.outcome == "played" }
            classified = results.count { $0.report?.problem != nil }
            damagedFrames = results.reduce(0) { $0 + ($1.report?.damagedFrames ?? 0) }
            longestOperationMs = results.compactMap { $0.report?.longestOperationMs }.max() ?? 0
        }
    }

    struct SoakReport: Encodable {
        var parameters: Parameters
        var files: [FileResult]
        var totals: Totals
    }

    // MARK: Expectations

    struct Expectation {
        /// "played", "classified", "any" or a `MediaProblem` kind.
        var outcome: String
        var dataEnd: Double?
        /// A zero-filled middle or a 4 KB overwrite at 50%: playback must get past it.
        var checksDamage = false
        var damagesVideo = false
    }

    /// corpus/manifest.json entries by file, and the odd/ files' expected outcomes.
    final class ManifestCache {
        private struct Manifest: Decodable {
            struct Damage: Decodable {
                var video: Bool
            }

            struct Entry: Decodable {
                var file: String
                var mutation: String
                var expected: String
                var dataEnd: Double?
                var damage: Damage?
            }

            var files: [Entry]
        }

        private var loaded: [String: [String: Manifest.Entry]?] = [:]

        func expectation(for file: URL) -> Expectation? {
            let directory = file.deletingLastPathComponent()
            if directory.lastPathComponent == "odd" { return SoakCommand.oddExpectation(file.lastPathComponent) }
            let key = directory.path(percentEncoded: false)
            if loaded[key] == nil {
                let url = directory.appending(path: "manifest.json")
                let manifest = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
                loaded[key] = manifest.map { Dictionary($0.files.map { ($0.file, $0) }, uniquingKeysWith: { first, _ in first }) }
            }
            guard let entries = loaded[key] ?? nil, let entry = entries[file.lastPathComponent] else { return nil }
            let damage = entry.mutation == "zeromid" || entry.mutation == "overwrite50"
            return Expectation(
                outcome: entry.expected,
                dataEnd: entry.dataEnd,
                checksDamage: damage,
                damagesVideo: damage && entry.damage?.video == true
            )
        }
    }

    /// odd/ has no manifest: three files are not media, ProRes is not decodable, the rest play.
    static func oddExpectation(_ name: String) -> Expectation {
        switch name {
        case "zero.mkv", "text.mp4", "random.mkv": Expectation(outcome: "notMedia")
        case "prores.mov": Expectation(outcome: "unsupportedCodec")
        default: Expectation(outcome: "played")
        }
    }

    // MARK: Input

    static func parameters(_ arguments: CommandArguments, files: [URL]) throws -> Parameters {
        Parameters(
            files: files.map { $0.path(percentEncoded: false) },
            seed: try arguments.int("--seed", default: 1),
            ops: try arguments.int("--ops", default: defaultOps),
            seconds: try arguments.double("--seconds", default: defaultSeconds),
            asanExpected: arguments.flags.contains("--asan-expected"),
            jobs: try jobs(arguments)
        )
    }

    /// `--jobs N` or `--jobs=N`, at most 16.
    static func jobs(_ arguments: CommandArguments) throws -> Int {
        let text: String
        if let option = arguments.options["--jobs"] {
            text = option
        } else if let flag = arguments.flags.first(where: { $0.hasPrefix("--jobs=") }) {
            text = String(flag.dropFirst("--jobs=".count))
        } else {
            return defaultJobs
        }
        guard let value = Int(text), value > 0 else { throw UsageError("--jobs needs a positive N") }
        return min(value, 16)
    }

    /// The positional files with `--list` (or the paths listed one per line in a single `.txt`
    /// or `.list` file), else every regular, non-hidden file under the one positional file or
    /// directory, sorted by path.
    static func inputFiles(_ arguments: CommandArguments) throws -> [URL] {
        let manager = FileManager.default
        if arguments.flags.contains("--list") {
            guard !arguments.positional.isEmpty else { throw UsageError("--list needs at least one file") }
            var paths = arguments.positional
            if paths.count == 1, let only = paths.first, ["txt", "list"].contains(URL(filePath: only).pathExtension.lowercased()) {
                let text = try String(contentsOf: URL(filePath: only), encoding: .utf8)
                paths = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            return try paths.map { path in
                let url = URL(filePath: path).standardizedFileURL
                guard manager.fileExists(atPath: url.path(percentEncoded: false)) else { throw UsageError("no such file: \(path)") }
                return url
            }
        }
        guard arguments.positional.count == 1, let path = arguments.positional.first else {
            throw UsageError("soak takes one <file|dir>, or --list <file>...")
        }
        let root = URL(filePath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory) else {
            throw UsageError("no such file: \(path)")
        }
        guard isDirectory.boolValue else { return [root] }
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  !skippedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            files.append(url.standardizedFileURL)
        }
        return files.sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }

    // MARK: Child

    /// What `soak-one` prints.
    struct OneReport: Codable {
        struct Problem: Codable {
            var kind: String
            var title: String
            var explanation: String
            var detail: String?
        }

        var file: String
        /// "played", or the `MediaProblem` kind of a file that did not open.
        var outcome: String
        var problem: Problem?
        var openMs: Double?
        var durationSeconds: Double?
        /// How far playback got (the end position when it ended).
        var reachedSeconds: Double
        var ended: Bool
        var operations: Int
        var operationCounts: [String: Int]
        var longestOperationMs: Double
        var longestOperation: String?
        var unsettledSeeks: Int
        var damagedFrames: Int
        var damagedVideoFrames: Int
        var damagedAudioPackets: Int
        var damagedEvents: Int
        var dataEnd: Double?
        var volumeGone: Bool
        var peakRSSBytes: Int
        var fdsBefore: Int
        var fdsAfter: Int
        var threadsBefore: Int
        var threadsAfter: Int
        /// Thread names after close, when there were more than the allowance.
        var threadNamesAfter: [String]?
        var decoder: String?
    }

    /// Runs on the main run loop, like `energy-bench`: the engine needs the main actor for its
    /// display layer, and `main.swift` calls commands synchronously.
    static func runOne(_ arguments: CommandArguments) throws -> Int32 {
        let file = try arguments.file()
        let seed = try arguments.int("--seed", default: 1)
        let ops = try arguments.int("--ops", default: defaultOps)
        let seconds = try arguments.double("--seconds", default: defaultSeconds)
        // Damaged files make FFmpeg log on every packet; the report carries what matters.
        av_log_set_level(AV_LOG_FATAL)
        let outcome = Mutex<OneReport?>(nil)
        Task.detached {
            let runner = SoakRunner(file: file, seed: UInt64(seed), operations: ops, playSeconds: seconds)
            let report = await runner.run()
            outcome.withLock { $0 = report }
            DispatchQueue.main.async { CFRunLoopStop(CFRunLoopGetMain()) }
        }
        var report: OneReport?
        while report == nil {
            CFRunLoopRun()
            report = outcome.withLock { $0 }
        }
        guard let report else { return 1 }
        if arguments.json {
            try printJSON(report)
        } else {
            print("\(file.lastPathComponent): \(report.outcome), \(report.operations) operations, longest \(Int(report.longestOperationMs)) ms")
        }
        return 0
    }
}

/// One file's soak in this process (section 7.10).
final class SoakRunner {
    let file: URL
    let operations: Int
    let playSeconds: Double
    private var random: SplitMix64
    private var counts: [String: Int] = [:]
    private var longest: (name: String, ms: Double)?
    private var unsettled = 0
    private var reached = MediaTime.zero
    private let events = SoakEvents()

    init(file: URL, seed: UInt64, operations: Int, playSeconds: Double) {
        self.file = file
        self.operations = operations
        self.playSeconds = playSeconds
        random = SplitMix64(seed: seed)
    }

    static func makeEngine() -> PlaybackEngine {
        // Headless: no audio renderer (none unless REEL_ALLOW_AUDIO=1, which the parent removes).
        PlaybackEngine(configuration: headlessConfiguration(decoder: nil))
    }

    func run() async -> SoakCommand.OneReport {
        // Warm-up: process-wide set-up (VideoToolbox's connection, Core Media's shared queues and
        // converters, font caches) is not a leak, so the baseline is taken after the same file
        // was opened, played, seeked and closed once. A leak per open still shows: the run
        // closes and reopens the file several times.
        let warmup = SoakRunner.makeEngine()
        if let info = try? await warmup.open(file) {
            await warmup.setRate(4)
            await warmup.play()
            try? await Task.sleep(for: .milliseconds(250))
            let middle = (info.startTime ?? .zero) + MediaTime(seconds: (info.duration?.seconds ?? 0) / 2)
            _ = await warmup.seekAndWait(.exact(middle), timeout: .seconds(10))
        }
        await warmup.close()
        let fdsBefore = ProcessCounts.openFileDescriptors()
        let threadsBefore = ProcessCounts.threads()

        var engine = SoakRunner.makeEngine()
        var listener = events.listen(to: engine)
        let opened = monotonicMilliseconds()
        var info: MediaInfo?
        var problem: SoakCommand.OneReport.Problem?
        do {
            info = try await engine.open(file)
        } catch {
            problem = await describe(error, events: events)
        }
        let openMs = monotonicMilliseconds() - opened
        var decoder: String?
        var dataEnd: MediaTime?
        var ended = false
        var damaged = (total: 0, video: 0, audio: 0)
        if let info {
            decoder = (await engine.videoDecoderKind)?.rawValue
            ended = await play(engine)
            await runOperations(&engine, listener: &listener, info: info)
            dataEnd = await engine.dataEnd
            damaged = (engine.damagedFrames, engine.damagedVideoFrames, engine.damagedAudioPackets)
            // Damage counted by engines closed during the run (reopen operations).
            damaged.total += events.closedDamage.total
            damaged.video += events.closedDamage.video
            damaged.audio += events.closedDamage.audio
        }
        await engine.close()
        await listener.value
        let after = await ProcessCounts.settle(fds: fdsBefore, threads: threadsBefore)
        let duration = info?.duration.map { (info?.startTime ?? .zero) + $0 }
        let snapshot = events.snapshot()
        return SoakCommand.OneReport(
            file: file.path(percentEncoded: false),
            outcome: problem?.kind ?? "played",
            problem: problem,
            openMs: openMs,
            durationSeconds: duration?.seconds,
            reachedSeconds: min(max(reached, snapshot.endedAt ?? .zero), duration ?? .seconds(Double(Int32.max))).seconds,
            ended: ended || snapshot.endedAt != nil,
            operations: counts.values.reduce(0, +),
            operationCounts: counts,
            longestOperationMs: longest?.ms ?? 0,
            longestOperation: longest?.name,
            unsettledSeeks: unsettled,
            damagedFrames: damaged.total,
            damagedVideoFrames: damaged.video,
            damagedAudioPackets: damaged.audio,
            damagedEvents: snapshot.damagedEvents,
            dataEnd: (dataEnd ?? snapshot.dataEnd)?.seconds,
            volumeGone: snapshot.volumeGone,
            peakRSSBytes: ProcessCounts.peakResidentBytes(),
            fdsBefore: fdsBefore,
            fdsAfter: after.fds,
            threadsBefore: threadsBefore,
            threadsAfter: after.threads,
            threadNamesAfter: after.threads > threadsBefore + SoakCommand.leakAllowance ? ProcessCounts.threadNames() : nil,
            decoder: decoder
        )
    }

    private func describe(_ error: any Error, events: SoakEvents) async -> SoakCommand.OneReport.Problem {
        let engineError = (error as? EngineError) ?? .openFailed("\(error)")
        // The engine's own classification arrives as `.problem` just before `.failed`.
        let reported = await events.waitForProblem()
        let problem = reported ?? MediaProblem.classify(from: engineError, path: file.path(percentEncoded: false), mountedVolumes: MountedVolumes.names())
        return SoakCommand.OneReport.Problem(
            kind: problem.kind,
            title: problem.title,
            explanation: problem.explanation,
            detail: engineError.errorDescription
        )
    }

    /// Plays at rate 4 on the host clock until the end or `playSeconds` of wall time. Returns
    /// whether it ended.
    private func play(_ engine: PlaybackEngine) async -> Bool {
        await engine.setRate(4)
        await engine.play()
        let deadline = ContinuousClock.now + .seconds(playSeconds)
        while ContinuousClock.now < deadline {
            reached = max(reached, engine.currentTime)
            if await engine.playbackState == .ended { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        reached = max(reached, engine.currentTime)
        return false
    }

    enum Operation: String, CaseIterable {
        case scrub, exactSeek, seekBeforeStart, seekPastEnd, frameStepForward, frameStepBack
        case audioTrack, subtitleTrack, speed, subtitleToggle, playPause, reopen
    }

    private func runOperations(_ engine: inout PlaybackEngine, listener: inout Task<Void, Never>, info: MediaInfo) async {
        let start = info.startTime ?? .zero
        let duration = info.duration ?? .seconds(2)
        var subtitlesVisible = true
        for _ in 0..<operations {
            let operation = Operation.allCases[Int(random.next() % UInt64(Operation.allCases.count))]
            let fraction = Double(random.next() % 10_000) / 10_000
            let target = start + MediaTime(seconds: duration.seconds * fraction)
            let began = monotonicMilliseconds()
            switch operation {
            case .scrub:
                _ = await engine.seekAndWait(.scrub(target), timeout: .seconds(10))
            case .exactSeek:
                await exact(engine, target)
            case .seekBeforeStart:
                await exact(engine, start - .seconds(5))
            case .seekPastEnd:
                await exact(engine, start + duration + .seconds(5))
            case .frameStepForward, .frameStepBack:
                await engine.pause()
                let step = info.videoStream?.video?.frameDuration ?? .microseconds(33_333)
                let now = engine.currentTime
                await exact(engine, operation == .frameStepForward ? now + step : now - step)
            case .audioTrack:
                let tracks = (await engine.trackState)?.audio.compactMap(\.streamIndex) ?? []
                if !tracks.isEmpty { await engine.selectAudioTrack(tracks[Int(random.next() % UInt64(tracks.count))]) }
            case .subtitleTrack:
                let subtitles = (await engine.trackState)?.subtitles ?? []
                let choice = Int(random.next() % UInt64(subtitles.count + 1))
                await engine.selectSubtitle(choice == subtitles.count ? .off : SubtitleSelection(subtitles[choice].id))
            case .speed:
                await engine.setRate(0.5 + 3.5 * Double(random.next() % 1_000) / 1_000)
            case .subtitleToggle:
                subtitlesVisible.toggle()
                await engine.setSubtitlesVisible(subtitlesVisible)
            case .playPause:
                if await engine.playbackState == .playing {
                    await engine.pause()
                } else {
                    await engine.play()
                }
            case .reopen:
                events.addClosedDamage(engine)
                await engine.close()
                await listener.value
                engine = SoakRunner.makeEngine()
                listener = events.listen(to: engine)
                _ = try? await engine.open(file)
                await engine.setRate(4)
                await engine.play()
            }
            let elapsed = monotonicMilliseconds() - began
            counts[operation.rawValue, default: 0] += 1
            if elapsed > (longest?.ms ?? -1) { longest = (operation.rawValue, elapsed) }
            if await engine.playbackState == .playing {
                // A little playback between operations, so decode runs after every kind of jump.
                try? await Task.sleep(for: .milliseconds(30))
            }
            reached = max(reached, engine.currentTime)
        }
    }

    private func exact(_ engine: PlaybackEngine, _ target: MediaTime) async {
        if await engine.seekAndWait(.exact(target), timeout: .seconds(10)) == nil { unsettled += 1 }
    }

    private func monotonicMilliseconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }
}

/// The events the soak cares about, from every engine it creates.
final class SoakEvents: Sendable {
    struct Snapshot: Sendable {
        var problem: MediaProblem?
        var dataEnd: MediaTime?
        var endedAt: MediaTime?
        var damagedEvents = 0
        var volumeGone = false
        var failed = false
    }

    private let state = Mutex(Snapshot())
    private let closed = Mutex((total: 0, video: 0, audio: 0))

    func listen(to engine: PlaybackEngine) -> Task<Void, Never> {
        Task { [self] in
            for await event in engine.events {
                self.state.withLock { snapshot in
                    switch event {
                    case .problem(let problem):
                        snapshot.problem = problem
                        if case .volumeGone = problem { snapshot.volumeGone = true }
                    case .failed:
                        snapshot.failed = true
                    case .dataEnd(let time):
                        snapshot.dataEnd = time
                    case .damaged:
                        snapshot.damagedEvents += 1
                    case .ended:
                        snapshot.endedAt = max(snapshot.endedAt ?? engine.currentTime, engine.currentTime)
                    default:
                        break
                    }
                }
            }
        }
    }

    func snapshot() -> Snapshot { state.withLock { $0 } }

    var closedDamage: (total: Int, video: Int, audio: Int) { closed.withLock { $0 } }

    func addClosedDamage(_ engine: PlaybackEngine) {
        closed.withLock { counts in
            counts.total += engine.damagedFrames
            counts.video += engine.damagedVideoFrames
            counts.audio += engine.damagedAudioPackets
        }
    }

    /// The `.problem` of a failed open; the engine sends it before `.failed`, which the
    /// listener sees shortly after `open` throws.
    func waitForProblem() async -> MediaProblem? {
        for _ in 0..<100 {
            let snapshot = snapshot()
            if snapshot.problem != nil || snapshot.failed { return snapshot.problem }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return snapshot().problem
    }
}

/// Process counters for the leak check (section 7.10).
enum ProcessCounts {
    static func openFileDescriptors() -> Int {
        let pid = getpid()
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return 0 }
        let capacity = Int(size) / MemoryLayout<proc_fdinfo>.stride + 16
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let filled = buffer.withUnsafeMutableBytes { bytes in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, bytes.baseAddress, Int32(bytes.count))
        }
        return filled > 0 ? Int(filled) / MemoryLayout<proc_fdinfo>.stride : 0
    }

    static func threads() -> Int {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let filled = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size)
        return filled == size ? Int(info.pti_threadnum) : 0
    }

    /// Names of this process's threads ("" for unnamed ones), for a report that found too many.
    static func threadNames() -> [String] {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return [] }
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var names: [String] = []
        for index in 0..<Int(count) {
            var info = thread_extended_info_data_t()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &infoCount)
                }
            }
            guard status == KERN_SUCCESS else { continue }
            let name = withUnsafeBytes(of: info.pth_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            names.append(name)
        }
        return names.sorted()
    }

    static func peakResidentBytes() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        // ru_maxrss is in bytes on macOS.
        return Int(usage.ru_maxrss)
    }

    /// Counts after close. Idle worker threads of Dispatch, the Swift pool and Core Media's
    /// shared queues retire some seconds after their last work, so it waits (at most 10 s) for
    /// the counts to come back within the allowance.
    static func settle(fds: Int, threads before: Int) async -> (fds: Int, threads: Int) {
        let deadline = ContinuousClock.now + .seconds(10)
        var current = (fds: openFileDescriptors(), threads: threads())
        while current.fds > fds + SoakCommand.leakAllowance || current.threads > before + SoakCommand.leakAllowance,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            current = (openFileDescriptors(), threads())
        }
        return current
    }
}

extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
