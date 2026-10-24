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
    /// Unbinds the key (`ignore` in input.conf).
    case ignore
}

public enum WindowScale: Sendable, Hashable {
    case factor(Double)
    case fitScreen
}

public enum NamedKey: String, Sendable, Hashable, CaseIterable {
    case space, `return`, escape, tab, backspace, delete
    case left, right, up, down, pageUp, pageDown, home, end
    case playPause, mediaNext, mediaPrevious, mediaStop
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

    /// Normalizes case: `"F"` becomes `f` with Shift. Pass the character the key produces
    /// without modifiers (`charactersIgnoringModifiers`).
    public init(character: Character, modifiers: KeyModifiers = []) {
        var mods = modifiers
        var normalized = character
        if character.isLetter, character.isUppercase {
            mods.insert(.shift)
            normalized = Character(character.lowercased())
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

    /// The M1 table from `DefaultInputConf`.
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
        switch name {
        case "ignore":
            return .success(.ignore)
        case "cycle":
            switch args.first {
            case "pause": return .success(.togglePause)
            case "mute": return .success(.toggleMute)
            case "fullscreen": return .success(.toggleFullscreen)
            default: return .failure(.unknown("cycle \(args.first ?? "")"))
            }
        case "set":
            if args.count == 2, args[0] == "fullscreen", args[1] == "no" { return .success(.exitFullscreen) }
            return .failure(.unknown(tokens.joined(separator: " ")))
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
            guard args.count == 2, args[0] == "volume", let delta = Double(args[1]), delta.isFinite else {
                return .failure(.unknown(tokens.joined(separator: " ")))
            }
            return .success(.adjustVolume(delta: delta))
        case "quit", "quit-watch-later":
            return .success(.quit)
        case "script-message":
            return parseScriptMessage(args)
        default:
            return .failure(.unknown(name))
        }
    }

    private static func parseScriptMessage(_ args: [String]) -> Result<InputAction, CommandFailure> {
        switch args.first {
        case "reel-open": return .success(.openFile)
        case "reel-close": return .success(.closeFile)
        case "reel-settings": return .success(.showSettings)
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
