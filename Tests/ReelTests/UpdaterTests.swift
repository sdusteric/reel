import Foundation
import Testing
@testable import Reel

/// The app's real factory, with injected inputs. Every case returns nil before Sparkle is touched.
@Suite struct UpdaterFactoryTests {
    static let app = URL(filePath: "/Applications/Reel.app", directoryHint: .isDirectory)

    @Test func noUpdaterInShotMode() {
        #expect(Updater.make(arguments: ["Reel", "--shot", "--scenario", "empty"], environment: [:], bundleURL: Self.app) == nil)
    }

    @Test func noUpdaterWithNoUpdatesVariable() {
        #expect(Updater.make(arguments: ["Reel"], environment: ["REEL_NO_UPDATES": "1"], bundleURL: Self.app) == nil)
    }

    @Test func noUpdaterOutsideAnAppBundle() {
        let bare = URL(filePath: "/tmp/reel/release", directoryHint: .isDirectory)
        #expect(Updater.make(arguments: ["Reel"], environment: [:], bundleURL: bare) == nil)
    }
}
