import AppKit
import ReelCore
import ReelUI

/// Window-level actions the key table can trigger.
protocol PlayerCommandTarget: AnyObject {
    func openDocument()
    func closeFile()
    func showSettings()
    func toggleFullscreen()
    func exitFullscreen()
    func scaleWindow(_ scale: WindowScale)
    /// Cmd+S (design 9.12).
    func takeScreenshot()
}

/// Turns key events into `InputMap` actions (design section 10).
enum KeyHandling {
    /// Virtual key codes for the named keys input.conf uses.
    private static let namedKeys: [UInt16: NamedKey] = [
        49: .space, 36: .return, 76: .return, 53: .escape, 48: .tab, 51: .backspace, 117: .delete,
        123: .left, 124: .right, 125: .down, 126: .up, 116: .pageUp, 121: .pageDown, 115: .home, 119: .end,
        122: .f1, 120: .f2, 99: .f3, 118: .f4, 96: .f5, 97: .f6, 98: .f7, 100: .f8, 101: .f9, 109: .f10,
        103: .f11, 111: .f12,
    ]

    /// AppKit's numbers for the mouse side buttons (`MBTN_BACK`, `MBTN_FORWARD`).
    static let mouseBackButton = 3
    static let mouseForwardButton = 4

    static func chord(for event: NSEvent) -> KeyChord? {
        var modifiers: KeyModifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if let named = namedKeys[event.keyCode] {
            return KeyChord(named, modifiers)
        }
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
              let character = characters.first else { return nil }
        if !character.isLetter, flags.contains(.shift) {
            // charactersIgnoringModifiers keeps Shift, so Shift+9 arrives as "(", which is how
            // input.conf names it.
            modifiers.remove(.shift)
        }
        return KeyChord(character: character, modifiers: modifiers)
    }

    /// The chord for a mouse side button, or nil for any other button.
    static func chord(forMouseButton button: Int) -> KeyChord? {
        switch button {
        case mouseBackButton: KeyChord(.mouseBack)
        case mouseForwardButton: KeyChord(.mouseForward)
        default: nil
        }
    }

    /// Runs the bound action. Returns false when the key is unbound, so AppKit can beep or pass it on.
    /// An open panel takes Up, Down, Return and Esc first, then the Dolby Vision note and Video
    /// Info take Esc, then the next-episode card takes Return and Esc (design 9.7, 9.8, 9.13).
    @discardableResult
    static func handle(_ event: NSEvent, map: InputMap, model: PlayerModel, target: PlayerCommandTarget) -> Bool {
        guard let chord = chord(for: event) else { return false }
        if handleOverlayKey(chord, model: model) { return true }
        guard let action = map.action(for: chord) else { return false }
        perform(action, model: model, target: target)
        return true
    }

    /// Keys for the open panel, the Dolby Vision note and Video Info (Esc closes them, design
    /// 9.13) or the next-episode card. Only plain keys (Alt is allowed for the arrows, which
    /// panels ignore anyway).
    static func handleOverlayKey(_ chord: KeyChord, model: PlayerModel) -> Bool {
        guard case .named(let key) = chord.key, chord.modifiers.subtracting(.option).isEmpty else { return false }
        if model.activePanel != nil {
            switch key {
            case .up: return model.handlePanelKey(.up)
            case .down: return model.handlePanelKey(.down)
            case .return: return model.handlePanelKey(.confirm)
            case .escape: return model.handlePanelKey(.escape)
            default: return false
            }
        }
        if key == .escape, chord.modifiers.isEmpty, model.dismissTransient() {
            return true
        }
        if model.autoAdvance.isActive {
            switch key {
            case .return:
                model.autoAdvance.playNow()
                return true
            case .escape:
                model.autoAdvance.cancel()
                return true
            default:
                return false
            }
        }
        return false
    }

    static func perform(_ action: InputAction, model: PlayerModel, target: PlayerCommandTarget) {
        switch action {
        case .togglePause:
            model.togglePause()
            model.chrome.playbackKeyPressed()
        case .seek(let seconds):
            model.seek(by: seconds, source: .keyboard)
        case .seekAbsolute(let seconds):
            model.seek(to: .seconds(seconds), source: .keyboard)
        case .frameStep(let forward):
            model.frameStep(forward: forward)
        case .adjustVolume(let delta):
            model.adjustVolume(by: delta)
        case .toggleMute:
            model.toggleMute()
        case .toggleFullscreen:
            target.toggleFullscreen()
        case .exitFullscreen:
            target.exitFullscreen()
        case .openFile:
            target.openDocument()
        case .closeFile:
            target.closeFile()
        case .showSettings:
            target.showSettings()
        case .windowScale(let scale):
            target.scaleWindow(scale)
        case .quit:
            NSApplication.shared.terminate(nil)
        case .ignore:
            // input.conf `ignore` unbinds a key; `InputMap.action(for:)` returns nil for it, so
            // only a direct call lands here, and it does nothing on purpose.
            return
        // The M2 rows of section 10.
        case .subtitleLine(let forward):
            Task { await model.stepSubtitleLine(forward: forward) }
        case .episode(let forward):
            Task {
                if forward { await model.playNextEpisode() } else { await model.playPreviousEpisode() }
            }
        case .multiplySpeed(let factor):
            multiplySpeed(factor, model: model)
        case .setSpeed(let rate):
            model.setRate(rate, announce: true)
        case .adjustSubtitleDelay(let seconds):
            model.adjustSubtitleDelay(by: seconds)
        case .setSubtitleDelay(let seconds):
            model.setSubtitleDelay(seconds)
        case .adjustAudioDelay(let seconds):
            model.adjustAudioDelay(by: seconds)
        case .setAudioDelay(let seconds):
            model.setAudioDelay(seconds)
        case .adjustSubtitleScale(let delta):
            model.adjustSubtitleScale(delta: delta)
        case .adjustSubtitlePosition(let delta):
            model.moveSubtitle(by: delta)
        case .toggleSubtitleVisibility:
            model.toggleSubtitlesVisible()
        case .cycleTrack(let kind):
            switch kind {
            case .subtitle: model.cycleSubtitle()
            case .audio: model.cycleAudio()
            case .video: model.cycleVideo()
            }
        case .screenshot:
            target.takeScreenshot()
        case .abLoop:
            model.toggleABLoop()
        case .toggleFileLoop:
            model.toggleFileLoop()
        case .togglePictureInPicture:
            model.togglePictureInPicture()
        // The M3 rows of section 10.
        case .addSubtitleFile:
            model.addSubtitleFile()
        case .videoInfo:
            model.toggleVideoInfo()
        }
    }

    /// `multiply speed` from input.conf: the named steps use the model's own rounding so the
    /// menu, the keys and the panel agree (2, 1/2, 1.1, 1/1.1).
    private static func multiplySpeed(_ factor: Double, model: PlayerModel) {
        switch factor {
        case 2: model.doubleSpeed()
        case 0.5: model.halveSpeed()
        case 1.1: model.increaseSpeed()
        case let value where abs(value - 1 / 1.1) < 1e-9: model.decreaseSpeed()
        default: model.setRate(model.rate * factor, announce: true)
        }
    }
}
