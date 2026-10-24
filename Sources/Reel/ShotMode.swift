import CoreGraphics
import Foundation
import ReelCore
import ReelEngine
import ReelUI

/// `Reel --shot <scenario> --appearance light|dark --size WxH --out <png> [--fixture f --at s]`
/// (design 14, D16). Renders `PlayerSceneView` with `ImageRenderer` and exits. It never calls
/// `NSApplication.run`, never creates a window and never touches `NSApp`, so the frontmost app
/// cannot change. A bare `RunLoop.main` serves the main queue on the real main thread;
/// `dispatchMain()` would not do, since it exits the main thread and SwiftUI's renderer then
/// waits forever for it.
enum ShotMode {
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
                title = fixture.lastPathComponent
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
        guard let image = ShotRenderer.render(
            scenario: options.scenario,
            appearance: options.appearance,
            size: options.size,
            frame: frame,
            title: title,
            position: at,
            duration: .seconds(options.duration)
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

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("Reel --shot: \(message)\n".utf8))
    }
}
