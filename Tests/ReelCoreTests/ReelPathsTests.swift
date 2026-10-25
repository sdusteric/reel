import Foundation
import Testing
@testable import ReelCore

@Suite struct ReelPathsTests {
    @Test func reelHomeOverridesTheDefault() {
        let paths = ReelPaths(environment: ["REEL_HOME": "/tmp/reel-test-home", "HOME": "/Users/someone"])
        #expect(paths.home.path(percentEncoded: false) == "/tmp/reel-test-home/")
        #expect(paths.settingsFile.lastPathComponent == "settings.json")
        #expect(paths.stateFile.path(percentEncoded: false) == "/tmp/reel-test-home/state.json")
        #expect(paths.resumeFile.path(percentEncoded: false) == "/tmp/reel-test-home/resume.json")
        #expect(paths.logFile.path(percentEncoded: false) == "/tmp/reel-test-home/logs/reel.log")
        #expect(paths.cachesDirectory.path(percentEncoded: false) == "/tmp/reel-test-home/Caches/")
    }

    @Test func defaultHomeIsApplicationSupport() {
        for environment in [["HOME": "/Users/someone"], ["HOME": "/Users/someone", "REEL_HOME": ""]] {
            let paths = ReelPaths(environment: environment)
            #expect(paths.home.path(percentEncoded: false) == "/Users/someone/Library/Application Support/Reel/")
        }
    }

    @Test func tildeExpandsAgainstHome() {
        let paths = ReelPaths(environment: ["REEL_HOME": "~/reel-home", "HOME": "/Users/someone"])
        #expect(paths.home.path(percentEncoded: false) == "/Users/someone/reel-home/")
    }

    @Test func createDirectoriesMakesHomeAndLogs() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "reel-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = ReelPaths(home: base.appending(path: "home"))
        try paths.createDirectories()
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.logsDirectory.path(percentEncoded: false), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func iinaWatchLaterCanBeRedirectedOrDisabled() {
        let home = ["HOME": "/Users/someone"]
        let defaultDir = ReelEnvironment(home).iinaWatchLaterDirectory
        #expect(defaultDir?.path(percentEncoded: false)
            == "/Users/someone/Library/Application Support/com.colliderli.iina/watch_later/")
        let fake = ReelEnvironment(home.merging(["REEL_IINA_WATCH_LATER": "/tmp/fake-wl"]) { $1 })
        #expect(fake.iinaWatchLaterDirectory?.path(percentEncoded: false) == "/tmp/fake-wl/")
        let disabled = ReelEnvironment(home.merging(["REEL_IINA_WATCH_LATER": ""]) { $1 })
        #expect(disabled.iinaWatchLaterDirectory == nil)
    }

    @Test func switchesParseFromTheEnvironment() {
        #expect(ReelEnvironment(["REEL_FORCE_DECODER": "hw"]).forcedDecoder == .hardware)
        #expect(ReelEnvironment(["REEL_FORCE_DECODER": "SW"]).forcedDecoder == .software)
        #expect(ReelEnvironment(["REEL_FORCE_DECODER": "gpu"]).forcedDecoder == nil)
        #expect(ReelEnvironment([:]).allowsAudioOutput == false)
        #expect(ReelEnvironment(["REEL_ALLOW_AUDIO": "true"]).allowsAudioOutput == false)
        #expect(ReelEnvironment(["REEL_ALLOW_AUDIO": "1"]).allowsAudioOutput)
        #expect(ReelEnvironment(["REEL_LOG": "debug"]).debugLogging)
    }

    @Test func screenshotsGoToTheVariableThenReelHomeThenPictures() {
        let user = ["HOME": "/Users/someone"]
        let explicit = ReelEnvironment(user.merging(["REEL_SCREENSHOTS": "/tmp/shots", "REEL_HOME": "/tmp/reel-home"]) { $1 })
        #expect(explicit.screenshotsDirectory.path(percentEncoded: false) == "/tmp/shots/")
        let home = ReelEnvironment(user.merging(["REEL_HOME": "/tmp/reel-home"]) { $1 })
        #expect(home.screenshotsDirectory.path(percentEncoded: false) == "/tmp/reel-home/Screenshots/")
        let emptyShots = ReelEnvironment(user.merging(["REEL_SCREENSHOTS": "", "REEL_HOME": "/tmp/reel-home"]) { $1 })
        #expect(emptyShots.screenshotsDirectory.path(percentEncoded: false) == "/tmp/reel-home/Screenshots/")
        for environment in [user, user.merging(["REEL_HOME": "", "REEL_SCREENSHOTS": ""]) { $1 }] {
            #expect(ReelEnvironment(environment).screenshotsDirectory.path(percentEncoded: false) == "/Users/someone/Pictures/Reel/")
        }
    }

    @Test func fixturesDirectoryPrefersTheVariable() {
        let root = URL(filePath: "/repo", directoryHint: .isDirectory)
        #expect(ReelEnvironment([:]).fixturesDirectory(repoRoot: root)?.path(percentEncoded: false) == "/repo/build/fixtures/")
        #expect(ReelEnvironment(["REEL_FIXTURES": "/media/fx"]).fixturesDirectory(repoRoot: root)?
            .path(percentEncoded: false) == "/media/fx/")
        #expect(ReelEnvironment([:]).fixturesDirectory() == nil)
    }
}
