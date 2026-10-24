import Foundation

/// Keyframes of the video stream, sorted by presentation time (design section 7.2).
///
/// Built at open from the container index (mkv Cues, mp4 stss) and extended with every key
/// packet the demuxer reads. Lookups use presentation pts, not dts: with B-frame reordering a
/// dts lookup can pick the previous GOP for a target just after a keyframe.
public struct KeyframeIndex: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// Instantaneous decoder refresh (H.264 IDR, HEVC IDR, AV1 key frame, VP9 key frame).
        case idr
        /// HEVC clean random access: open GOP, its leading RASL pictures reference the previous GOP.
        case cra
        /// A key packet whose type was not inspected (container flag only).
        case other

        /// Higher is more specific; used when two sources report the same keyframe.
        fileprivate var specificity: Int {
            switch self {
            case .other: 0
            case .cra, .idr: 1
            }
        }
    }

    public struct Entry: Sendable, Hashable, Codable {
        public var pts: MediaTime
        /// Decode timestamp, when known. mkv Cues only carry pts.
        public var dts: MediaTime?
        /// Byte offset of the packet in the file, when known.
        public var pos: Int64?
        public var kind: Kind

        public init(pts: MediaTime, dts: MediaTime? = nil, pos: Int64? = nil, kind: Kind = .other) {
            self.pts = pts
            self.dts = dts
            self.pos = pos
            self.kind = kind
        }
    }

    public private(set) var entries: [Entry]

    public init() {
        entries = []
    }

    public init(_ entries: some Sequence<Entry>) {
        self.entries = []
        for entry in entries {
            insert(entry)
        }
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var first: Entry? { entries.first }
    public var last: Entry? { entries.last }

    /// Adds a keyframe. An entry with the same pts is merged: known dts and pos fill gaps,
    /// and a specific kind (IDR, CRA) replaces `.other`.
    /// Returns true when the index gained a new keyframe.
    @discardableResult
    public mutating func insert(_ entry: Entry) -> Bool {
        // Fast path: the demuxer appends in order while reading forward.
        if let lastEntry = entries.last, lastEntry.pts < entry.pts {
            entries.append(entry)
            return true
        }
        let index = firstIndex(withPTSAtLeast: entry.pts)
        if index < entries.count, entries[index].pts == entry.pts {
            var merged = entries[index]
            if merged.dts == nil { merged.dts = entry.dts }
            if merged.pos == nil { merged.pos = entry.pos }
            if entry.kind.specificity > merged.kind.specificity { merged.kind = entry.kind }
            entries[index] = merged
            return false
        }
        entries.insert(entry, at: index)
        return true
    }

    /// The last keyframe with pts at or before `time`: where an exact seek to `time` starts.
    public func entry(atOrBefore time: MediaTime) -> Entry? {
        let index = firstIndex(withPTSAtLeast: time)
        if index < entries.count, entries[index].pts == time { return entries[index] }
        return index > 0 ? entries[index - 1] : nil
    }

    /// The first keyframe with pts strictly after `time`: the end of the GOP containing `time`.
    public func next(after time: MediaTime) -> Entry? {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].pts <= time { low = mid + 1 } else { high = mid }
        }
        return low < entries.count ? entries[low] : nil
    }

    /// The last keyframe with pts strictly before `time`.
    public func previous(before time: MediaTime) -> Entry? {
        let index = firstIndex(withPTSAtLeast: time)
        return index > 0 ? entries[index - 1] : nil
    }

    /// Keyframes whose pts lies in `range`.
    public func entries(in range: ClosedRange<MediaTime>) -> ArraySlice<Entry> {
        let lower = firstIndex(withPTSAtLeast: range.lowerBound)
        var upper = lower
        while upper < entries.count, entries[upper].pts <= range.upperBound { upper += 1 }
        return entries[lower..<upper]
    }

    private func firstIndex(withPTSAtLeast time: MediaTime) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].pts < time { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
