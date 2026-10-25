import AVFoundation
import AVKit
import CoreMedia
import ReelCore
import ReelUI
import Synchronization
import VideoToolbox

/// Picture in Picture (design 9.9): `AVPictureInPictureController` with the sample buffer display
/// layer as its content source. The playback delegate maps play, pause, skip by 10 s and the time
/// range to the player. While active, the engine composites subtitles into the frames (8.6, D37)
/// and the window shows a placeholder made from the frame on screen when PiP started.
///
/// Never started by a test or by shot mode: only the controller button, the Video menu and
/// Ctrl+Cmd+P reach `start()`.
@MainActor
final class PictureInPicture: NSObject {
    /// What the delegate callbacks read; they may run off the main thread.
    struct Snapshot: Sendable {
        var duration: Double?
        var isPaused = true
    }

    private weak var model: PlayerModel?
    private let log: ReelLog
    private var controller: AVPictureInPictureController?
    private weak var layer: AVSampleBufferDisplayLayer?
    private let snapshot = Mutex(Snapshot())
    /// Tells the engine to start or stop compositing subtitles into the frames.
    var onActiveChange: ((Bool) -> Void)?

    init(model: PlayerModel, log: ReelLog) {
        self.model = model
        self.log = log
        super.init()
    }

    var isActive: Bool { controller?.isPictureInPictureActive == true }

    /// A new engine gets a new display layer, so the controller is made again for it.
    func attach(_ displayLayer: AVSampleBufferDisplayLayer) {
        if isActive { controller?.stopPictureInPicture() }
        controller?.delegate = nil
        controller = nil
        layer = displayLayer
    }

    /// Updates what the PiP window's controls show. Call on play, pause and open.
    func refresh() {
        guard let model else { return }
        let state = Snapshot(duration: model.duration?.seconds, isPaused: !model.isPlaying)
        snapshot.withLock { $0 = state }
        controller?.invalidatePlaybackState()
    }

    func toggle(_ wanted: Bool) {
        if wanted { start() } else { stop() }
    }

    func start() {
        guard let model, model.hasMedia, !isActive else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported(), let controller = makeControllerIfNeeded() else {
            model.postOSD(OSDMessage(kind: .track, text: "Picture in Picture Unavailable", symbol: "pip"))
            return
        }
        refresh()
        controller.startPictureInPicture()
    }

    func stop() {
        guard isActive else { return }
        controller?.stopPictureInPicture()
    }

    private func makeControllerIfNeeded() -> AVPictureInPictureController? {
        if let controller { return controller }
        guard let layer else { return nil }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let made = AVPictureInPictureController(contentSource: source)
        made.delegate = self
        controller = made
        return made
    }

    /// The frame on screen, for the window's blurred placeholder.
    private func displayedFrame() -> CGImage? {
        guard let buffer = layer?.sampleBufferRenderer.displayedPixelBuffer() else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        return image
    }

    func didChange(active: Bool) {
        guard let model else { return }
        model.setPictureInPicture(active: active, snapshot: active ? displayedFrame() : nil)
        onActiveChange?(active)
        log.info(active ? "Picture in Picture started" : "Picture in Picture stopped")
    }

    func failedToStart(_ error: String) {
        log.error("Picture in Picture failed to start: \(error)")
        model?.postOSD(OSDMessage(kind: .track, text: "Picture in Picture Unavailable", symbol: "pip"))
    }

    func setPlaying(_ playing: Bool) {
        guard let model else { return }
        if playing { model.play() } else { model.pause() }
        refresh()
    }

    func skip(by seconds: Double) {
        model?.seek(by: seconds, source: .pointer)
    }

    nonisolated var currentSnapshot: Snapshot { snapshot.withLock { $0 } }

    /// The range the PiP window's scrubber shows: the file, or an open range while the duration
    /// is unknown.
    nonisolated static func timeRange(duration: Double?) -> CMTimeRange {
        guard let duration, duration > 0 else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }
}

extension PictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in self.setPlaying(playing) }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        PictureInPicture.timeRange(duration: currentSnapshot.duration)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        currentSnapshot.isPaused
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) {
        let seconds = skipInterval.seconds
        Task { @MainActor in
            self.skip(by: seconds.isFinite ? seconds : 0)
            completionHandler()
        }
    }
}

extension PictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.didChange(active: true) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.didChange(active: false) }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        let message = error.localizedDescription
        Task { @MainActor in self.failedToStart(message) }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
