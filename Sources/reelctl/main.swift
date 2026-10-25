import Foundation
import ReelCore
import ReelEngine

// Headless tool: never opens a window and never attaches an audio renderer (engines are
// created with the `.headless` configuration, which attaches none unless REEL_ALLOW_AUDIO=1).

let usage = """
    usage: reelctl probe <file> [--no-external] [--json]
           reelctl probe --build-info [--json]
           reelctl decode-bench <file> [--decoder hw|sw|auto] [--json]
           reelctl seek-bench <file> [--runs N] [--with-thumbs] [--json] [--decoder hw|sw|auto] [--seed N]
                              [--psnr-samples N]
           reelctl av-sync <file> [--json] [--seeks N] [--rate R] [--seed N]
           reelctl subs <file> [--track T] [--external path] [--no-external] [--at s] [--size WxH]
                        [--frames N] [--out png] [--dump-text] [--json]
           reelctl thumbs <file> [--runs N] [--fresh-cache] [--cold] [--out-dir dir] [--decoder hw|sw|auto] [--json]
           reelctl episodes <file> [--json]
    """

/// Parsed command line: positional arguments, boolean flags and `--name value` options.
struct CommandArguments {
    static let valueOptions: Set<String> = [
        "--decoder", "--runs", "--seed", "--psnr-samples", "--seeks", "--rate",
        "--track", "--external", "--at", "--size", "--frames", "--out", "--out-dir",
    ]

    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if CommandArguments.valueOptions.contains(argument) {
                guard index + 1 < arguments.count else { throw UsageError("\(argument) needs a value") }
                options[argument] = arguments[index + 1]
                index += 2
                continue
            }
            if argument.hasPrefix("--") { flags.insert(argument) } else { positional.append(argument) }
            index += 1
        }
    }

    var json: Bool { flags.contains("--json") }

    func int(_ name: String, default value: Int) throws -> Int {
        guard let text = options[name] else { return value }
        guard let parsed = Int(text), parsed > 0 else { throw UsageError("\(name) must be a positive integer") }
        return parsed
    }

    func double(_ name: String, default value: Double) throws -> Double {
        guard let text = options[name] else { return value }
        guard let parsed = Double(text), parsed > 0 else { throw UsageError("\(name) must be a positive number") }
        return parsed
    }

    /// The media file argument, which must exist.
    func file() throws -> URL {
        guard let path = positional.first else { throw UsageError("missing <file>") }
        let url = URL(filePath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw UsageError("no such file: \(path)")
        }
        return url
    }

    /// `--decoder hw|sw|auto`; nil for auto.
    func decoder() throws -> VideoDecoderKind? {
        switch options["--decoder"]?.lowercased() {
        case nil, "auto": return nil
        case "hw", "hardware": return .hardware
        case "sw", "software": return .software
        case let other?: throw UsageError("unknown decoder \(other); use hw, sw or auto")
        }
    }
}

struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// Prints a value as pretty, key-sorted JSON.
func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

/// Configuration for engines made by benches: silent, no display sleep assertion, and the
/// decoder forced when `--decoder` asks for one.
func headlessConfiguration(decoder: VideoDecoderKind?) -> PlaybackEngine.Configuration {
    var values = ProcessInfo.processInfo.environment
    switch decoder {
    case .hardware?: values["REEL_FORCE_DECODER"] = "hw"
    case .software?: values["REEL_FORCE_DECODER"] = "sw"
    case nil: break
    }
    return PlaybackEngine.Configuration(audioMode: .headless, environment: ReelEnvironment(values), preventsDisplaySleep: false)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage) }

do {
    let parsed = try CommandArguments(Array(arguments.dropFirst()))
    let status: Int32
    switch command {
    case "probe":
        status = try ProbeCommand.run(parsed)
    case "decode-bench":
        status = try await DecodeBenchCommand.run(parsed)
    case "seek-bench":
        status = try await SeekBenchCommand.run(parsed)
    case "av-sync":
        status = try await AVSyncCommand.run(parsed)
    case "subs":
        status = try await SubsCommand.run(parsed)
    case "thumbs":
        status = try await ThumbsCommand.run(parsed)
    case "episodes":
        status = try EpisodesCommand.run(parsed)
    case "-h", "--help", "help":
        print(usage)
        status = 0
    default:
        fail("unknown command: \(command)\n" + usage)
    }
    exit(status)
} catch let error as UsageError {
    fail("\(error.description)\n" + usage)
} catch {
    fail("reelctl \(command): \(error.localizedDescription)", code: 1)
}
