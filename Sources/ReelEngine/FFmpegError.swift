import CReelDeps
import Foundation
import ReelCore

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
