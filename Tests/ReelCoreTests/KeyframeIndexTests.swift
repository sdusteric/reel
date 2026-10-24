import Foundation
import Testing
@testable import ReelCore

@Suite struct KeyframeIndexTests {
    /// HEVC at 24 fps with 8 B-frames: dts runs a few frames behind pts, GOP every 10.4 s.
    private static let frame = MediaTime(microseconds: 41_667)
    private static let reorderDelay = MediaTime(microseconds: 41_667 * 3)

    private static func hevcIndex(gops: Int) -> KeyframeIndex {
        KeyframeIndex((0..<gops).map { gop in
            let pts = MediaTime.seconds(10.4 * Double(gop))
            return KeyframeIndex.Entry(
                pts: pts,
                dts: pts - reorderDelay,
                pos: Int64(gop) * 26_000_000,
                kind: gop == 0 ? .idr : .cra
            )
        })
    }

    @Test func emptyIndexHasNoEntries() {
        let index = KeyframeIndex()
        #expect(index.isEmpty)
        #expect(index.entry(atOrBefore: .seconds(5)) == nil)
        #expect(index.next(after: .zero) == nil)
        #expect(index.previous(before: .seconds(1)) == nil)
    }

    @Test func atOrBeforeReturnsTheKeyframeThatStartsTheGOP() {
        let index = Self.hevcIndex(gops: 6)
        #expect(index.entry(atOrBefore: .seconds(0))?.pts == .zero)
        #expect(index.entry(atOrBefore: .seconds(10.39))?.pts == .zero)
        #expect(index.entry(atOrBefore: .seconds(10.4))?.pts == .seconds(10.4))
        #expect(index.entry(atOrBefore: .seconds(31.0))?.pts == .seconds(20.8))
        #expect(index.entry(atOrBefore: .seconds(999))?.pts == .seconds(52))
    }

    @Test func targetBeforeTheFirstKeyframeHasNoStart() {
        let index = KeyframeIndex([KeyframeIndex.Entry(pts: .milliseconds(80), kind: .idr)])
        #expect(index.entry(atOrBefore: .milliseconds(40)) == nil)
        #expect(index.next(after: .milliseconds(40))?.pts == .milliseconds(80))
    }

    @Test func lookupByPTSAvoidsTheExtraGOPThatDTSWouldPick() {
        // A target 0.2 s after a keyframe's pts. Its dts is reorderDelay earlier, so a dts-based
        // search for the target would still land on this keyframe, but a target between
        // dts and pts would land in the previous GOP. Lookup by pts never does that.
        let index = Self.hevcIndex(gops: 4)
        let keyframe = MediaTime.seconds(20.8)
        let target = keyframe + .milliseconds(200)
        #expect(index.entry(atOrBefore: target)?.pts == keyframe)
        let betweenDTSAndPTS = keyframe - Self.frame
        #expect(index.entry(atOrBefore: betweenDTSAndPTS)?.pts == .seconds(10.4))
        #expect(index.entry(atOrBefore: target)?.dts == keyframe - Self.reorderDelay)
    }

    @Test func nextAfterIsStrictlyLater() {
        let index = Self.hevcIndex(gops: 3)
        #expect(index.next(after: .zero)?.pts == .seconds(10.4))
        #expect(index.next(after: .seconds(10.4))?.pts == .seconds(20.8))
        #expect(index.next(after: .seconds(20.8)) == nil)
        #expect(index.next(after: .seconds(-1))?.pts == .zero)
    }

    @Test func previousBeforeIsStrictlyEarlier() {
        let index = Self.hevcIndex(gops: 3)
        #expect(index.previous(before: .seconds(10.4))?.pts == .zero)
        #expect(index.previous(before: .seconds(10.5))?.pts == .seconds(10.4))
        #expect(index.previous(before: .zero) == nil)
    }

    @Test func insertKeepsEntriesSortedWhateverTheOrder() {
        var index = KeyframeIndex()
        for seconds in [20.0, 0.0, 30.0, 10.0, 5.0] {
            let added = index.insert(KeyframeIndex.Entry(pts: .seconds(seconds)))
            #expect(added)
        }
        #expect(index.entries.map(\.pts.seconds) == [0, 5, 10, 20, 30])
        #expect(index.count == 5)
        #expect(index.first?.pts == .zero)
        #expect(index.last?.pts == .seconds(30))
    }

    @Test func insertMergesDuplicatesAndFillsMissingFields() {
        // Cues give pts and position; the demuxer later reads the packet and adds dts and kind.
        var index = KeyframeIndex()
        index.insert(KeyframeIndex.Entry(pts: .seconds(10.4), pos: 1_000))
        index.insert(KeyframeIndex.Entry(pts: .seconds(20.8)))
        let added = index.insert(KeyframeIndex.Entry(pts: .seconds(10.4), dts: .seconds(10.275), pos: 9_999, kind: .cra))
        #expect(!added)
        #expect(index.count == 2)
        let merged = index.entry(atOrBefore: .seconds(11))
        #expect(merged?.pos == 1_000)
        #expect(merged?.dts == .seconds(10.275))
        #expect(merged?.kind == .cra)
    }

    @Test func mergeNeverDowngradesAKnownKind() {
        var index = KeyframeIndex([KeyframeIndex.Entry(pts: .zero, kind: .idr)])
        index.insert(KeyframeIndex.Entry(pts: .zero, kind: .other))
        #expect(index.first?.kind == .idr)
    }

    @Test func entriesInRangeAreInclusive() {
        let index = Self.hevcIndex(gops: 6)
        let slice = index.entries(in: .seconds(10.4) ... .seconds(31.2))
        #expect(slice.map(\.pts) == [.seconds(10.4), .seconds(20.8), .seconds(31.2)])
        #expect(index.entries(in: .seconds(1) ... .seconds(2)).isEmpty)
    }

    @Test func gopBoundsForAWorstCaseTarget() {
        // The frame before the next keyframe is the worst case an exact seek can hit.
        let index = Self.hevcIndex(gops: 3)
        let gopEnd = index.next(after: .seconds(15))?.pts
        #expect(gopEnd == .seconds(20.8))
        let worst = (gopEnd ?? .zero) - Self.frame
        #expect(index.entry(atOrBefore: worst)?.pts == .seconds(10.4))
    }

    @Test func lookupsScaleToLongFiles() {
        // Two hours of 2 s GOPs.
        let index = KeyframeIndex((0..<3_600).map { KeyframeIndex.Entry(pts: .seconds(Double($0) * 2)) })
        #expect(index.entry(atOrBefore: .seconds(5_001))?.pts == .seconds(5_000))
        #expect(index.next(after: .seconds(5_001))?.pts == .seconds(5_002))
    }
}
