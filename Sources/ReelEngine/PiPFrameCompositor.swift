import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ReelCore

/// Subtitles for Picture in Picture (design section 8.6, D37). The PiP window shows only the
/// display layer, so while PiP is active and a subtitle is visible each frame is copied into a
/// pooled pixel buffer with the subtitle drawn over it (Core Image source-over on the GPU) before
/// it is enqueued. Frames without a subtitle pass through untouched.
///
/// If 4K frames take longer than `budgetMilliseconds` to composite for `slowFrameLimit` frames in
/// a row, compositing is switched off for 4K for the rest of the session and logged: 4K PiP then
/// runs without subtitles rather than dropping frames.
///
/// Unchecked Sendable: `CIContext` is documented as thread-safe; the pool and counters are only
/// touched while `lock` is held.
public final class PiPFrameCompositor: @unchecked Sendable {
    public static let budgetMilliseconds = 12.0
    public static let slowFrameLimit = 10

    public struct Statistics: Sendable, Hashable {
        public var composited = 0
        public var passedThrough = 0
        public var slowFrames = 0
        public var disabledFor4K = false
        public var lastMilliseconds: Double?
    }

    private struct PoolKey: Hashable {
        var width: Int
        var height: Int
        var format: OSType
    }

    private struct State {
        var pool: CVPixelBufferPool?
        var key: PoolKey?
        var statistics = Statistics()
    }

    private let context: CIContext
    private let lock = NSLock()
    private var stateStorage = State()

    private func withState<Result>(_ body: (inout State) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&stateStorage)
    }

    public init() {
        // No colour management: the frame converts YCbCr to RGB and back with its own matrix,
        // so pixels without a subtitle come out as they went in.
        context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    }

    public var statistics: Statistics { withState { $0.statistics } }

    /// Tests: marks 4K as too slow, as a run of slow frames would.
    func disableFor4KForTesting() {
        withState { $0.statistics.disabledFor4K = true }
    }

    static func is4K(width: Int, height: Int) -> Bool { width * height >= 3840 * 2000 }

    /// `subtitle` was rendered for a frame of `renderedWidth` x `renderedHeight` pixels (top-left
    /// origin); it is scaled to the decoded frame.
    public func composite(_ frame: DecodedFrame, subtitle: SubtitleBitmap, renderedWidth: Int, renderedHeight: Int) -> DecodedFrame {
        let width = frame.width
        let height = frame.height
        let large = PiPFrameCompositor.is4K(width: width, height: height)
        guard width > 0, height > 0, renderedWidth > 0, renderedHeight > 0, !subtitle.rect.isEmpty else { return passThrough(frame) }
        if large, withState({ $0.statistics.disabledFor4K }) { return passThrough(frame) }
        let started = ContinuousClock.now
        let format = frame.pixelFormat
        guard let pool = pool(width: width, height: height, format: format) else { return passThrough(frame) }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made) == kCVReturnSuccess, let copy = made else {
            return passThrough(frame)
        }
        let scaleX = CGFloat(width) / CGFloat(renderedWidth)
        let scaleY = CGFloat(height) / CGFloat(renderedHeight)
        let rect = subtitle.rect
        // Core Image has a bottom-left origin.
        let placement = CGAffineTransform(scaleX: CGFloat(rect.width) * scaleX / CGFloat(subtitle.image.width), y: CGFloat(rect.height) * scaleY / CGFloat(subtitle.image.height))
            .concatenating(CGAffineTransform(translationX: CGFloat(rect.x) * scaleX, y: CGFloat(height) - CGFloat(rect.maxY) * scaleY))
        let overlay = CIImage(cgImage: subtitle.image, options: [.colorSpace: NSNull()]).transformed(by: placement)
        // Only the subtitle's region is rendered (on whole chroma pairs); the rest of the copy is
        // the frame's own bytes, so pixels without a subtitle stay exactly as decoded.
        let region = PiPFrameCompositor.evenRegion(overlay.extent, width: width, height: height)
        let rendered = frame.pixelBuffer.withUnsafeBuffer { source -> Bool in
            guard !region.isEmpty, PiPFrameCompositor.copyPlanes(from: source, to: copy) else { return false }
            CVBufferPropagateAttachments(source, copy)
            let base = CIImage(cvPixelBuffer: source, options: [.colorSpace: NSNull()])
            let destination = CIRenderDestination(pixelBuffer: copy)
            destination.colorSpace = nil
            do {
                let task = try context.startTask(toRender: overlay.composited(over: base), from: region, to: destination, at: region.origin)
                _ = try task.waitUntilCompleted()
                return true
            } catch {
                return false
            }
        }
        guard rendered else { return passThrough(frame) }
        let elapsed = ContinuousClock.now - started
        let milliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        withState { state in
            state.statistics.composited += 1
            state.statistics.lastMilliseconds = milliseconds
            guard large else { return }
            if milliseconds > PiPFrameCompositor.budgetMilliseconds {
                state.statistics.slowFrames += 1
                if state.statistics.slowFrames >= PiPFrameCompositor.slowFrameLimit, !state.statistics.disabledFor4K {
                    state.statistics.disabledFor4K = true
                    trace("PiP subtitles off for 4K: \(milliseconds) ms per frame is over \(PiPFrameCompositor.budgetMilliseconds) ms")
                    FileHandle.standardError.write(Data("reel: Picture in Picture shows 4K without subtitles (compositing too slow)\n".utf8))
                }
            } else {
                state.statistics.slowFrames = 0
            }
        }
        return DecodedFrame(
            pixelBuffer: CVReadOnlyPixelBuffer(fresh: copy),
            presentationTime: frame.presentationTime,
            duration: frame.duration,
            generation: frame.generation,
            decoder: frame.decoder
        )
    }

    /// `rect` grown to even pixel edges and clipped to the frame.
    static func evenRegion(_ rect: CGRect, width: Int, height: Int) -> CGRect {
        let minX = max(0, (Int(rect.minX.rounded(.down)) / 2) * 2)
        let minY = max(0, (Int(rect.minY.rounded(.down)) / 2) * 2)
        let maxX = min(width, ((Int(rect.maxX.rounded(.up)) + 1) / 2) * 2)
        let maxY = min(height, ((Int(rect.maxY.rounded(.up)) + 1) / 2) * 2)
        guard maxX > minX, maxY > minY else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Copies every plane row by row (the two buffers may pad rows differently).
    static func copyPlanes(from source: CVPixelBuffer, to destination: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        let planes = max(CVPixelBufferGetPlaneCount(source), 1)
        guard planes == max(CVPixelBufferGetPlaneCount(destination), 1) else { return false }
        for plane in 0..<planes {
            let planar = CVPixelBufferIsPlanar(source)
            guard let from = planar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source),
                  let to = planar ? CVPixelBufferGetBaseAddressOfPlane(destination, plane) : CVPixelBufferGetBaseAddress(destination) else { return false }
            let rows = planar ? CVPixelBufferGetHeightOfPlane(source, plane) : CVPixelBufferGetHeight(source)
            let fromStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
            let toStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(destination, plane) : CVPixelBufferGetBytesPerRow(destination)
            let length = min(fromStride, toStride)
            if fromStride == toStride {
                to.copyMemory(from: from, byteCount: fromStride * rows)
            } else {
                for row in 0..<rows {
                    (to + row * toStride).copyMemory(from: from + row * fromStride, byteCount: length)
                }
            }
        }
        return true
    }

    private func passThrough(_ frame: DecodedFrame) -> DecodedFrame {
        withState { $0.statistics.passedThrough += 1 }
        return frame
    }

    private func pool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        let key = PoolKey(width: width, height: height, format: format)
        if let pool = withState({ $0.key == key ? $0.pool : nil }) { return pool }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attributes as CFDictionary, &created) == kCVReturnSuccess,
              let created else { return nil }
        withState { state in
            state.pool = created
            state.key = key
        }
        return created
    }
}
