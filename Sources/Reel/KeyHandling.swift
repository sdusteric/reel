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

    /// Runs the bound action. Returns false when the key is unbound, so AppKit can beep or pass it on.
    @discardableResult
    static func handle(_ event: NSEvent, map: InputMap, model: PlayerModel, target: PlayerCommandTarget) -> Bool {
        guard let chord = chord(for: event), let action = map.action(for: chord) else { return false }
        perform(action, model: model, target: target)
        return true
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
            break
        }
    }
}
