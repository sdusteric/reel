import CReelDeps
import Foundation
import ReelCore
import Synchronization

/// A negative return code from an FFmpeg call.
public struct FFmpegError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    public let code: Int32
    public let operation: String

    public init(code: Int32, operation: String) {
        self.code = code
        self.operation = operation
    }

    public var message: String { FFmpegError.message(for: code) }
    public var description: String { "\(operation): \(message) (\(code))" }
    public var errorDescription: String? { description }

    public var isEndOfFile: Bool { code == reel_averror_eof() }
    public var isAgain: Bool { code == reel_averror_eagain() }

    /// FFmpeg's text for an error code, via the thread-safe shim.
    public static func message(for code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        return buffer.withUnsafeMutableBufferPointer { pointer in
            String(cString: reel_err_string(code, pointer.baseAddress, pointer.count))
        }
    }

    /// Returns `code` when it is not negative, otherwise throws.
    @discardableResult
    public static func check(_ code: Int32, _ operation: @autoclosure () -> String) throws -> Int32 {
        if code < 0 { throw FFmpegError(code: code, operation: operation()) }
        return code
    }
}

/// A failed Core Media, Core Video or VideoToolbox call.
public struct MediaStatusError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    public let status: Int32
    public let operation: String

    public init(status: Int32, operation: String) {
        self.status = status
        self.operation = operation
    }

    public var description: String { "\(operation) failed with status \(status)" }
    public var errorDescription: String? { description }

    /// Throws unless `status` is zero (noErr, kCVReturnSuccess).
    public static func check(_ status: Int32, _ operation: @autoclosure () -> String) throws {
        if status != 0 { throw MediaStatusError(status: status, operation: operation()) }
    }
}

// MARK: Classification (design section 7.10)

extension FFmpegError {
    /// `AVERROR_INVALIDDATA`: the bytes are not what the demuxer or decoder expected.
    public var isInvalidData: Bool { code == reel_averror_invaliddata() }

    /// The POSIX errno behind an `AVERROR(e)` code, when it is one.
    public var posixCode: Int32? {
        let errno = -code
        return errno > 0 && errno < 256 ? errno : nil
    }

    /// An operating system read error: the disk, the drive or the permissions, not the data.
    public var isReadError: Bool {
        guard let errno = posixCode else { return false }
        return FFmpegError.readErrnos.contains(errno)
    }

    /// The errors a disconnected drive produces (section 7.10): no device, I/O error, file gone.
    public var isDriveLossError: Bool {
        guard let errno = posixCode else { return false }
        return errno == ENXIO || errno == EIO || errno == ENOENT || errno == ENODEV
    }

    /// `AVERROR_EXIT`: the interrupt callback stopped a blocking call.
    public var isInterrupted: Bool { code == FFmpegError.exitCode }

    static let readErrnos: Set<Int32> = [EIO, ENXIO, ENOENT, ENODEV, EACCES, EPERM, ETIMEDOUT, EBUSY, ESTALE, ENOTDIR, EISDIR]

    /// `FFERRTAG('E','X','I','T')`.
    static let exitCode: Int32 = -Int32(bitPattern: UInt32(0x45) | UInt32(0x58) << 8 | UInt32(0x49) << 16 | UInt32(0x54) << 24)
}

/// Lets a blocking FFmpeg call give up (section 7.10): an open that has not finished by its
/// deadline, or a read on a demuxer that is being stopped. Installed as the format context's
/// `interrupt_callback`, which FFmpeg polls inside its read loops.
public final class ReadInterrupt: Sendable {
    private let aborted = Atomic<Bool>(false)
    private let timedOutFlag = Atomic<Bool>(false)
    /// Uptime nanoseconds after which calls are interrupted; 0 means no deadline.
    private let deadline = Atomic<UInt64>(0)

    public init() {}

    /// Interrupts blocking calls from now on.
    public func abort() {
        aborted.store(true, ordering: .releasing)
    }

    /// Interrupts calls still running `duration` from now; nil removes the deadline.
    public func setDeadline(after duration: Duration?) {
        guard let duration else {
            deadline.store(0, ordering: .releasing)
            return
        }
        let nanos = UInt64(max(0, duration / .nanoseconds(1)))
        deadline.store(DispatchTime.now().uptimeNanoseconds &+ max(nanos, 1), ordering: .releasing)
    }

    public var isAborted: Bool { aborted.load(ordering: .acquiring) }
    /// True once the deadline interrupted something (the open timed out).
    public var timedOut: Bool { timedOutFlag.load(ordering: .acquiring) }

    /// What the callback answers: 1 to interrupt.
    func shouldInterrupt() -> Bool {
        if aborted.load(ordering: .acquiring) { return true }
        let limit = deadline.load(ordering: .acquiring)
        if limit != 0, DispatchTime.now().uptimeNanoseconds > limit {
            timedOutFlag.store(true, ordering: .releasing)
            return true
        }
        return false
    }

    /// The `AVIOInterruptCB` for a format context. The context must not outlive `self`.
    var callback: AVIOInterruptCB {
        AVIOInterruptCB(
            callback: { opaque in
                guard let opaque else { return 0 }
                return Unmanaged<ReadInterrupt>.fromOpaque(opaque).takeUnretainedValue().shouldInterrupt() ? 1 : 0
            },
            opaque: Unmanaged.passUnretained(self).toOpaque()
        )
    }
}
