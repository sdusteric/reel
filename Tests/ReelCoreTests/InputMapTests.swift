import Testing
@testable import ReelCore

@Suite struct InputMapTests {
    private let map = InputMap.standard

    private func action(_ text: String) -> InputAction? {
        guard let chord = InputMap.parseChord(text) else { return nil }
        return map.action(for: chord)
    }

    @Test func defaultConfParsesWithoutDiagnostics() {
        #expect(map.diagnostics.isEmpty)
        #expect(!map.bindings.isEmpty)
    }

    @Test func playPauseKeys() {
        #expect(action("SPACE") == .togglePause)
        #expect(action("p") == .togglePause)
        #expect(action("PLAYPAUSE") == .togglePause)
        #expect(map.action(for: KeyChord(.playPause)) == .togglePause)
    }

    @Test func arrowKeysSeekFiveSecondsAndPageKeysSixHundred() {
        #expect(action("RIGHT") == .seek(seconds: 5))
        #expect(action("LEFT") == .seek(seconds: -5))
        #expect(action("Shift+PGUP") == .seek(seconds: 600))
        #expect(action("Shift+PGDWN") == .seek(seconds: -600))
    }

    @Test func frameStepKeys() {
        #expect(action(".") == .frameStep(forward: true))
        #expect(action(",") == .frameStep(forward: false))
        #expect(action("Alt+RIGHT") == .frameStep(forward: true))
        #expect(action("Alt+LEFT") == .frameStep(forward: false))
    }

    @Test func volumeKeysUseFiveAndOneWithAlt() {
        #expect(action("UP") == .adjustVolume(delta: 5))
        #expect(action("DOWN") == .adjustVolume(delta: -5))
        #expect(action("Alt+UP") == .adjustVolume(delta: 1))
        #expect(action("Alt+DOWN") == .adjustVolume(delta: -1))
    }

    @Test func muteAndFullscreenKeys() {
        #expect(action("m") == .toggleMute)
        #expect(action("Meta+/") == .toggleMute)
        #expect(action("f") == .toggleFullscreen)
        #expect(action("Ctrl+Meta+f") == .toggleFullscreen)
        #expect(action("ENTER") == .toggleFullscreen)
        #expect(action("ESC") == .exitFullscreen)
    }

    @Test func appKeys() {
        #expect(action("Meta+o") == .openFile)
        #expect(action("Meta+w") == .closeFile)
        #expect(action("Meta+,") == .showSettings)
        #expect(action("Meta+q") == .quit)
        #expect(action("q") == .quit)
    }

    @Test func windowScaleKeys() {
        #expect(action("Meta+0") == .windowScale(.factor(0.5)))
        #expect(action("Meta+1") == .windowScale(.factor(1)))
        #expect(action("Meta+2") == .windowScale(.factor(2)))
        #expect(action("Meta+3") == .windowScale(.fitScreen))
    }

    @Test func everyBindingCommandMapsToATypedAction() {
        #expect(map.bindings.values.allSatisfy { $0 != .ignore })
    }

    @Test func menuLookupFindsAChordForAnAction() {
        #expect(map.chord(for: .openFile) == KeyChord(character: "o", modifiers: .command))
        #expect(map.chord(for: .showSettings) == KeyChord(character: ",", modifiers: .command))
        #expect(map.chord(for: .adjustVolume(delta: 42)) == nil)
    }

    // MARK: Chord syntax

    @Test func modifierNamesAreCaseInsensitiveAndAliased() {
        let expected = KeyChord(character: "s", modifiers: [.command, .shift])
        #expect(InputMap.parseChord("Meta+Shift+s") == expected)
        #expect(InputMap.parseChord("cmd+shift+S") == expected)
        #expect(InputMap.parseChord("Command+Shift+s") == expected)
        #expect(InputMap.parseChord("Option+x") == KeyChord(character: "x", modifiers: .option))
        #expect(InputMap.parseChord("Control+x") == KeyChord(character: "x", modifiers: .control))
    }

    @Test func uppercaseLetterMeansShift() {
        #expect(InputMap.parseChord("G") == KeyChord(character: "g", modifiers: .shift))
        #expect(KeyChord(character: "G") == KeyChord(character: "g", modifiers: .shift))
    }

    @Test func plusAndSharpKeys() {
        #expect(InputMap.parseChord("+") == KeyChord(character: "+"))
        #expect(InputMap.parseChord("Shift++") == KeyChord(character: "+", modifiers: .shift))
        #expect(InputMap.parseChord("SHARP") == KeyChord(character: "#"))
    }

    @Test func namedKeyAliases() {
        #expect(InputMap.parseChord("esc") == KeyChord(.escape))
        #expect(InputMap.parseChord("PGDOWN") == KeyChord(.pageDown))
        #expect(InputMap.parseChord("BS") == KeyChord(.backspace))
        #expect(InputMap.parseChord("F11") == KeyChord(.f11))
    }

    @Test func badChordsReturnNil() {
        #expect(InputMap.parseChord("") == nil)
        #expect(InputMap.parseChord("Hyper+x") == nil)
        #expect(InputMap.parseChord("Meta+") == nil)
        #expect(InputMap.parseChord("ab") == nil)
    }

    // MARK: File syntax

    @Test func commentsAndBlankLinesAreSkipped() {
        let parsed = InputMap(parsing: "# comment\n\n   \nSPACE cycle pause\n")
        #expect(parsed.bindings.count == 1)
        #expect(parsed.diagnostics.isEmpty)
    }

    @Test func tabsAndExtraSpacesSeparateTokens() {
        let parsed = InputMap(parsing: "RIGHT\t seek   10   exact")
        #expect(parsed.action(for: KeyChord(.right)) == .seek(seconds: 10))
    }

    @Test func laterLinesReplaceEarlierOnes() {
        let parsed = InputMap(parsing: "RIGHT seek 5\nRIGHT seek 30")
        #expect(parsed.action(for: KeyChord(.right)) == .seek(seconds: 30))
    }

    @Test func ignoreUnbindsAKey() {
        var user = InputMap.standard
        user.merge(parsing: "SPACE ignore\nRIGHT seek 10 exact")
        #expect(user.action(for: KeyChord(.space)) == nil)
        #expect(user.action(for: KeyChord(.right)) == .seek(seconds: 10))
        #expect(user.action(for: KeyChord(.left)) == .seek(seconds: -5))
    }

    @Test func absoluteSeekIsRecognised() {
        let parsed = InputMap(parsing: "HOME seek 0 absolute")
        #expect(parsed.action(for: KeyChord(.home)) == .seekAbsolute(seconds: 0))
    }

    @Test func unsupportedCommandsAreReportedNotBound() {
        let parsed = InputMap(parsing: "Ctrl+Meta+t cycle ontop\nSPACE cycle pause\nShift+Meta+> add chapter 1")
        #expect(parsed.bindings.count == 1)
        #expect(parsed.diagnostics.map(\.line) == [1, 3])
        #expect(parsed.diagnostics.first?.message.contains("cycle ontop") == true)
    }

    @Test func malformedLinesAreReportedWithTheirLineNumber() {
        let parsed = InputMap(parsing: "SPACE\nBogus+x cycle pause\nRIGHT seek abc\nUP add volume nope")
        #expect(parsed.bindings.isEmpty)
        #expect(parsed.diagnostics.map(\.line) == [1, 2, 3, 4])
    }

    @Test func chordDescriptionRoundTripsThroughTheParser() {
        let chord = KeyChord(character: "f", modifiers: [.control, .command])
        #expect(chord.description == "Ctrl+Meta+f")
        #expect(InputMap.parseChord(chord.description) == chord)
    }

    // MARK: M2 rows (design section 10, as in IINA's iina-default-input.conf)

    @Test func subtitleLineKeys() {
        #expect(action("Shift+RIGHT") == .subtitleLine(forward: true))
        #expect(action("Shift+LEFT") == .subtitleLine(forward: false))
    }

    @Test func subtitleDelayKeysAreShiftedLetters() {
        #expect(action("Z") == .adjustSubtitleDelay(seconds: -0.5))
        #expect(action("X") == .adjustSubtitleDelay(seconds: 0.5))
        #expect(action("Alt+Z") == .adjustSubtitleDelay(seconds: -0.1))
        #expect(action("Alt+X") == .adjustSubtitleDelay(seconds: 0.1))
        #expect(action("C") == .setSubtitleDelay(seconds: 0))
        #expect(map.action(for: KeyChord(character: "z", modifiers: .shift)) == .adjustSubtitleDelay(seconds: -0.5))
        // Lowercase z, x and c are not bound (the M1 draft had them wrong).
        #expect(action("z") == nil)
        #expect(action("x") == nil)
        #expect(action("c") == nil)
    }

    @Test func audioDelayKeysUseParenthesesAndUnderscore() {
        #expect(action("Shift+(") == .adjustAudioDelay(seconds: 0.5))
        #expect(action("Shift+)") == .adjustAudioDelay(seconds: -0.5))
        #expect(action("Alt+Shift+(") == .adjustAudioDelay(seconds: 0.1))
        #expect(action("Alt+Shift+)") == .adjustAudioDelay(seconds: -0.1))
        #expect(action("Shift+_") == .setAudioDelay(seconds: 0))
        // The key handler sends Shift+9 as "(" without Shift, as mpv does.
        #expect(map.action(for: KeyChord(character: "(")) == .adjustAudioDelay(seconds: 0.5))
        #expect(map.action(for: KeyChord(character: "(", modifiers: .option)) == .adjustAudioDelay(seconds: 0.1))
        #expect(map.action(for: KeyChord(character: "_")) == .setAudioDelay(seconds: 0))
    }

    @Test func subtitleSizePositionAndVisibilityKeys() {
        #expect(action("G") == .adjustSubtitleScale(delta: 0.1))
        #expect(action("F") == .adjustSubtitleScale(delta: -0.1))
        #expect(action("r") == .adjustSubtitlePosition(delta: -1))
        #expect(action("R") == .adjustSubtitlePosition(delta: 1))
        #expect(action("t") == .adjustSubtitlePosition(delta: 1))
        #expect(action("v") == .toggleSubtitleVisibility)
        // Shift+F is subtitle size; plain f stays fullscreen.
        #expect(action("f") == .toggleFullscreen)
    }

    @Test func trackCycleKeys() {
        #expect(action("Ctrl+Meta+s") == .cycleTrack(.subtitle))
        #expect(action("Ctrl+Meta+a") == .cycleTrack(.audio))
        #expect(action("Ctrl+Meta+v") == .cycleTrack(.video))
    }

    @Test func episodeKeysIncludeMediaAndMouseButtons() {
        #expect(action("Meta+RIGHT") == .episode(forward: true))
        #expect(action("Meta+LEFT") == .episode(forward: false))
        #expect(action("NEXT") == .episode(forward: true))
        #expect(action("PREV") == .episode(forward: false))
        #expect(map.action(for: KeyChord(.mouseForward)) == .episode(forward: true))
        #expect(map.action(for: KeyChord(.mouseBack)) == .episode(forward: false))
    }

    @Test func speedKeys() {
        #expect(action("Meta+]") == .multiplySpeed(factor: 2))
        #expect(action("Meta+[") == .multiplySpeed(factor: 0.5))
        #expect(action("Alt+Meta+]") == .multiplySpeed(factor: 1.1))
        #expect(action("Alt+Meta+[") == .multiplySpeed(factor: 1 / 1.1))
        #expect(action("Meta+\\") == .setSpeed(1))
    }

    @Test func mediaSeekKeys() {
        #expect(map.action(for: KeyChord(.mediaForward)) == .seek(seconds: 15))
        #expect(map.action(for: KeyChord(.mediaRewind)) == .seek(seconds: -15))
    }

    @Test func screenshotLoopAndPictureInPictureKeys() {
        #expect(action("Meta+s") == .screenshot)
        #expect(action("Meta+l") == .abLoop)
        #expect(action("Meta+L") == .toggleFileLoop)
        #expect(map.action(for: KeyChord(character: "l", modifiers: [.command, .shift])) == .toggleFileLoop)
        #expect(action("Ctrl+Meta+p") == .togglePictureInPicture)
    }

    @Test func menuLookupFindsTheM2Chords() {
        #expect(map.chord(for: .screenshot) == KeyChord(character: "s", modifiers: .command))
        #expect(map.chord(for: .togglePictureInPicture) == KeyChord(character: "p", modifiers: [.control, .command]))
    }

    @Test func numbersAcceptSignsAndFractions() {
        #expect(InputMap.number("+0.1") == 0.1)
        #expect(InputMap.number("-1") == -1)
        #expect(InputMap.number("1/1.1") == 1 / 1.1)
        #expect(InputMap.number("1/0") == nil)
        #expect(InputMap.number("abc") == nil)
    }

    @Test func iinaFileSyntaxForM2CommandsParses() {
        let text = """
            Meta+L cycle-values loop "inf" "no"
            Alt+Meta+[ multiply speed 1/1.1
            G add sub-scale +0.1
            Shift+_ set audio-delay 0
            """
        let parsed = InputMap(parsing: text)
        #expect(parsed.diagnostics.isEmpty)
        #expect(parsed.bindings.count == 4)
    }
}
