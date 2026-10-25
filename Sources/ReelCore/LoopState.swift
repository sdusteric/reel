import Foundation

/// A-B loop and file loop (design section 9.12, D49).
public struct LoopState: Sendable, Hashable, Codable {
    public enum Phase: Sendable, Hashable {
        case none
        /// A is set; the next Cmd+L sets B.
        case startSet
        /// A and B are set; the next Cmd+L clears.
        case active
    }

    public var start: MediaTime?
    public var end: MediaTime?
    /// Shift+Cmd+L: restart at the end instead of ending.
    public var fileLoop: Bool

    public init(start: MediaTime? = nil, end: MediaTime? = nil, fileLoop: Bool = false) {
        self.start = start
        self.end = end
        self.fileLoop = fileLoop
    }

    public static let off = LoopState()

    public var phase: Phase {
        switch (start, end) {
        case (nil, _): .none
        case (_?, nil): .startSet
        case (_?, _?): .active
        }
    }

    /// The A-B range while both points are set.
    public var range: ClosedRange<MediaTime>? {
        guard let start, let end else { return nil }
        return start...end
    }

    /// Cmd+L: set A, then set B, then clear. A B before A swaps the two; a B equal to A is ignored.
    public mutating func toggleABLoop(at time: MediaTime) {
        switch phase {
        case .none:
            start = time
            end = nil
        case .startSet:
            guard let a = start, time != a else { return }
            start = min(a, time)
            end = max(a, time)
        case .active:
            start = nil
            end = nil
        }
    }

    public mutating func clearABLoop() {
        start = nil
        end = nil
    }

    /// Shift+Cmd+L.
    public mutating func toggleFileLoop() {
        fileLoop.toggle()
    }

    /// Auto-advance runs only with no loop of either kind (an A point alone counts).
    public var allowsAutoAdvance: Bool { !fileLoop && start == nil && end == nil }

    /// Where to jump when playback reaches `time`: A once B is reached.
    public func loopTarget(at time: MediaTime) -> MediaTime? {
        guard let range, time >= range.upperBound else { return nil }
        return range.lowerBound
    }

    /// Where to go at the end of the file: 0 with file loop on, else nil (end normally).
    public var endOfFileTarget: MediaTime? { fileLoop ? .zero : nil }

    /// The Playback menu item for Cmd+L.
    public var menuTitle: String {
        switch phase {
        case .none: "Set Loop Start"
        case .startSet: "Set Loop End"
        case .active: "Clear Loop"
        }
    }

    /// OSD text after Cmd+L: "Loop from 31:04", "Loop 31:04 to 32:10", "Loop Off".
    public func abOSDText(duration: MediaTime?) -> String {
        let format = { (time: MediaTime) in TimeFormat.clock(time, duration: duration) }
        switch (start, end) {
        case (nil, _): return "Loop Off"
        case (let a?, nil): return "Loop from \(format(a))"
        case (let a?, let b?): return "Loop \(format(a)) to \(format(b))"
        }
    }

    /// OSD text after Shift+Cmd+L.
    public var fileLoopOSDText: String { fileLoop ? "Loop File On" : "Loop File Off" }
}
