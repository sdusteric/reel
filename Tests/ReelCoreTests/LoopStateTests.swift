import Foundation
import Testing
@testable import ReelCore

@Suite struct LoopStateTests {
    @Test func abLoopSetsAThenBThenClears() {
        var loop = LoopState()
        #expect(loop.phase == .none)
        #expect(loop.menuTitle == "Set Loop Start")
        loop.toggleABLoop(at: .seconds(1_864))
        #expect(loop.phase == .startSet)
        #expect(loop.start == .seconds(1_864))
        #expect(loop.menuTitle == "Set Loop End")
        loop.toggleABLoop(at: .seconds(1_930))
        #expect(loop.phase == .active)
        #expect(loop.range == .seconds(1_864)...(.seconds(1_930)))
        #expect(loop.menuTitle == "Clear Loop")
        loop.toggleABLoop(at: .seconds(1_940))
        #expect(loop == LoopState())
    }

    @Test func bBeforeASwaps() {
        var loop = LoopState()
        loop.toggleABLoop(at: .seconds(50))
        loop.toggleABLoop(at: .seconds(20))
        #expect(loop.start == .seconds(20))
        #expect(loop.end == .seconds(50))
    }

    @Test func bEqualToAIsIgnored() {
        var loop = LoopState()
        loop.toggleABLoop(at: .seconds(5))
        loop.toggleABLoop(at: .seconds(5))
        #expect(loop.phase == .startSet)
    }

    @Test func reachingBJumpsToA() {
        let loop = LoopState(start: .seconds(10), end: .seconds(20))
        #expect(loop.loopTarget(at: .seconds(19.9)) == nil)
        #expect(loop.loopTarget(at: .seconds(20)) == .seconds(10))
        #expect(LoopState(start: .seconds(10)).loopTarget(at: .seconds(30)) == nil)
    }

    @Test func fileLoopRestartsAtZero() {
        var loop = LoopState()
        #expect(loop.endOfFileTarget == nil)
        loop.toggleFileLoop()
        #expect(loop.fileLoop)
        #expect(loop.endOfFileTarget == .zero)
        #expect(loop.fileLoopOSDText == "Loop File On")
        loop.toggleFileLoop()
        #expect(loop.fileLoopOSDText == "Loop File Off")
    }

    @Test func autoAdvanceOnlyWithoutAnyLoop() {
        #expect(LoopState().allowsAutoAdvance)
        #expect(!LoopState(fileLoop: true).allowsAutoAdvance)
        #expect(!LoopState(start: .seconds(3)).allowsAutoAdvance)
        #expect(!LoopState(start: .seconds(3), end: .seconds(9)).allowsAutoAdvance)
        var cleared = LoopState(start: .seconds(3), end: .seconds(9))
        cleared.clearABLoop()
        #expect(cleared.allowsAutoAdvance)
    }

    @Test func osdTextFollowsTheMockup() {
        var loop = LoopState()
        let duration = MediaTime.seconds(3_000)
        #expect(loop.abOSDText(duration: duration) == "Loop Off")
        loop.toggleABLoop(at: .seconds(1_864))
        #expect(loop.abOSDText(duration: duration) == "Loop from 31:04")
        loop.toggleABLoop(at: .seconds(1_930))
        #expect(loop.abOSDText(duration: duration) == "Loop 31:04 to 32:10")
    }

    @Test func roundTripsThroughJSON() throws {
        let loop = LoopState(start: .seconds(1), end: .seconds(2), fileLoop: true)
        let data = try JSONEncoder().encode(loop)
        #expect(try JSONDecoder().decode(LoopState.self, from: data) == loop)
    }
}
