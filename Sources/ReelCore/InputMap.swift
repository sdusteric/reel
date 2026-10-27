import Foundation

/// A command a key can trigger.
public enum InputAction: Sendable, Hashable {
    case togglePause
    /// Relative seek in seconds; always an exact seek.
    case seek(seconds: Double)
    case seekAbsolute(seconds: Double)
    case frameStep(forward: Bool)
    /// Volume change in mpv units (0 to 100 scale).
    case adjustVolume(delta: Double)
    case toggleMute
    case toggleFullscreen
    case exitFullscreen
    case openFile
    case closeFile
    case showSettings
    case windowScale(WindowScale)
    case quit
    // M2 (design section 10).
    /// `sub-seek 1` / `sub-seek -1`: exact seek to the start of the next or previous line.
    case subtitleLine(forward: Bool)
    /// `playlist-next` / `playlist-prev`: next or previous episode in the folder.
    case episode(forward: Bool)
    /// `multiply speed 2.0`, `multiply speed 1/1.1`.
    case multiplySpeed(factor: Double)
    /// `set speed 1.0`.
    case setSpeed(Double)
    /// `add sub-delay 0.5` in seconds.
    case adjustSubtitleDelay(seconds: Double)
    /// `set sub-delay 0`.
    case setSubtitleDelay(seconds: Double)
    /// `add audio-delay 0.5` in seconds.
    case adjustAudioDelay(seconds: Double)
    /// `set audio-delay 0`.
    case setAudioDelay(seconds: Double)
    /// `add sub-scale 0.1`: one size step per 0.1 (`SubtitleStyle.steps(forScaleDelta:)`).
    case adjustSubtitleScale(delta: Double)
    /// `add sub-pos -1`: negative moves up, in percent of the video height.
    case adjustSubtitlePosition(delta: Double)
    /// `cycle sub-visibility`.
    case toggleSubtitleVisibility
    /// `cycle sub`, `cycle audio`, `cycle video`.
    case cycleTrack(TrackKind)
    /// `screenshot`.
    case screenshot
    /// `ab-loop`: set A, set B, clear.
    case abLoop
    /// `cycle-values loop "inf" "no"`.
    case toggleFileLoop
    /// `toggle-pip` (IINA's command name; Reel binds it to Ctrl+Cmd+P and opens its mini player).
    case toggleMiniPlayer
    // M3 (design section 10).
    /// Video Info (Cmd+I, IINA's Inspector key): `script-message reel-video-info`, or
    /// `script-binding video-info`.
    case videoInfo
    /// Add Subtitle File (Shift+Cmd+O): `script-message reel-add-subtitle-file`.
    case addSubtitleFile
    /// Unbinds the key (`ignore` in input.conf).
    case ignore
}

/// The kinds of track that `cycle` steps through.
public enum TrackKind: String, Sendable, Hashable, Codable {
    case video, audio, subtitle
}

public enum WindowScale: Sendable, Hashable {
    case factor(Double)
    case fitScreen
}

public enum NamedKey: String, Sendable, Hashable, CaseIterable {
    case space, `return`, escape, tab, backspace, delete
    case left, right, up, down, pageUp, pageDown, home, end
    case playPause, mediaNext, mediaPrevious, mediaStop, mediaForward, mediaRewind
    /// Mouse side buttons (`MBTN_BACK`, `MBTN_FORWARD`).
    case mouseBack, mouseForward
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
}

public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    /// The Command key (`Meta` in input.conf).
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

/// A key plus modifiers. Letters are stored lowercase; an uppercase letter means Shift.
public struct KeyChord: Sendable, Hashable, CustomStringConvertible {
    public enum Key: Sendable, Hashable {
        case character(Character)
        case named(NamedKey)
    }

    public var key: Key
    public var modifiers: KeyModifiers

    public init(key: Key, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public init(_ named: NamedKey, _ modifiers: KeyModifiers = []) {
        self.init(key: .named(named), modifiers: modifiers)
    }

    /// Normalizes case: `"F"` becomes `f` with Shift, and Shift is dropped from symbols (`(`).
    /// Pass the character the key produces without modifiers (`charactersIgnoringModifiers`).
    public init(character: Character, modifiers: KeyModifiers = []) {
        var mods = modifiers
        var normalized = character
        if character.isLetter, character.isUppercase {
            mods.insert(.shift)
            normalized = Character(character.lowercased())
        } else if !character.isLetter {
            // As in mpv, Shift is part of a printable symbol: `Shift+(` is the key "(".
            mods.remove(.shift)
        }
        self.init(key: .character(normalized), modifiers: mods)
    }

    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Meta") }
        switch key {
        case .character(let character): parts.append(String(character))
        case .named(let named): parts.append(named.rawValue)
        }
        return parts.joined(separator: "+")
    }
}

/// One problem found while parsing an input.conf. Parsing never throws: a bad line is skipped.
public struct InputConfDiagnostic: Sendable, Hashable {
    public var line: Int
    public var text: String
    public var message: String
}

/// The key binding table (design section 10), parsed from IINA's input.conf syntax.
public struct InputMap: Sendable, Hashable {
    public private(set) var bindings: [KeyChord: InputAction]
    public private(set) var diagnostics: [InputConfDiagnostic]

    public init(bindings: [KeyChord: InputAction] = [:], diagnostics: [InputConfDiagnostic] = []) {
        self.bindings = bindings
        self.diagnostics = diagnostics
    }

    /// Parses `text`. A later line for the same key replaces an earlier one; `ignore` unbinds.
    public init(parsing text: String) {
        self.init()
        merge(parsing: text)
    }

    /// The default table from `DefaultInputConf`.
    public static let standard = InputMap(parsing: DefaultInputConf.text)

    /// The action bound to `chord`. Unbound and `ignore`d keys return nil.
    public func action(for chord: KeyChord) -> InputAction? {
        guard let action = bindings[chord], action != .ignore else { return nil }
        return action
    }

    /// The binding to show next to a menu item: the first in a stable order.
    public func chord(for action: InputAction) -> KeyChord? {
        bindings.filter { $0.value == action }.keys.min { $0.description < $1.description }
    }

    /// Applies a user file on top of the current table.
    public mutating func merge(parsing text: String) {
        var lineNumber = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 2 else {
                diagnostics.append(.init(line: lineNumber, text: line, message: "expected a key and a command"))
                continue
            }
            guard let chord = InputMap.parseChord(tokens[0]) else {
                diagnostics.append(.init(line: lineNumber, text: line, message: "unknown key \(tokens[0])"))
                continue
            }
            switch InputMap.parseCommand(Array(tokens.dropFirst())) {
            case .success(let action):
                bindings[chord] = action
            case .failure(let reason):
                diagnostics.append(.init(line: lineNumber, text: line, message: reason.message))
            }
        }
    }

    // MARK: Keys

    private static let keyNames: [String: NamedKey] = [
        "space": .space, "enter": .return, "return": .return, "kp_enter": .return,
        "esc": .escape, "escape": .escape, "tab": .tab,
        "bs": .backspace, "backspace": .backspace, "del": .delete, "delete": .delete,
        "left": .left, "right": .right, "up": .up, "down": .down,
        "pgup": .pageUp, "pageup": .pageUp, "pgdwn": .pageDown, "pgdown": .pageDown, "pagedown": .pageDown,
        "home": .home, "end": .end,
        "playpause": .playPause, "play": .playPause, "pause": .playPause, "media_play_pause": .playPause,
        "next": .mediaNext, "media_next": .mediaNext, "prev": .mediaPrevious, "media_prev": .mediaPrevious,
        "stop": .mediaStop, "medianext": .mediaNext, "mediaprevious": .mediaPrevious, "mediastop": .mediaStop,
        "forward": .mediaForward, "rewind": .mediaRewind,
        "mbtn_back": .mouseBack, "mbtn_forward": .mouseForward, "xbutton1": .mouseBack, "xbutton2": .mouseForward,
        "f1": .f1, "f2": .f2, "f3": .f3, "f4": .f4, "f5": .f5, "f6": .f6,
        "f7": .f7, "f8": .f8, "f9": .f9, "f10": .f10, "f11": .f11, "f12": .f12,
    ]

    private static let modifierNames: [String: KeyModifiers] = [
        "shift": .shift, "ctrl": .control, "control": .control,
        "alt": .option, "option": .option, "opt": .option,
        "meta": .command, "cmd": .command, "command": .command,
    ]

    /// Parses `Ctrl+Meta+f`, `Shift+PGUP`, `Meta+/`, `SPACE`, `+` or `Shift++`.
    public static func parseChord(_ text: String) -> KeyChord? {
        var keyText = text
        var modifierText: [Substring] = []
        if text == "+" {
            keyText = "+"
        } else if text.hasSuffix("++") {
            keyText = "+"
            modifierText = text.dropLast(2).split(separator: "+", omittingEmptySubsequences: false)
        } else {
            var parts = text.split(separator: "+", omittingEmptySubsequences: false)
            guard let last = parts.popLast(), !last.isEmpty else { return nil }
            keyText = String(last)
            modifierText = parts
        }
        var modifiers: KeyModifiers = []
        for name in modifierText {
            guard let modifier = modifierNames[name.lowercased()] else { return nil }
            modifiers.insert(modifier)
        }
        if let named = keyNames[keyText.lowercased()] {
            return KeyChord(named, modifiers)
        }
        if keyText.lowercased() == "sharp" { return KeyChord(character: "#", modifiers: modifiers) }
        guard keyText.count == 1, let character = keyText.first else { return nil }
        return KeyChord(character: character, modifiers: modifiers)
    }

    // MARK: Commands

    private enum CommandFailure: Error {
        case unknown(String)
        case badArguments(String)

        var message: String {
            switch self {
            case .unknown(let command): "unsupported command \(command)"
            case .badArguments(let command): "bad arguments for \(command)"
            }
        }
    }

    private static func parseCommand(_ tokens: [String]) -> Result<InputAction, CommandFailure> {
        guard let name = tokens.first else { return .failure(.unknown("")) }
        let args = Array(tokens.dropFirst())
        let whole = tokens.joined(separator: " ")
        switch name {
        case "ignore":
            return .success(.ignore)
        case "cycle":
            switch args.first {
            case "pause": return .success(.togglePause)
            case "mute": return .success(.toggleMute)
            case "fullscreen": return .success(.toggleFullscreen)
            case "sub-visibility": return .success(.toggleSubtitleVisibility)
            case "sub", "sid": return .success(.cycleTrack(.subtitle))
            case "audio", "aid": return .success(.cycleTrack(.audio))
            case "video", "vid": return .success(.cycleTrack(.video))
            default: return .failure(.unknown("cycle \(args.first ?? "")"))
            }
        case "cycle-values":
            if let property = args.first, property == "loop" || property == "loop-file" {
                return .success(.toggleFileLoop)
            }
            return .failure(.unknown(whole))
        case "set":
            guard args.count == 2 else { return .failure(.unknown(whole)) }
            switch args[0] {
            case "fullscreen" where args[1] == "no":
                return .success(.exitFullscreen)
            case "speed":
                guard let value = number(args[1]), value > 0 else { return .failure(.badArguments("set speed")) }
                return .success(.setSpeed(value))
            case "sub-delay":
                guard let value = number(args[1]) else { return .failure(.badArguments("set sub-delay")) }
                return .success(.setSubtitleDelay(seconds: value))
            case "audio-delay":
                guard let value = number(args[1]) else { return .failure(.badArguments("set audio-delay")) }
                return .success(.setAudioDelay(seconds: value))
            default:
                return .failure(.unknown(whole))
            }
        case "seek":
            guard let first = args.first, let seconds = Double(first), seconds.isFinite else {
                return .failure(.badArguments("seek"))
            }
            let absolute = args.dropFirst().contains("absolute")
            return .success(absolute ? .seekAbsolute(seconds: seconds) : .seek(seconds: seconds))
        case "frame-step":
            return .success(.frameStep(forward: true))
        case "frame-back-step":
            return .success(.frameStep(forward: false))
        case "add":
            guard args.count == 2, let delta = number(args[1]) else { return .failure(.unknown(whole)) }
            switch args[0] {
            case "volume": return .success(.adjustVolume(delta: delta))
            case "sub-delay": return .success(.adjustSubtitleDelay(seconds: delta))
            case "audio-delay": return .success(.adjustAudioDelay(seconds: delta))
            case "sub-scale": return .success(.adjustSubtitleScale(delta: delta))
            case "sub-pos": return .success(.adjustSubtitlePosition(delta: delta))
            default: return .failure(.unknown(whole))
            }
        case "multiply":
            guard args.count == 2, args[0] == "speed", let factor = number(args[1]), factor > 0 else {
                return .failure(.unknown(whole))
            }
            return .success(.multiplySpeed(factor: factor))
        case "sub-seek":
            guard let first = args.first, let lines = Int(first), lines != 0 else { return .failure(.badArguments("sub-seek")) }
            return .success(.subtitleLine(forward: lines > 0))
        case "playlist-next":
            return .success(.episode(forward: true))
        case "playlist-prev":
            return .success(.episode(forward: false))
        case "screenshot":
            return .success(.screenshot)
        case "ab-loop":
            return .success(.abLoop)
        case "toggle-pip":
            return .success(.toggleMiniPlayer)
        case "quit", "quit-watch-later":
            return .success(.quit)
        case "script-message":
            return parseScriptMessage(args)
        case "script-binding":
            return args.first == "video-info" ? .success(.videoInfo) : .failure(.unknown("script-binding \(args.first ?? "")"))
        default:
            return .failure(.unknown(name))
        }
    }

    /// A finite number: `0.5`, `+0.1`, `-1`, or a fraction such as `1/1.1`.
    static func number(_ text: String) -> Double? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            guard let value = Double(text), value.isFinite else { return nil }
            return value
        case 2:
            guard let top = Double(parts[0]), let bottom = Double(parts[1]), bottom != 0 else { return nil }
            let value = top / bottom
            return value.isFinite ? value : nil
        default:
            return nil
        }
    }

    private static func parseScriptMessage(_ args: [String]) -> Result<InputAction, CommandFailure> {
        switch args.first {
        case "reel-open": return .success(.openFile)
        case "reel-close": return .success(.closeFile)
        case "reel-settings": return .success(.showSettings)
        case "reel-video-info": return .success(.videoInfo)
        case "reel-add-subtitle-file": return .success(.addSubtitleFile)
        case "reel-window-scale":
            guard args.count == 2 else { return .failure(.badArguments("reel-window-scale")) }
            if args[1] == "fit" { return .success(.windowScale(.fitScreen)) }
            guard let factor = Double(args[1]), factor > 0, factor.isFinite else {
                return .failure(.badArguments("reel-window-scale"))
            }
            return .success(.windowScale(.factor(factor)))
        default:
            return .failure(.unknown("script-message \(args.first ?? "")"))
        }
    }
}
