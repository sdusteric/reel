import CoreGraphics
import Foundation
import ImageIO
import ReelCore
import ReelEngine
import ReelUI

/// `Reel --shot <scenario> --appearance light|dark --size WxH --out <png> [--fixture f --at s]`
/// (design 14, D16). Renders `PlayerSceneView` with `ImageRenderer` and exits. It never calls
/// `NSApplication.run`, never creates a window and never touches `NSApp`, so the frontmost app
/// cannot change. Picture in Picture and Now Playing are never started here: the pip scenario is
/// the model's placeholder state only. A bare `RunLoop.main` serves the main queue on the real
/// main thread; `dispatchMain()` would not do, since it exits the main thread and SwiftUI's
/// renderer then waits forever for it.
enum ShotMode {
    /// The subtitle scenarios draw the bilingual ASS track of this fixture (next to `--fixture`).
    static let subtitleFixtureName = "subs_tracks.mkv"
    static let subtitleTime = MediaTime.seconds(2)
    /// Where the hover pill of the thumbnail scenario sits, as in `ShotRenderer.makeModel`.
    static let thumbnailHoverFraction = 0.38
    static let m1Scenarios: Set<ShotScenario> = [.empty, .playing, .pausedOSD, .scrubbing]

    static func run(_ options: ShotOptions) -> Never {
        Task { @MainActor in
            let status = await render(options)
            exit(status)
        }
        while true {
            RunLoop.main.run(mode: .default, before: .distantFuture)
        }
    }

    private static func render(_ options: ShotOptions) async -> Int32 {
        let at = MediaTime.seconds(options.at)
        var frame: CGImage?
        var title = ShotRenderer.demoTitle
        if options.scenario != .empty {
            if let fixture = options.fixture {
                // The M2 scenarios keep the mockup's episode title so previous and next and the
                // next-episode card name the demo season; the M1 four show the fixture's name.
                if m1Scenarios.contains(options.scenario) { title = fixture.lastPathComponent }
                do {
                    frame = try await EngineFactory.grabFrame(url: fixture, at: at)
                } catch {
                    report("frame grab failed (\(error)); using a generated gradient")
                }
            }
            if frame == nil {
                frame = ShotRenderer.placeholderFrame()
            }
        }
        var subtitle: SubtitleBitmap?
        if options.scenario == .subtitles || options.scenario == .subtitlesLifted {
            // These shots exist to show libass output; the sample lines would pass the ink check.
            guard let rendered = await renderSubtitle(options) else { return 1 }
            subtitle = rendered
        }
        let thumbnail = await thumbnail(for: options)
        guard let image = ShotRenderer.render(
            scenario: options.scenario,
            appearance: options.appearance,
            size: options.size,
            frame: frame,
            title: title,
            position: at,
            duration: .seconds(options.duration),
            subtitleImage: subtitle?.image,
            subtitleRect: subtitle.map { pointRect($0.rect) },
            thumbnail: thumbnail
        ) else {
            report("ImageRenderer produced no image")
            return 1
        }
        do {
            try ShotRenderer.writePNG(image, to: options.output)
        } catch {
            report("\(error)")
            return 1
        }
        print("wrote \(options.output.path(percentEncoded: false)) (\(image.width)x\(image.height))")
        return 0
    }

    // MARK: Subtitles

    /// The subtitle fixture: next to `--fixture`, else in `REEL_FIXTURES`, else `build/fixtures`.
    static func subtitleFixture(for options: ShotOptions) -> URL? {
        var candidates: [URL] = []
        if let fixture = options.fixture {
            candidates.append(fixture.deletingLastPathComponent().appending(path: subtitleFixtureName))
        }
        let current = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
        if let folder = ReelEnvironment().fixturesDirectory(repoRoot: current) {
            candidates.append(folder.appending(path: subtitleFixtureName))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// libass output for the whole window at 2x: the embedded bilingual ASS track (简英双语), what
    /// the player picks when the sidecar file is ignored, at 2.0 s. The lifted scenario passes the
    /// lift the window would send to the engine.
    private static func renderSubtitle(_ options: ShotOptions) async -> SubtitleBitmap? {
        guard let url = subtitleFixture(for: options) else {
            report("\(subtitleFixtureName) not found; the subtitle shot needs libass output")
            return nil
        }
        let scale = ShotRenderer.scale
        let width = Int((options.size.width * scale).rounded())
        let height = Int((options.size.height * scale).rounded())
        let lift = ShotRenderer.subtitleLift(scenario: options.scenario, size: options.size).map { $0 * Double(scale) }
        do {
            let selection = try await Task.detached(priority: .userInitiated) { () throws -> SubtitleSelection in
                let demuxer = try Demuxer(url: url)
                defer { demuxer.stop() }
                return TrackState(info: demuxer.info).selectedSubtitle
            }.value
            let bitmap = try await EngineFactory.renderSubtitle(
                url: url,
                at: subtitleTime,
                width: width,
                height: height,
                selection: selection,
                bottomInset: lift
            )
            if let bitmap {
                let rect = bitmap.rect
                report("subtitle drawn by libass from \(subtitleFixtureName) at \(subtitleTime.seconds) s: \(rect.x),\(rect.y) \(rect.width)x\(rect.height)")
            } else {
                report("no subtitle at \(subtitleTime.seconds) s in \(subtitleFixtureName)")
            }
            return bitmap
        } catch {
            report("subtitle render failed (\(error)); the subtitle shot needs libass output")
            return nil
        }
    }

    /// Pixels at the shot scale to points, origin top-left.
    private static func pointRect(_ rect: PixelRect) -> CGRect {
        let scale = ShotRenderer.scale
        return CGRect(
            x: CGFloat(rect.x) / scale,
            y: CGFloat(rect.y) / scale,
            width: CGFloat(rect.width) / scale,
            height: CGFloat(rect.height) / scale
        )
    }

    // MARK: Thumbnails

    /// The thumbnail scenario uses `ThumbnailGenerator` on the fixture (no cache, nothing written);
    /// the next-episode card uses the same picture the app would, 30 s into the file.
    private static func thumbnail(for options: ShotOptions) async -> CGImage? {
        guard let fixture = options.fixture else { return nil }
        switch options.scenario {
        case .thumbnail:
            let generator = ThumbnailGenerator(url: fixture, key: nil, cache: nil)
            generator.start()
            let report = await generator.finished()
            let time = MediaTime.seconds(options.duration * thumbnailHoverFraction)
            guard let image = generator.thumbnail(at: time) ?? generator.thumbnail(at: .seconds(options.duration)) else {
                Self.report("no thumbnail generated (\(report.outcome.rawValue)\(report.error.map { ": \($0)" } ?? ""))")
                return nil
            }
            return decodeJPEG(image.jpeg)
        case .nextEpisode:
            return await EpisodeNavigator.cardThumbnail(for: fixture)
        default:
            return nil
        }
    }

    private static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("Reel --shot: \(message)\n".utf8))
    }
}
