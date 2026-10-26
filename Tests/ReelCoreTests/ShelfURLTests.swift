import Foundation
import Testing
@testable import ReelCore

@MainActor
private final class FakeHandler: ShelfActionHandling {
    var performed: [ShelfAction] = []
    func perform(_ action: ShelfAction) { performed.append(action) }
}

@MainActor
@Suite struct ShelfURLTests {
    private func parse(_ text: String) -> ShelfAction? {
        ShelfURL.parse(URL(string: text)!)
    }

    @Test func acceptsEveryAllowlistedAction() {
        #expect(parse("reel://open-recent") == .openRecent)
        #expect(parse("reel://check-for-updates") == .checkForUpdates)
        #expect(parse("reel://open-recent/") == .openRecent)
        #expect(parse("REEL://Open-Recent") == .openRecent)
    }

    @Test func advertisedActionsMatchTheAllowlist() {
        #expect(ShelfURL.advertisedActions == ["open-recent", "check-for-updates"])
    }

    @Test func rejectsUnknownHostsAndOtherSchemes() {
        #expect(parse("reel://delete-everything") == nil)
        #expect(parse("reel://") == nil)
        #expect(parse("reel:open-recent") == nil)
        #expect(parse("haul://open-recent") == nil)
        #expect(parse("https://open-recent") == nil)
        #expect(parse("file:///tmp/a.mkv") == nil)
    }

    @Test func rejectsParametersPathsAndAuthority() {
        #expect(parse("reel://open-recent?file=/tmp/a.mkv") == nil)
        #expect(parse("reel://open-recent#x") == nil)
        #expect(parse("reel://open-recent/extra") == nil)
        #expect(parse("reel://user@open-recent") == nil)
        #expect(parse("reel://open-recent:80") == nil)
    }

    @Test func routerDispatchesAcceptedURLsToTheHandler() {
        let handler = FakeHandler()
        let router = ShelfRouter(handler: handler) { _ in }
        #expect(router.handle(URL(string: "reel://open-recent")!))
        #expect(router.handle(URL(string: "reel://check-for-updates")!))
        #expect(handler.performed == [.openRecent, .checkForUpdates])
    }

    @Test func routerIgnoresAndLogsRejectedURLsWithoutTheQuery() {
        let handler = FakeHandler()
        var lines: [String] = []
        let router = ShelfRouter(handler: handler) { lines.append($0) }
        #expect(!router.handle(URL(string: "reel://evil?secret=hunter2")!))
        #expect(!router.handle(URL(string: "reel://open-recent?secret=hunter2")!))
        #expect(handler.performed.isEmpty)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { !$0.contains("hunter2") && !$0.contains("secret") })
    }
}
