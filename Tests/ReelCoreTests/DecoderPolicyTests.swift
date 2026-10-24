import Testing
@testable import ReelCore

@Suite struct DecoderPolicyTests {
    private let policy = DecoderPolicy()

    @Test func h264AndHEVCUseHardware() {
        #expect(policy.decide(for: VideoStreamTraits(codec: "h264")).kind == .hardware)
        #expect(policy.decide(for: VideoStreamTraits(codec: "hevc", bitDepth: 10)).kind == .hardware)
        #expect(policy.decide(for: VideoStreamTraits(codec: "hevc", bitDepth: 8)).reason == .hardwareSupported)
    }

    @Test func vp9UsesHardwareAndAV1UsesHardwareWhenSupported() {
        #expect(policy.decide(for: VideoStreamTraits(codec: "vp9", bitDepth: 10)).kind == .hardware)
        #expect(policy.decide(for: VideoStreamTraits(codec: "av1", bitDepth: 10)).kind == .hardware)
        let noAV1 = DecoderPolicy(support: HardwareDecodeSupport(av1: false))
        let decision = noAV1.decide(for: VideoStreamTraits(codec: "av1"))
        #expect(decision.kind == .software)
        #expect(decision.reason == .hardwareUnavailable)
    }

    @Test func unsupportedProfilesUseSoftware() {
        let high10 = policy.decide(for: VideoStreamTraits(codec: "h264", bitDepth: 10))
        #expect(high10 == DecoderDecision(kind: .software, reason: .unsupportedProfile))
        let hevc444 = policy.decide(for: VideoStreamTraits(codec: "hevc", bitDepth: 10, chroma: .yuv444))
        #expect(hevc444.kind == .software)
        let hevc12 = policy.decide(for: VideoStreamTraits(codec: "hevc", bitDepth: 12))
        #expect(hevc12.kind == .software)
    }

    @Test func otherCodecsUseSoftware() {
        for codec in ["mpeg4", "flv1", "mpeg2video", "vc1", "theora"] {
            let decision = policy.decide(for: VideoStreamTraits(codec: codec))
            #expect(decision == DecoderDecision(kind: .software, reason: .unsupportedCodec))
        }
    }

    @Test func codecNamesAreCaseInsensitive() {
        #expect(policy.decide(for: VideoStreamTraits(codec: "HEVC")).kind == .hardware)
    }

    @Test func settingOffForcesSoftware() {
        let off = DecoderPolicy(hardwareEnabled: false)
        let decision = off.decide(for: VideoStreamTraits(codec: "hevc", bitDepth: 10))
        #expect(decision == DecoderDecision(kind: .software, reason: .disabledInSettings))
    }

    @Test func forcedDecoderWinsOverEverything() {
        let forcedHardware = DecoderPolicy(forced: .hardware, hardwareEnabled: false)
        #expect(forcedHardware.decide(for: VideoStreamTraits(codec: "mpeg4")).kind == .hardware)
        let forcedSoftware = DecoderPolicy(forced: .software)
        let decision = forcedSoftware.decide(for: VideoStreamTraits(codec: "h264"))
        #expect(decision == DecoderDecision(kind: .software, reason: .forcedByEnvironment))
    }

    @Test func environmentVariableSelectsTheForcedDecoder() {
        let hw = DecoderPolicy(environment: ReelEnvironment(["REEL_FORCE_DECODER": "hw"]))
        #expect(hw.forced == .hardware)
        let sw = DecoderPolicy(environment: ReelEnvironment(["REEL_FORCE_DECODER": "SW"]))
        #expect(sw.forced == .software)
        let none = DecoderPolicy(environment: ReelEnvironment([:]))
        #expect(none.forced == nil)
        let junk = DecoderPolicy(environment: ReelEnvironment(["REEL_FORCE_DECODER": "gpu"]))
        #expect(junk.forced == nil)
    }
}

@Suite struct DecoderFailureTrackerTests {
    private let hardware = DecoderDecision(kind: .hardware, reason: .hardwareSupported)

    @Test func threeConsecutiveFailuresScheduleASwitchAtTheNextKeyframe() {
        var tracker = DecoderFailureTracker(initial: hardware)
        let first = tracker.recordFailure()
        let second = tracker.recordFailure()
        let third = tracker.recordFailure("VT error -12909")
        #expect(!first && !second && third)
        #expect(tracker.switchPending)
        #expect(tracker.current == .hardware)
        let firstKeyframe = tracker.reachedKeyframe()
        #expect(firstKeyframe == .software)
        #expect(tracker.current == .software)
        #expect(!tracker.switchPending)
        let secondKeyframe = tracker.reachedKeyframe()
        #expect(secondKeyframe == nil)
    }

    @Test func aSuccessResetsTheCount() {
        var tracker = DecoderFailureTracker(initial: hardware)
        tracker.recordFailure()
        tracker.recordFailure()
        tracker.recordSuccess()
        let first = tracker.recordFailure()
        let second = tracker.recordFailure()
        #expect(!first && !second)
        #expect(!tracker.switchPending)
        #expect(tracker.consecutiveFailures == 2)
    }

    @Test func keyframeWithoutAPendingSwitchChangesNothing() {
        var tracker = DecoderFailureTracker(initial: hardware)
        tracker.recordFailure()
        let switched = tracker.reachedKeyframe()
        #expect(switched == nil)
        #expect(tracker.current == .hardware)
    }

    @Test func sessionCreationFailureSwitchesAtOnce() {
        var tracker = DecoderFailureTracker(initial: hardware)
        let switched = tracker.recordSessionCreationFailure("no session")
        #expect(switched)
        #expect(tracker.current == .software)
        #expect(tracker.lastFailureNote == "no session")
    }

    @Test func softwareDecodingNeverFallsBack() {
        var tracker = DecoderFailureTracker(initial: DecoderDecision(kind: .software, reason: .unsupportedCodec))
        for _ in 0..<5 { tracker.recordFailure() }
        #expect(!tracker.switchPending)
        let switched = tracker.recordSessionCreationFailure()
        #expect(!switched)
        #expect(tracker.current == .software)
    }

    @Test func forcedHardwareNeverFallsBack() {
        var tracker = DecoderFailureTracker(initial: DecoderDecision(kind: .hardware, reason: .forcedByEnvironment))
        for _ in 0..<5 { tracker.recordFailure() }
        #expect(!tracker.switchPending)
        let switched = tracker.recordSessionCreationFailure()
        #expect(!switched)
        #expect(tracker.current == .hardware)
    }
}
