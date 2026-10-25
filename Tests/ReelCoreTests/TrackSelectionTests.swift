import Foundation
import Testing
@testable import ReelCore

@Suite struct TrackSelectionTests {
    private let tb = Rational(1, 1_000)

    private func subtitleStream(
        _ index: Int,
        codec: String,
        language: String?,
        title: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        isHearingImpaired: Bool = false
    ) -> StreamInfo {
        StreamInfo(
            index: index, kind: .subtitle, codec: codec, timeBase: tb, language: language, title: title,
            isDefault: isDefault, isForced: isForced, isHearingImpaired: isHearingImpaired
        )
    }

    private func audioStream(_ index: Int, codec: String, language: String?, channels: Int, layout: String?, title: String? = nil, isDefault: Bool = false) -> StreamInfo {
        StreamInfo(
            index: index, kind: .audio, codec: codec, timeBase: tb, language: language, title: title, isDefault: isDefault,
            audio: AudioParameters(sampleRate: 48_000, channels: channels, channelLayout: layout)
        )
    }

    /// The streams of `subs_tracks.mkv` (fixtures.sh).
    private var fixtureInfo: MediaInfo {
        MediaInfo(
            url: URL(filePath: "/fixtures/subs_tracks.mkv"),
            formatName: "matroska,webm",
            streams: [
                StreamInfo(index: 0, kind: .video, codec: "h264", timeBase: tb, video: VideoParameters(width: 1280, height: 720)),
                audioStream(1, codec: "eac3", language: "eng", channels: 6, layout: "5.1(side)", isDefault: true),
                audioStream(2, codec: "aac", language: "jpn", channels: 6, layout: "5.1"),
                subtitleStream(3, codec: "ass", language: "zho", title: "简英双语", isDefault: true),
                subtitleStream(4, codec: "ass", language: "zho", title: "繁英雙語"),
                subtitleStream(5, codec: "subrip", language: "eng"),
                subtitleStream(6, codec: "subrip", language: "eng", title: "SDH", isHearingImpaired: true),
            ],
            videoStreamIndex: 0,
            audioStreamIndex: 1
        )
    }

    private func external(_ name: String) -> SubtitleTrack {
        let url = URL(filePath: "/fixtures/\(name)")
        let found = ExternalSubtitles.discover(for: URL(filePath: "/fixtures/subs_tracks.mkv"), candidates: [url])
        return found[0].track
    }

    // MARK: Default choice

    @Test func embeddedSimplifiedChineseIsChosenWithoutExternalFiles() {
        let state = TrackState(info: fixtureInfo)
        #expect(state.selectedSubtitle == .embedded(streamIndex: 3))
        #expect(state.selectedAudio == 1)
    }

    @Test func externalFileBeatsEmbeddedTrackOfEqualRank() {
        let state = TrackState(info: fixtureInfo, external: [external("subs_tracks.zh-Hans.srt")])
        #expect(state.selectedSubtitle == .external(URL(filePath: "/fixtures/subs_tracks.zh-Hans.srt")))
    }

    @Test func simplifiedBeatsTraditionalWhateverTheOrder() {
        let tracks = [
            SubtitleTrack(id: .embedded(streamIndex: 1), language: "chi", title: "繁體中文", format: .ass, isDefault: true),
            SubtitleTrack(id: .embedded(streamIndex: 2), language: "chi", title: "CHS", format: .ass),
        ]
        #expect(TrackPreference.defaultSubtitle(tracks) == .embedded(streamIndex: 2))
    }

    @Test func traditionalExternalLosesToSimplifiedEmbedded() {
        let tracks = [
            SubtitleTrack(id: .embedded(streamIndex: 1), language: "zho", title: "简体", format: .ass),
            external("subs_tracks.cht.srt"),
        ]
        #expect(TrackPreference.defaultSubtitle(tracks) == .embedded(streamIndex: 1))
    }

    @Test func chineseBeatsEnglishAndEnglishBeatsOthers() {
        let english = SubtitleTrack(id: .embedded(streamIndex: 1), language: "eng", format: .srt, isDefault: true)
        let japanese = SubtitleTrack(id: .embedded(streamIndex: 2), language: "jpn", format: .pgs)
        let chinese = SubtitleTrack(id: .embedded(streamIndex: 3), language: "zh", format: .srt)
        #expect(TrackPreference.defaultSubtitle([japanese, english, chinese]) == .embedded(streamIndex: 3))
        #expect(TrackPreference.defaultSubtitle([japanese, english]) == .embedded(streamIndex: 1))
    }

    @Test func noMatchingLanguageStartsOff() {
        let tracks = [
            SubtitleTrack(id: .embedded(streamIndex: 2), language: "jpn", format: .pgs, isDefault: true),
            SubtitleTrack(id: .embedded(streamIndex: 3), format: .srt),
        ]
        #expect(TrackPreference.defaultSubtitle(tracks) == nil)
        #expect(TrackPreference.defaultSubtitle([]) == nil)
    }

    @Test func nonForcedBeatsForcedAndDefaultBreaksTies() {
        let forced = SubtitleTrack(id: .embedded(streamIndex: 1), language: "eng", format: .srt, isDefault: true, isForced: true)
        let plain = SubtitleTrack(id: .embedded(streamIndex: 2), language: "eng", format: .srt)
        let flagged = SubtitleTrack(id: .embedded(streamIndex: 3), language: "eng", format: .srt, isDefault: true)
        #expect(TrackPreference.defaultSubtitle([forced, plain, flagged]) == .embedded(streamIndex: 3))
        #expect(TrackPreference.defaultSubtitle([forced, plain]) == .embedded(streamIndex: 2))
    }

    @Test func forcedOnlyTrackNeedsMatchingAudio() {
        let forced = SubtitleTrack(id: .embedded(streamIndex: 4), language: "eng", format: .srt, isForced: true)
        #expect(TrackPreference.defaultSubtitle([forced], audioLanguage: "jpn") == nil)
        #expect(TrackPreference.defaultSubtitle([forced], audioLanguage: "eng") == .embedded(streamIndex: 4))
        #expect(TrackPreference.defaultSubtitle([forced], audioLanguage: nil) == nil)
    }

    @Test func unsupportedTracksAreNeverChosen() {
        let vobsub = SubtitleTrack(id: .external(URL(filePath: "/v/a.zh.idx")), language: "zh", format: .vobsub, unsupportedReason: "no")
        let english = SubtitleTrack(id: .embedded(streamIndex: 2), language: "en", format: .srt)
        #expect(TrackPreference.defaultSubtitle([vobsub, english]) == .embedded(streamIndex: 2))
    }

    @Test func defaultAudioIsTheContainerDefaultThenTheFirst() {
        let state = TrackState(info: fixtureInfo)
        #expect(TrackPreference.defaultAudio(state.audio) == 1)
        let plain = state.audio.map { track -> AudioTrack in
            var copy = track
            copy.isDefault = false
            return copy
        }
        #expect(TrackPreference.defaultAudio(plain) == 1)
        #expect(TrackPreference.defaultAudio([]) == nil)
    }

    // MARK: Labels

    @Test func subtitleLabelsFollowTheMockup() {
        let state = TrackState(info: fixtureInfo, external: [external("subs_tracks.zh-Hans.srt")])
        let labels = state.subtitles.map { $0.label() }
        #expect(labels[0] == TrackLabel(title: "Chinese (Simplified)", detail: "简英双语 · Default", tag: "ASS"))
        #expect(labels[1] == TrackLabel(title: "Chinese (Traditional)", detail: "繁英雙語", tag: "ASS"))
        #expect(labels[2] == TrackLabel(title: "English", detail: nil, tag: "SRT"))
        #expect(labels[3] == TrackLabel(title: "English SDH", detail: "Hearing impaired", tag: "SRT"))
        #expect(labels[4] == TrackLabel(title: "Chinese (Simplified)", detail: "External: subs_tracks.zh-Hans.srt", tag: "SRT"))
    }

    @Test func audioLabelsShowCodecAndChannels() {
        let state = TrackState(info: fixtureInfo)
        #expect(state.audio[0].label() == TrackLabel(title: "English", detail: "Default", tag: "E-AC-3 5.1"))
        #expect(state.audio[1].label() == TrackLabel(title: "Japanese", detail: nil, tag: "AAC 5.1"))
        let commentary = AudioTrack(streamIndex: 3, language: "eng", title: "Commentary", codec: "aac", channels: 2, channelLayout: "stereo")
        #expect(commentary.label() == TrackLabel(title: "English", detail: "Commentary", tag: "AAC 2.0"))
        #expect(AudioTrack(streamIndex: 4, codec: "truehd", channels: 8).formatTag == "TrueHD 7.1")
        #expect(AudioTrack(streamIndex: 5, codec: "opus", channels: 2).formatTag == "Opus 2.0")
        #expect(AudioTrack(streamIndex: 6, language: "cmn", codec: "aac", channels: 2).label().title == "Chinese (Mandarin)")
    }

    @Test func formatTagsCoverEveryCodec() {
        #expect(SubtitleFormat(codec: "ass").tag == "ASS")
        #expect(SubtitleFormat(codec: "ssa").tag == "ASS")
        #expect(SubtitleFormat(codec: "subrip").tag == "SRT")
        #expect(SubtitleFormat(codec: "webvtt").tag == "VTT")
        #expect(SubtitleFormat(codec: "mov_text").tag == "TX3G")
        #expect(SubtitleFormat(codec: "hdmv_pgs_subtitle").tag == "PGS")
        #expect(SubtitleFormat(codec: "dvd_subtitle").tag == "VobSub")
        #expect(SubtitleFormat(codec: "hdmv_pgs_subtitle").isBitmap)
        #expect(!SubtitleFormat(codec: "ass").isBitmap)
        #expect(SubtitleFormat(codec: "subrip").usesDefaultStyle)
        #expect(!SubtitleFormat(codec: "ass").usesDefaultStyle)
    }

    @Test func titleRepeatingTheLanguageIsDropped() {
        let track = SubtitleTrack(id: .embedded(streamIndex: 1), language: "eng", title: "English", format: .srt)
        #expect(track.label().detail == nil)
        let signs = SubtitleTrack(id: .embedded(streamIndex: 2), language: "eng", title: "Signs & Songs", format: .ass, isForced: true)
        #expect(signs.label().detail == "Signs & Songs · Forced")
    }

    @Test func trackWithoutLanguageUsesTitleOrOrdinal() {
        #expect(SubtitleTrack(id: .embedded(streamIndex: 1), title: "Commentary", format: .srt).label().title == "Commentary")
        #expect(SubtitleTrack(id: .embedded(streamIndex: 1), format: .srt).label(ordinal: 3).title == "Track 3")
    }

    @Test func longExternalNamesAreMiddleTruncated() {
        let name = "Northern.Line.S02E05.1080p.BluRay.x265.10bit-RLS.zh-Hans.srt"
        let track = SubtitleTrack(id: .external(URL(filePath: "/v/\(name)")), language: "zh-Hans", format: .srt)
        let detail = track.label().detail ?? ""
        #expect(detail.hasPrefix("External: Northern.Line"))
        #expect(detail.hasSuffix("zh-Hans.srt"))
        #expect(detail.contains("…"))
    }

    @Test func languageTagsNormalise() {
        #expect(LanguageTag("zho")?.code == "zh")
        #expect(LanguageTag("chi")?.code == "zh")
        #expect(LanguageTag("eng")?.code == "en")
        #expect(LanguageTag("ger")?.code == "de")
        #expect(LanguageTag("zh-Hant")?.chineseScript == .traditional)
        #expect(LanguageTag("zh_TW")?.chineseScript == .traditional)
        #expect(LanguageTag("zh-CN")?.chineseScript == .simplified)
        #expect(LanguageTag("chs")?.displayName() == "Chinese (Simplified)")
        #expect(LanguageTag("big5")?.displayName() == "Chinese (Traditional)")
        #expect(LanguageTag("pt-BR")?.displayName() == "Portuguese (Brazil)")
        #expect(LanguageTag("und") == nil)
        #expect(LanguageTag("1080p") == nil)
        #expect(LanguageTag("forced") == nil)
    }

    // MARK: Cycling

    @Test func subtitleCycleGoesThroughOffAndEverySupportedTrack() {
        var state = TrackState(info: fixtureInfo)
        var seen: [SubtitleSelection] = []
        for _ in 0..<5 {
            state.selectedSubtitle = state.nextSubtitleSelection()
            seen.append(state.selectedSubtitle)
        }
        #expect(seen == [.embedded(streamIndex: 4), .embedded(streamIndex: 5), .embedded(streamIndex: 6), .off, .embedded(streamIndex: 3)])
    }

    @Test func audioCycleWrapsAndVideoNeedsTwoTracks() {
        let state = TrackState(info: fixtureInfo)
        #expect(state.nextAudioStream() == 2)
        var second = state
        second.selectedAudio = 2
        #expect(second.nextAudioStream() == 1)
        #expect(state.nextVideoStream() == nil)
    }

    // MARK: Carry-over

    @Test func carryOverMatchesLanguageAndTitleThenLanguage() {
        let previous = TrackIdentity(streamIndex: 3, language: "zho", title: "繁英雙語", codec: "ass")
        let next = TrackState(info: fixtureInfo).subtitles
        #expect(TrackPreference.match(previous, in: next, sameFile: false) == .embedded(streamIndex: 4))
        let renamed = TrackIdentity(streamIndex: 9, language: "chi", title: "Something else", codec: "ass")
        #expect(TrackPreference.match(renamed, in: next, sameFile: false) == .embedded(streamIndex: 3))
        let french = TrackIdentity(streamIndex: 3, language: "fre", title: nil, codec: "ass")
        #expect(TrackPreference.match(french, in: next, sameFile: false) == nil)
    }

    @Test func sameFileMatchUsesTheStreamIndexWhenTheLanguageAgrees() {
        let tracks = TrackState(info: fixtureInfo).subtitles
        let sdh = TrackIdentity(streamIndex: 6, language: "eng", title: "SDH", codec: "subrip")
        #expect(TrackPreference.match(sdh, in: tracks, sameFile: true) == .embedded(streamIndex: 6))
        let moved = TrackIdentity(streamIndex: 3, language: "eng", title: "SDH", codec: "subrip")
        #expect(TrackPreference.match(moved, in: tracks, sameFile: true) == .embedded(streamIndex: 6))
    }

    @Test func externalChoiceIsFoundByFileName() {
        let sidecar = external("subs_tracks.zh-Hans.srt")
        let tracks = TrackState(info: fixtureInfo, external: [sidecar]).subtitles
        #expect(TrackPreference.match(sidecar.identity, in: tracks, sameFile: true) == sidecar.id)
    }

    @Test func audioCarryOverPrefersLanguageAndTitle() {
        let tracks = TrackState(info: fixtureInfo).audio
        #expect(TrackPreference.match(TrackIdentity(streamIndex: 7, language: "jpn", codec: "aac"), in: tracks, sameFile: false) == 2)
        #expect(TrackPreference.match(TrackIdentity(streamIndex: 2, language: "jpn", codec: "aac"), in: tracks, sameFile: true) == 2)
    }

    // MARK: Lines

    @Test func nextAndPreviousLineStepLikeAssStepSub() {
        let events = [
            SubtitleEventTime(start: .seconds(1), end: .seconds(3)),
            SubtitleEventTime(start: .seconds(4), end: .seconds(6)),
            SubtitleEventTime(start: .seconds(8), end: .seconds(9)),
        ]
        #expect(SubtitleLines.next(after: .seconds(0), in: events) == .seconds(1))
        #expect(SubtitleLines.next(after: .seconds(1), in: events) == .seconds(4))
        #expect(SubtitleLines.next(after: .seconds(8.5), in: events) == nil)
        // Inside the second line: back to the first.
        #expect(SubtitleLines.previous(before: .seconds(5), in: events) == .seconds(1))
        // In the gap after the second line: back to it.
        #expect(SubtitleLines.previous(before: .seconds(7), in: events) == .seconds(4))
        #expect(SubtitleLines.previous(before: .seconds(2), in: events) == nil)
        #expect(SubtitleLines.previous(before: .seconds(0.5), in: events) == nil)
    }
}
