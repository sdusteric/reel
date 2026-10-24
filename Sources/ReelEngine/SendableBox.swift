import CoreMedia
import CoreVideo

/// Carries a freshly created buffer into an `unsafeBuffer:` initializer that takes it as `sending`
/// (`CMReadySampleBuffer(unsafeBuffer:)`, `CVReadOnlyPixelBuffer(unsafeBuffer:)`).
///
/// Swift 6 cannot prove that a CMSampleBuffer or CVPixelBuffer handed over by VideoToolbox or a
/// pool is unshared, so it refuses the `sending` argument. Every use passes a buffer that nothing
/// else holds a writable reference to; use this box only at that boundary.
struct FreshBuffer<Buffer>: @unchecked Sendable {
    nonisolated(unsafe) let value: Buffer

    init(_ value: Buffer) {
        self.value = value
    }
}

extension CMReadySampleBuffer where Content == CMSampleBuffer.DynamicContent {
    /// Wraps a sample buffer that was just created and is referenced nowhere else.
    init(fresh buffer: CMSampleBuffer) {
        self.init(unsafeBuffer: FreshBuffer(buffer).value)
    }
}

extension CVReadOnlyPixelBuffer {
    /// Wraps a pixel buffer that a decoder or pool just produced and will not write to again.
    convenience init(fresh buffer: CVPixelBuffer) {
        self.init(unsafeBuffer: FreshBuffer(buffer).value)
    }
}
