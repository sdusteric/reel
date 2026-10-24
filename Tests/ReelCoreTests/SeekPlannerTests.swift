import Testing
@testable import ReelCore

@Suite struct SeekPlannerTests {
    private static let frame24 = MediaTime(microseconds: 41_667)
    private static let frame30 = MediaTime(microseconds: 33_333)
    private static let frame60 = MediaTime(microseconds: 16_667)

    private static func index(gop seconds: Double, count: Int = 6) -> KeyframeIndex {
        KeyframeIndex((0..<count).map {
            KeyframeIndex.Entry(pts: .seconds(seconds * Double($0)), kind: $0 == 0 ? .idr : .cra)
        })
    }

    private static let hevc = DecodeProfile(
        codec: "hevc", decoder: .hardware, width: 1920, height: 1080, frameDuration: frame24
    )
    private static let h264 = DecodeProfile(
        codec: "h264", decoder: .hardware, width: 1920, height: 1080, frameDuration: frame30
    )
    private static let av1 = DecodeProfile(
        codec: "av1", decoder: .hardware, width: 3840, height: 2160, frameDuration: frame60
    )
    private static let vp9 = DecodeProfile(
        codec: "vp9", decoder: .hardware, width: 3840, height: 2160, frameDuration: frame60
    )

    @Test func withoutALiveDecoderTheSeekStartsAtTheKeyframe() {
        let plan = SeekPlanner().planExact(
            target: .seconds(25), index: Self.index(gop: 10.4), decoder: nil, profile: Self.hevc
        )
        #expect(plan.start == .keyframe)
        #expect(plan.startPTS == .seconds(20.8))
        #expect(plan.keyframe?.pts == .seconds(20.8))
        #expect(plan.needsFlush)
        // (25 - 20.8) s at 24 fps is 100 frames, plus the keyframe.
        #expect(plan.framesToDecode == 101)
    }

    @Test func hevcWorstCaseMatchesTheMeasuredGOPCostAndNeedsNoPreview() {
        let target = MediaTime.seconds(10.4) - Self.frame24
        let plan = SeekPlanner().planExact(
            target: target, index: Self.index(gop: 10.4), decoder: nil, profile: Self.hevc
        )
        #expect(plan.start == .keyframe)
        #expect(plan.framesToDecode == 249)
        // Measured full GOP: 128 ms. Allow the restart overhead on top.
        #expect(plan.predictedMilliseconds > 120 && plan.predictedMilliseconds < 150)
        #expect(!plan.showsKeyframePreview)
    }

    @Test func h264AndAV1WorstCasesShowAKeyframePreview() {
        let h264Plan = SeekPlanner().planExact(
            target: .seconds(9.95), index: Self.index(gop: 10), decoder: nil, profile: Self.h264
        )
        #expect(h264Plan.predictedMilliseconds > 150)
        #expect(h264Plan.showsKeyframePreview)

        let av1Plan = SeekPlanner().planExact(
            target: .seconds(4.98), index: Self.index(gop: 5), decoder: nil, profile: Self.av1
        )
        #expect(av1Plan.predictedMilliseconds > 380 && av1Plan.predictedMilliseconds < 450)
        #expect(av1Plan.showsKeyframePreview)
    }

    @Test func vp9WorstCaseIsAboutOnePointTwoSeconds() {
        let plan = SeekPlanner().planExact(
            target: .seconds(4.98), index: Self.index(gop: 5), decoder: nil, profile: Self.vp9
        )
        #expect(plan.predictedMilliseconds > 1_000 && plan.predictedMilliseconds < 1_400)
        #expect(plan.showsKeyframePreview)
    }

    @Test func seekingToTheKeyframeItselfDecodesOneFrameWithoutPreview() {
        let plan = SeekPlanner().planExact(
            target: .seconds(10.4), index: Self.index(gop: 10.4), decoder: nil, profile: Self.hevc
        )
        #expect(plan.framesToDecode == 1)
        #expect(!plan.showsKeyframePreview)
    }

    @Test func forwardSeekWithinTheCurrentGOPContinuesTheDecoder() {
        // Playing at 5 s in a 10.4 s GOP, step 5 s: 120 frames, about 60 ms, no flush.
        let plan = SeekPlanner().planExact(
            target: .seconds(10), index: Self.index(gop: 10.4),
            decoder: DecoderPosition(lastSubmittedPTS: .seconds(5)), profile: Self.hevc
        )
        #expect(plan.start == .continueDecoder)
        #expect(plan.startPTS == .seconds(5))
        #expect(plan.framesToDecode == 120)
        #expect(!plan.needsFlush)
        #expect(!plan.showsKeyframePreview)
        #expect(plan.predictedMilliseconds > 55 && plan.predictedMilliseconds < 70)
    }

    @Test func continuingIsKeptEvenWhenSlowBecauseThereIsNoCheaperStart() {
        let plan = SeekPlanner().planExact(
            target: .seconds(4.9), index: Self.index(gop: 5),
            decoder: DecoderPosition(lastSubmittedPTS: .seconds(0.5)), profile: Self.av1
        )
        #expect(plan.start == .continueDecoder)
        #expect(plan.predictedMilliseconds > 150)
        #expect(!plan.showsKeyframePreview)
    }

    @Test func backwardSeekRestartsAtTheKeyframe() {
        let plan = SeekPlanner().planExact(
            target: .seconds(3), index: Self.index(gop: 10.4),
            decoder: DecoderPosition(lastSubmittedPTS: .seconds(8)), profile: Self.hevc
        )
        #expect(plan.start == .keyframe)
        #expect(plan.startPTS == .zero)
        #expect(plan.needsFlush)
    }

    @Test func seekPastTheNextKeyframeRestartsThere() {
        // Decoder is 2 s into GOP 0; the target is 1 s into GOP 1, so restarting is far cheaper.
        let plan = SeekPlanner().planExact(
            target: .seconds(11.4), index: Self.index(gop: 10.4),
            decoder: DecoderPosition(lastSubmittedPTS: .seconds(2)), profile: Self.hevc
        )
        #expect(plan.start == .keyframe)
        #expect(plan.startPTS == .seconds(10.4))
    }

    @Test func aShortHopAcrossAKeyframeRestartsWhenThatIsCheaper() {
        // Decoder at 10.0 s, target 10.5 s, keyframe at 10.4 s: 3 frames from the keyframe
        // beat 12 frames from the decoder even with the restart overhead.
        let plan = SeekPlanner().planExact(
            target: .seconds(10.5), index: Self.index(gop: 10.4),
            decoder: DecoderPosition(lastSubmittedPTS: .seconds(10.0)),
            profile: Self.hevc
        )
        #expect(plan.start == .keyframe)
        #expect(plan.framesToDecode == 3)
    }

    @Test func targetInsideTheLastSubmittedFrameRestarts() {
        let plan = SeekPlanner().planExact(
            target: .seconds(5.01), index: Self.index(gop: 10.4),
            decoder: DecoderPosition(lastSubmittedPTS: .seconds(5)), profile: Self.hevc
        )
        #expect(plan.start == .keyframe)
    }

    @Test func restartOverheadDecidesCloseTies() {
        var planner = SeekPlanner(restartOverheadMilliseconds: 50)
        let decoder = DecoderPosition(lastSubmittedPTS: .seconds(10.0))
        let index = Self.index(gop: 10.4)
        #expect(planner.planExact(target: .seconds(10.5), index: index, decoder: decoder, profile: Self.hevc)
            .start == .continueDecoder)
        planner.restartOverheadMilliseconds = 0
        #expect(planner.planExact(target: .seconds(10.5), index: index, decoder: decoder, profile: Self.hevc)
            .start == .keyframe)
    }

    @Test func previewSettingTurnsThePreviewOff() {
        let planner = SeekPlanner(keyframePreviewEnabled: false)
        let plan = planner.planExact(
            target: .seconds(9.95), index: Self.index(gop: 10), decoder: nil, profile: Self.h264
        )
        #expect(plan.predictedMilliseconds > 150)
        #expect(!plan.showsKeyframePreview)
    }

    @Test func skippableFramesLowerTheCostButKeepTheEnds() {
        var profile = Self.h264
        profile.skippableFraction = 0.5
        let plan = SeekPlanner().planExact(
            target: .seconds(9.95), index: Self.index(gop: 10), decoder: nil, profile: profile
        )
        let all = SeekPlanner().planExact(
            target: .seconds(9.95), index: Self.index(gop: 10), decoder: nil, profile: Self.h264
        )
        #expect(plan.framesToDecode < all.framesToDecode)
        #expect(plan.framesToDecode > all.framesToDecode / 2)
        #expect(plan.predictedMilliseconds < all.predictedMilliseconds)
    }

    @Test func skippableFramesLowerTheRestartCostInTheComparisonToo() {
        // Decoder at 10.0 s, target 10.75 s, keyframe at 10.4 s: 18 frames ahead against 9 from
        // the keyframe. With half the frames skippable a restart submits 6, continuing 10.
        var profile = Self.hevc
        profile.skippableFraction = 0.5
        let planner = SeekPlanner(restartOverheadMilliseconds: 1.5)
        let decoder = DecoderPosition(lastSubmittedPTS: .seconds(10.0))
        let plan = planner.planExact(target: .seconds(10.75), index: Self.index(gop: 10.4), decoder: decoder, profile: profile)
        #expect(plan.start == .keyframe, "restart \(plan.predictedMilliseconds) ms")
        #expect(plan.framesToDecode == 6)
        let unskipped = planner.planExact(target: .seconds(10.75), index: Self.index(gop: 10.4), decoder: decoder, profile: Self.hevc)
        #expect(unskipped.start == .keyframe)
    }

    @Test func emptyIndexDecodesFromTheFileStart() {
        let plan = SeekPlanner().planExact(
            target: .seconds(2), index: KeyframeIndex(), decoder: nil, profile: Self.hevc
        )
        #expect(plan.keyframe == nil)
        #expect(plan.startPTS == .zero)
        #expect(plan.start == .keyframe)
        #expect(!plan.showsKeyframePreview)
    }

    @Test func profileRejectsAZeroFrameDuration() {
        let profile = DecodeProfile(
            codec: "h264", decoder: .hardware, width: 640, height: 360, frameDuration: .zero
        )
        let plan = SeekPlanner().planExact(target: .seconds(1), index: Self.index(gop: 10), decoder: nil, profile: profile)
        #expect(plan.framesToDecode > 0)
    }

    // MARK: Scrub

    @Test func scrubShowsTheKeyframeBeforeTheTarget() {
        let plan = SeekPlanner().planScrub(
            target: .seconds(25), index: Self.index(gop: 10.4), displayedKeyframe: nil
        )
        #expect(plan == .showKeyframe(KeyframeIndex.Entry(pts: .seconds(20.8), kind: .cra)))
    }

    @Test func scrubWithinTheDisplayedGOPDoesNothing() {
        let plan = SeekPlanner().planScrub(
            target: .seconds(25), index: Self.index(gop: 10.4), displayedKeyframe: .seconds(20.8)
        )
        #expect(plan == .alreadyDisplayed)
    }

    @Test func scrubBeforeTheFirstKeyframeHasNothingToShow() {
        let index = KeyframeIndex([KeyframeIndex.Entry(pts: .milliseconds(80), kind: .idr)])
        #expect(SeekPlanner().planScrub(target: .milliseconds(10), index: index, displayedKeyframe: nil) == .noKeyframe)
    }

    // MARK: Rates

    @Test func ratesScaleWithFrameArea() {
        let rates = DecodeRates()
        let uhd = rates.framesPerSecond(codec: "av1", decoder: .hardware, width: 3840, height: 2160)
        let hd = rates.framesPerSecond(codec: "av1", decoder: .hardware, width: 1920, height: 1080)
        #expect(uhd == 740)
        #expect(hd > uhd * 3.9 && hd < uhd * 4.1)
    }

    @Test func unknownCodecsGetAConservativeRate() {
        let rate = DecodeRates().framesPerSecond(codec: "mpeg4", decoder: .software, width: 1920, height: 1080)
        #expect(rate > 0 && rate < 500)
    }

    @Test func recordedTimingsMoveTheEstimateTowardTheMeasurement() {
        var rates = DecodeRates()
        let before = rates.framesPerSecond(codec: "hevc", decoder: .hardware, width: 1920, height: 1080)
        rates.record(codec: "hevc", decoder: .hardware, width: 1920, height: 1080, frames: 1_000, seconds: 1)
        let after = rates.framesPerSecond(codec: "hevc", decoder: .hardware, width: 1920, height: 1080)
        #expect(after < before)
        #expect(after > 1_000)
        rates.record(codec: "hevc", decoder: .hardware, width: 1920, height: 1080, frames: 0, seconds: 1)
        #expect(rates.framesPerSecond(codec: "hevc", decoder: .hardware, width: 1920, height: 1080) == after)
    }

    @Test func slowerMeasuredRatesRaiseThePredictedCost() {
        var planner = SeekPlanner()
        let target = MediaTime.seconds(10)
        let before = planner.planExact(target: target, index: Self.index(gop: 10.4), decoder: nil, profile: Self.hevc)
        for _ in 0..<10 {
            planner.rates.record(codec: "hevc", decoder: .hardware, width: 1920, height: 1080, frames: 100, seconds: 1)
        }
        let after = planner.planExact(target: target, index: Self.index(gop: 10.4), decoder: nil, profile: Self.hevc)
        #expect(after.predictedMilliseconds > before.predictedMilliseconds * 3)
    }
}

@Suite struct ScrubCoalescerTests {
    @Test func firstRequestStartsImmediately() {
        var coalescer = ScrubCoalescer()
        let started = coalescer.request(.seconds(1))
        #expect(started == .seconds(1))
        #expect(coalescer.isBusy)
    }

    @Test func requestsWhileBusyKeepOnlyTheLatest() {
        var coalescer = ScrubCoalescer()
        _ = coalescer.request(.seconds(1))
        let queued = [coalescer.request(.seconds(2)), coalescer.request(.seconds(3)), coalescer.request(.seconds(4))]
        #expect(queued.allSatisfy { $0 == nil })
        #expect(coalescer.pending == .seconds(4))
        let next = coalescer.finish()
        #expect(next == .seconds(4))
        #expect(coalescer.inFlight == .seconds(4))
        let last = coalescer.finish()
        #expect(last == nil)
        #expect(!coalescer.isBusy)
    }

    @Test func onlyOneIsEverInFlight() {
        var coalescer = ScrubCoalescer()
        var started: [MediaTime] = []
        for second in 1...20 {
            if let next = coalescer.request(.seconds(Double(second))) { started.append(next) }
        }
        #expect(started == [.seconds(1)])
        if let next = coalescer.finish() { started.append(next) }
        #expect(started == [.seconds(1), .seconds(20)])
    }

    @Test func cancelDropsEverythingQueued() {
        var coalescer = ScrubCoalescer()
        _ = coalescer.request(.seconds(1))
        _ = coalescer.request(.seconds(2))
        coalescer.cancel()
        #expect(!coalescer.isBusy)
        #expect(coalescer.pending == nil)
        let afterCancel = coalescer.finish()
        #expect(afterCancel == nil)
        let restarted = coalescer.request(.seconds(9))
        #expect(restarted == .seconds(9))
    }
}
