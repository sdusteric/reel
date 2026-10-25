import Foundation
import Testing
@testable import ReelCore

@Suite struct EnergyPolicyTests {
    // MARK: The section 7.9 table, one test per column

    @Test func playingVisibleRunsEverything() {
        let decision = EnergyPolicy.decide(EnergyInputs(playback: .playing))
        #expect(decision == EnergyDecision(
            videoDecode: true,
            readAhead: .full,
            audioDecode: true,
            timeEvents: .interval(seconds: 0.1),
            subtitleRenders: .whileActiveOrDue,
            thumbnails: .full,
            holdsDisplaySleepAssertion: true,
            holdsActivity: true
        ))
    }

    @Test func playingWithTheChromeHiddenSendsTimeOncePerSecond() {
        #expect(EnergyPolicy.decide(EnergyInputs(playback: .playing, chromeVisible: false)).timeEvents == .interval(seconds: 1))
    }

    @Test func pausedIsIdle() {
        let decision = EnergyPolicy.decide(EnergyInputs(playback: .paused))
        #expect(decision == EnergyDecision(
            videoDecode: false,
            readAhead: .finishFillThenBlock,
            audioDecode: false,
            timeEvents: .onChangeOnly,
            subtitleRenders: .onSeekOnly,
            thumbnails: .suspended,
            holdsDisplaySleepAssertion: false,
            holdsActivity: false
        ))
        #expect(decision.timeEvents.interval == nil)
    }

    @Test func pausedThumbnailsContinueOnlyWhileThePointerMovedRecently() {
        #expect(EnergyPolicy.decide(EnergyInputs(playback: .paused, pointerRecent: true)).thumbnails == .full)
        #expect(EnergyPolicy.decide(EnergyInputs(playback: .paused, pointerRecent: false)).thumbnails == .suspended)
        #expect(EnergyPolicy.decide(EnergyInputs(playback: .paused, pointerRecent: true, lowPower: true)).thumbnails == .coarse)
    }

    @Test func playingOccludedKeepsAudioOnly() {
        let decision = EnergyPolicy.decide(EnergyInputs(playback: .playing, occluded: true, pointerRecent: true))
        #expect(decision == EnergyDecision(
            videoDecode: false,
            readAhead: .audioOnly,
            audioDecode: true,
            timeEvents: .interval(seconds: 1),
            subtitleRenders: .none,
            thumbnails: .suspended,
            holdsDisplaySleepAssertion: false,
            holdsActivity: false
        ))
    }

    @Test func stoppedRunsNothing() {
        for pointer in [false, true] {
            let decision = EnergyPolicy.decide(EnergyInputs(playback: .stopped, pointerRecent: pointer))
            #expect(decision == EnergyDecision(
                videoDecode: false,
                readAhead: .none,
                audioDecode: false,
                timeEvents: .none,
                subtitleRenders: .none,
                thumbnails: .suspended,
                holdsDisplaySleepAssertion: false,
                holdsActivity: false
            ))
        }
    }

    @Test func occlusionMattersOnlyWhilePlaying() {
        #expect(EnergyPolicy.decide(EnergyInputs(playback: .paused, occluded: true)) == EnergyPolicy.decide(EnergyInputs(playback: .paused)))
        #expect(EnergyPolicy.decide(EnergyInputs(playback: .stopped, occluded: true)) == EnergyPolicy.decide(EnergyInputs(playback: .stopped)))
    }

    @Test func lowPowerModeStopsThumbnailsAfterTheCoarsePass() {
        #expect(EnergyPolicy.decide(EnergyInputs(playback: .playing, lowPower: true)).thumbnails == .coarse)
        #expect(EnergyPolicy.decide(EnergyInputs(playback: .playing, lowPower: true)).videoDecode)
        #expect(ThumbnailMode.coarse.runs && ThumbnailMode.full.runs && !ThumbnailMode.suspended.runs)
    }

    /// Every combination: the display sleep assertion and the activity are held exactly while
    /// playing visibly, and video decode never runs unless they are.
    @Test func assertionsFollowVisiblePlaybackInEveryCombination() {
        for playback in EnergyPlayback.allCases {
            for occluded in [false, true] {
                for pointer in [false, true] {
                    for lowPower in [false, true] {
                        for chrome in [false, true] {
                            let inputs = EnergyInputs(playback: playback, occluded: occluded, pointerRecent: pointer, lowPower: lowPower, chromeVisible: chrome)
                            let decision = EnergyPolicy.decide(inputs)
                            let visiblePlay = playback == .playing && !occluded
                            #expect(decision.holdsDisplaySleepAssertion == visiblePlay)
                            #expect(decision.holdsActivity == visiblePlay)
                            #expect(decision.videoDecode == visiblePlay)
                            #expect(decision.audioDecode == (playback == .playing))
                        }
                    }
                }
            }
        }
    }

    // MARK: Constants and helpers

    @Test func timingConstantsMatchTheDesign() {
        #expect(EnergyPolicy.occlusionDelay == 1)
        #expect(EnergyPolicy.pointerRecentSeconds == 10)
        #expect(EnergyPolicy.subtitleLookahead == 1)
    }

    @Test func timerLeewayIsTenPercent() {
        #expect(abs(EnergyPolicy.leeway(forInterval: 0.1) - 0.01) < 1e-12)
        #expect(EnergyPolicy.leeway(forInterval: 1) == 0.1)
        #expect(EnergyPolicy.leeway(forInterval: 0) == 0)
        #expect(EnergyPolicy.leeway(forInterval: .infinity) == 0)
    }

    @Test func playbackStatesMapWithTheirIntent() {
        #expect(EnergyPlayback(.playing, playIntent: false) == .playing)
        #expect(EnergyPlayback(.paused, playIntent: true) == .paused)
        #expect(EnergyPlayback(.ready, playIntent: false) == .paused)
        #expect(EnergyPlayback(.seeking, playIntent: true) == .playing)
        #expect(EnergyPlayback(.seeking, playIntent: false) == .paused)
        #expect(EnergyPlayback(.opening, playIntent: true) == .playing)
        #expect(EnergyPlayback(.ended, playIntent: true) == .stopped)
        #expect(EnergyPlayback(.idle, playIntent: false) == .stopped)
        #expect(EnergyPlayback(.failed, playIntent: true) == .stopped)
    }

    @Test func countersSubtractPerWindow() throws {
        let start = EnergyCounters(framesDecoded: 10, packetsRead: 30, subtitleRenders: 2, timeEvents: 5, thumbnailsDecoded: 1)
        let end = EnergyCounters(framesDecoded: 490, packetsRead: 990, subtitleRenders: 2, timeEvents: 205, thumbnailsDecoded: 1)
        #expect(end - start == EnergyCounters(framesDecoded: 480, packetsRead: 960, subtitleRenders: 0, timeEvents: 200, thumbnailsDecoded: 0))
        let json = String(decoding: try JSONEncoder().encode(EnergyCounters.zero), as: UTF8.self)
        for key in ["framesDecoded", "packetsRead", "subtitleRenders", "timeEvents", "thumbnailsDecoded"] {
            #expect(json.contains(key))
        }
    }
}
