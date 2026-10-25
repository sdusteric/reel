import CoreGraphics
import Foundation
import ReelCore

/// Entry points the app, shot mode and reelctl use to get an engine and grab frames.
public enum EngineFactory {
    /// Returns an engine ready to open `url`. The app passes `.playback` (audible, keeps the
    /// display awake); tools pass `.headless`.
    public static func make(url: URL, configuration: PlaybackEngine.Configuration = .playback) -> any PlayerEngine {
        makePlaybackEngine(configuration: configuration)
    }

    /// The concrete engine, for callers that attach a display layer or observe frames.
    public static func makePlaybackEngine(configuration: PlaybackEngine.Configuration = .playback) -> PlaybackEngine {
        PlaybackEngine(configuration: configuration)
    }

    /// Decodes the frame displayed at `time` into an image (used by shot mode). Runs off the
    /// calling actor because the decode blocks.
    public static func grabFrame(url: URL, at time: MediaTime) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            try FrameGrabber.grabImage(url: url, at: time)
        }.value
    }

    /// The subtitle the player shows for `url` at `time`, drawn for a `width` x `height` pixel
    /// frame (shot mode). `selection` nil takes the player's default choice, sidecar files
    /// included; `bottomInset` lifts bottom lines like `setSubtitleAvoidance` (in pixels). Nil
    /// when nothing shows.
    public static func renderSubtitle(
        url: URL,
        at time: MediaTime,
        width: Int,
        height: Int,
        selection: SubtitleSelection? = nil,
        bottomInset: Double? = nil
    ) async throws -> SubtitleBitmap? {
        let demuxer = try await Task.detached(priority: .userInitiated) { try Demuxer(url: url) }.value
        defer { demuxer.stop() }
        let external = ExternalSubtitles.scan(for: url).map(\.track)
        let tracks = TrackState(info: demuxer.info, external: external)
        guard let id = (selection ?? tracks.selectedSubtitle).trackID,
              let track = tracks.subtitles.first(where: { $0.id == id }) ?? (id == selection?.trackID ? PlaybackEngine.externalTrack(url, video: url) : nil)
        else { return nil }
        let video = demuxer.info.videoStream?.video
        let videoWidth = video?.width ?? width
        let videoHeight = video?.height ?? height
        if track.format.isBitmap, case .embedded(let index) = id {
            let decoded = try await Task.detached { try BitmapSubtitles.decodeAll(url: url, streamIndex: index) }.value
            guard let set = decoded.timeline.active(at: time) else { return nil }
            let videoRect = PixelRect.aspectFit(width: videoWidth, height: videoHeight, inWidth: width, height: height)
            let placed = set.rects.map { rect in
                (rect.image, BitmapSubtitles.place(rect.rect, canvasWidth: set.canvasWidth > 0 ? set.canvasWidth : decoded.canvasWidth,
                                                   canvasHeight: set.canvasHeight > 0 ? set.canvasHeight : decoded.canvasHeight, videoRect: videoRect))
            }
            guard var bounds = placed.first?.1 else { return nil }
            for (_, rect) in placed.dropFirst() { bounds = bounds.union(rect) }
            let lift = BitmapSubtitles.liftOffset(bounds: bounds, frameHeight: height, bottomInset: bottomInset)
            guard let image = SubtitlePresenter.compose(placed, bounds: bounds) else { return nil }
            return SubtitleBitmap(image: image, rect: bounds.offsetBy(dy: lift))
        }
        let store = SubtitleTrackStore()
        switch id {
        case .external(let file):
            try ExternalSubtitleLoader.load(file, title: track.title, into: store)
        case .embedded(let index):
            let prefetcher = SubtitlePrefetcher(url: url, store: store, streams: [index])
            prefetcher.start()
            if let error = await prefetcher.wait().error { throw EngineError.decoderFailed(error) }
        }
        let renderer = try SubtitleRenderer()
        renderer.sync(with: store, track: id)
        let settings = SubtitleRenderSettings(
            frameWidth: width, frameHeight: height, videoWidth: videoWidth, videoHeight: videoHeight, bottomInset: bottomInset
        )
        return renderer.render(at: time, settings: settings).bitmap
    }
}
