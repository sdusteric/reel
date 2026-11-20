import CoreMedia
import CoreVideo
import CReelDeps
import Foundation
import Metal
import ReelCore
import Synchronization

/// How the two fields of a frame are ordered in time.
public enum FieldOrder: Sendable, Hashable {
    case progressive
    case topFirst
    case bottomFirst

    /// From FFmpeg's `AVFieldOrder`: TT and TB show the top field first, BB and BT the bottom one.
    init(_ order: AVFieldOrder) {
        switch order {
        case AV_FIELD_TT, AV_FIELD_TB: self = .topFirst
        case AV_FIELD_BB, AV_FIELD_BT: self = .bottomFirst
        default: self = .progressive
        }
    }
}

/// Removes the comb lines of interlaced frames before they are shown, at frame rate, on the GPU.
///
/// The field shown first is kept. Each line of the other field stays where it matches the lines
/// around it (still picture, full resolution) and is rebuilt from them where the two fields
/// disagree (motion, which shows as combing). Progressive frames pass through untouched.
///
/// A frame is interlaced when its buffer says two fields (the software decoder tags each frame
/// libavcodec flags interlaced), or when it comes from VideoToolbox and the stream's field order
/// is interlaced.
public final class Deinterlacer: @unchecked Sendable {
    // Unchecked Sendable: the Metal objects are thread safe, and `outputs` is behind a mutex.

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // One plane: luma (r) or interleaved chroma (rg). keepParity is the row parity of the field
    // shown first. Rows of the other field keep their own sample where it fits between its
    // neighbors and take their average where it sticks out from both (combing).
    kernel void deinterlace(texture2d<float, access::read> source [[texture(0)]],
                            texture2d<float, access::write> target [[texture(1)]],
                            constant uint &keepParity [[buffer(0)]],
                            uint2 position [[thread_position_in_grid]]) {
        uint width = source.get_width();
        uint height = source.get_height();
        if (position.x >= width || position.y >= height) { return; }
        float4 own = source.read(position);
        if ((position.y & 1) == keepParity || position.y == 0 || position.y + 1 >= height) {
            target.write(own, position);
            return;
        }
        float4 above = source.read(uint2(position.x, position.y - 1));
        float4 below = source.read(uint2(position.x, position.y + 1));
        float4 comb = (own - above) * (own - below);
        float strength = max(comb.r, comb.g);
        float blend = smoothstep(0.0004, 0.0025, strength);
        target.write(mix(own, (above + below) * 0.5, blend), position);
    }
    """

    /// Made on the first interlaced frame; nil without Metal.
    public static let shared = Deinterlacer()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private struct Outputs {
        var pool: CVPixelBufferPool?
        var key: (width: Int, height: Int, format: OSType)?
    }
    private let outputs = Mutex(Outputs())

    /// Nil when the Mac has no Metal device or the kernel does not build.
    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let function = library.makeFunction(name: "deinterlace"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        textureCache = cache
    }

    /// The field order of `frame`, from its buffer or, for a VideoToolbox frame, the stream.
    public static func fieldOrder(of frame: DecodedFrame, stream: FieldOrder) -> FieldOrder {
        // VideoToolbox tags its frames one field whatever the stream is, so for its frames only
        // a two-field tag counts and the stream decides otherwise.
        frame.pixelBuffer.withUnsafeBuffer { buffer in
            if CVBufferCopyAttachment(buffer, kCVImageBufferFieldCountKey, nil) as? Int == 2 {
                let detail = CVBufferCopyAttachment(buffer, kCVImageBufferFieldDetailKey, nil) as? String
                return detail == kCVImageBufferFieldDetailTemporalBottomFirst as String ? .bottomFirst : .topFirst
            }
            return frame.decoder == .hardware ? stream : .progressive
        }
    }

    /// `frame` with its combing removed, or `frame` itself when it is progressive or cannot be
    /// processed (an unexpected pixel format, no output buffer). Waits for the GPU, about a
    /// millisecond for a 1080 frame.
    public func process(_ frame: DecodedFrame, stream: FieldOrder) -> DecodedFrame {
        let order = Self.fieldOrder(of: frame, stream: stream)
        guard order != .progressive, let output = run(frame, order: order) else { return frame }
        return DecodedFrame(
            pixelBuffer: CVReadOnlyPixelBuffer(fresh: output.value),
            presentationTime: frame.presentationTime,
            duration: frame.duration,
            generation: frame.generation,
            decoder: frame.decoder,
            concealedErrors: frame.concealedErrors
        )
    }

    private func run(_ frame: DecodedFrame, order: FieldOrder) -> FreshBuffer<CVPixelBuffer>? {
        frame.pixelBuffer.withUnsafeBuffer { source -> FreshBuffer<CVPixelBuffer>? in
            let format = CVPixelBufferGetPixelFormatType(source)
            let planeFormats: (MTLPixelFormat, MTLPixelFormat)
            switch format {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                planeFormats = (.r8Unorm, .rg8Unorm)
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
                planeFormats = (.r16Unorm, .rg16Unorm)
            default:
                return nil
            }
            let width = CVPixelBufferGetWidth(source)
            let height = CVPixelBufferGetHeight(source)
            guard let target = makeBuffer(width: width, height: height, format: format) else { return nil }
            CVBufferPropagateAttachments(source, target)
            CVBufferSetAttachment(target, kCVImageBufferFieldCountKey, 1 as CFNumber, .shouldPropagate)
            CVBufferRemoveAttachment(target, kCVImageBufferFieldDetailKey)
            guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { return nil }
            var keepParity: UInt32 = order == .topFirst ? 0 : 1
            encoder.setComputePipelineState(pipeline)
            encoder.setBytes(&keepParity, length: MemoryLayout<UInt32>.size, index: 0)
            // The CVMetalTextures must live until the GPU is done with them.
            var textures: [CVMetalTexture] = []
            for (plane, pixelFormat) in [(0, planeFormats.0), (1, planeFormats.1)] {
                guard let input = texture(source, plane: plane, format: pixelFormat),
                      let output = texture(target, plane: plane, format: pixelFormat),
                      let inputTexture = CVMetalTextureGetTexture(input),
                      let outputTexture = CVMetalTextureGetTexture(output) else {
                    encoder.endEncoding()
                    return nil
                }
                textures += [input, output]
                encoder.setTexture(inputTexture, index: 0)
                encoder.setTexture(outputTexture, index: 1)
                let threads = MTLSize(width: 16, height: 16, depth: 1)
                let groups = MTLSize(
                    width: (inputTexture.width + threads.width - 1) / threads.width,
                    height: (inputTexture.height + threads.height - 1) / threads.height,
                    depth: 1
                )
                encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
            }
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            withExtendedLifetime(textures) {}
            guard commands.status == .completed else { return nil }
            // A pool buffer made above and written only by this command buffer.
            return FreshBuffer(target)
        }
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture
        )
        return status == kCVReturnSuccess ? texture : nil
    }

    private func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        outputs.withLock { outputs -> CVPixelBuffer? in
            if outputs.pool == nil || outputs.key.map({ $0.width != width || $0.height != height || $0.format != format }) ?? true {
                let attributes: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey: format,
                    kCVPixelBufferWidthKey: width,
                    kCVPixelBufferHeightKey: height,
                    kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
                    kCVPixelBufferMetalCompatibilityKey: true,
                ]
                var pool: CVPixelBufferPool?
                CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
                outputs.pool = pool
                outputs.key = (width, height, format)
            }
            guard let pool = outputs.pool else { return nil }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            return buffer
        }
    }
}
