import Foundation
import ReelCore
import Synchronization

/// Every known text event per subtitle track, time-ordered, shared by the prefetcher, the main
/// demuxer's decoder and the renderer (design section 8.1). Duplicates (the same event read by
/// both passes) are stored once.
public final class SubtitleTrackStore: Sendable {
    /// One stored event with a store-wide id; ids only grow, so a renderer adds `id > last seen`.
    public struct StoredEvent: Sendable, Hashable {
        public var id: Int
        public var event: SubtitleTextEvent
    }

    /// A copy of one track's state.
    public struct Track: Sendable {
        public var header: String
        public var format: SubtitleFormat
        public var charset: SubtitleCharset
        public var charsetRecognised: Bool
        /// The family Reel's default style uses for this track (PingFang SC, TC or HK).
        public var fontFamily: String = SubtitleStyle.fontName
        /// Changes when the events were replaced (a charset change); renderers rebuild their track.
        public var epoch: Int
        /// Sorted by start, then id.
        public var events: [StoredEvent]
        /// Set when a pass read the whole file (the prefetcher finished, or an external file loaded).
        public var isComplete: Bool

        public var eventTimes: [SubtitleEventTime] { events.map(\.event.time) }

        public func events(at time: MediaTime) -> [SubtitleTextEvent] {
            events.map(\.event).filter { $0.isActive(at: time) }
        }

        /// Events with an id above `id`, in id order.
        public func events(after id: Int) -> [StoredEvent] {
            events.filter { $0.id > id }.sorted { $0.id < $1.id }
        }
    }

    private struct EventKey: Hashable {
        var start: Int64
        var end: Int64
        var fields: String

        init(_ event: SubtitleTextEvent) {
            start = event.start.microseconds
            end = event.end.microseconds
            fields = event.fields
        }
    }

    private struct TrackState {
        var track: Track
        var keys: Set<EventKey> = []
    }

    private struct State {
        var tracks: [TrackID: TrackState] = [:]
        var nextID = 1
        var nextEpoch = 1
    }

    private let state = Mutex(State())

    public init() {}

    /// Registers a track, or updates its header and format if known. Keeps existing events.
    public func begin(
        _ id: TrackID,
        header: String,
        format: SubtitleFormat,
        charset: SubtitleCharset = .utf8,
        recognised: Bool = true,
        fontFamily: String = SubtitleStyle.fontName
    ) {
        state.withLock { state in
            if var existing = state.tracks[id] {
                if existing.track.header.isEmpty { existing.track.header = header }
                state.tracks[id] = existing
                return
            }
            let track = Track(
                header: header,
                format: format,
                charset: charset,
                charsetRecognised: recognised,
                fontFamily: fontFamily,
                epoch: state.nextEpoch,
                events: [],
                isComplete: false
            )
            state.nextEpoch += 1
            state.tracks[id] = TrackState(track: track)
        }
    }

    /// Adds events; ones already stored are ignored. Returns how many were new.
    @discardableResult
    public func add(_ events: [SubtitleTextEvent], to id: TrackID) -> Int {
        guard !events.isEmpty else { return 0 }
        return state.withLock { state in
            guard var entry = state.tracks[id] else { return 0 }
            var added = 0
            for event in events {
                let key = EventKey(event)
                guard entry.keys.insert(key).inserted else { continue }
                let stored = StoredEvent(id: state.nextID, event: event)
                state.nextID += 1
                let position = SubtitleTrackStore.insertionIndex(for: stored, in: entry.track.events)
                entry.track.events.insert(stored, at: position)
                added += 1
            }
            state.tracks[id] = entry
            return added
        }
    }

    /// Drops every event of the track and records the charset it is now decoded with (a decoder
    /// found invalid text and fell back, section 8.3). The epoch changes.
    public func reset(_ id: TrackID, charset: SubtitleCharset, recognised: Bool, header: String? = nil) {
        state.withLock { state in
            guard var entry = state.tracks[id] else { return }
            entry.keys = []
            entry.track.events = []
            entry.track.charset = charset
            entry.track.charsetRecognised = recognised
            if let header { entry.track.header = header }
            entry.track.epoch = state.nextEpoch
            state.nextEpoch += 1
            state.tracks[id] = entry
        }
    }

    public func markComplete(_ id: TrackID) {
        state.withLock { state in
            state.tracks[id]?.track.isComplete = true
        }
    }

    public func remove(_ id: TrackID) {
        _ = state.withLock { state in state.tracks.removeValue(forKey: id) }
    }

    public func track(_ id: TrackID) -> Track? {
        state.withLock { $0.tracks[id]?.track }
    }

    public var trackIDs: [TrackID] {
        state.withLock { Array($0.tracks.keys) }
    }

    public func charset(of id: TrackID) -> SubtitleCharset? {
        state.withLock { $0.tracks[id]?.track.charset }
    }

    public func eventTimes(_ id: TrackID) -> [SubtitleEventTime] {
        track(id)?.eventTimes ?? []
    }

    public func events(_ id: TrackID, at time: MediaTime) -> [SubtitleTextEvent] {
        track(id)?.events(at: time) ?? []
    }

    /// Start of the next event after `time` (Shift+Right).
    public func nextEventStart(_ id: TrackID, after time: MediaTime) -> MediaTime? {
        SubtitleLines.next(after: time, in: eventTimes(id))
    }

    /// Start of the previous event (Shift+Left), like `ass_step_sub(-1)`.
    public func previousEventStart(_ id: TrackID, before time: MediaTime) -> MediaTime? {
        SubtitleLines.previous(before: time, in: eventTimes(id))
    }

    private static func insertionIndex(for stored: StoredEvent, in events: [StoredEvent]) -> Int {
        var low = 0
        var high = events.count
        while low < high {
            let middle = (low + high) / 2
            let other = events[middle]
            if (other.event.start, other.id) < (stored.event.start, stored.id) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
