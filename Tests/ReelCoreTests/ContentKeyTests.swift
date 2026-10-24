import Foundation
import Testing
@testable import ReelCore

@Suite struct ContentKeyTests {
    private static func bytes(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    @Test func sameContentGivesTheSameKeyAfterRenameAndMove() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let content = Self.bytes(300_000, seed: 7)
        let first = scratch.file("a.mkv")
        try content.write(to: first)
        let keyBefore = try ContentKey(contentsOf: first)
        let moved = scratch.file("renamed.mp4")
        try FileManager.default.moveItem(at: first, to: moved)
        #expect(try ContentKey(contentsOf: moved) == keyBefore)
    }

    @Test func keyIsLowercaseHexSHA256() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let file = scratch.file("x.bin")
        try Self.bytes(1_000, seed: 1).write(to: file)
        let key = try ContentKey(contentsOf: file)
        #expect(key.hex.count == 64)
        #expect(key.hex.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func changeInTheMiddleIsNotSampled() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        var content = Self.bytes(500_000, seed: 3)
        let one = scratch.file("one.bin")
        try content.write(to: one)
        content[250_000] ^= 0xFF
        let two = scratch.file("two.bin")
        try content.write(to: two)
        #expect(try ContentKey(contentsOf: one) == ContentKey(contentsOf: two))
    }

    @Test func changeInTheFirstOrLast64KiBChangesTheKey() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let content = Self.bytes(500_000, seed: 3)
        let original = scratch.file("o.bin")
        try content.write(to: original)
        let baseline = try ContentKey(contentsOf: original)

        var head = content
        head[100] ^= 0xFF
        let headFile = scratch.file("h.bin")
        try head.write(to: headFile)
        #expect(try ContentKey(contentsOf: headFile) != baseline)

        var tail = content
        tail[content.count - 100] ^= 0xFF
        let tailFile = scratch.file("t.bin")
        try tail.write(to: tailFile)
        #expect(try ContentKey(contentsOf: tailFile) != baseline)
    }

    @Test func sizeIsPartOfTheKey() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let content = Self.bytes(500_000, seed: 9)
        let short = scratch.file("short.bin")
        try content.write(to: short)
        // Same first and last 64 KiB, one extra byte in the middle.
        var longer = content
        longer.insert(0x55, at: 250_000)
        let long = scratch.file("long.bin")
        try longer.write(to: long)
        #expect(try ContentKey(contentsOf: short) != ContentKey(contentsOf: long))
    }

    @Test func smallFilesAreSupported() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let empty = scratch.file("empty.bin")
        try Data().write(to: empty)
        let tiny = scratch.file("tiny.bin")
        try Data([1, 2, 3]).write(to: tiny)
        #expect(try ContentKey(contentsOf: empty) != ContentKey(contentsOf: tiny))
    }

    @Test func missingFileThrows() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        #expect(throws: (any Error).self) { try ContentKey(contentsOf: scratch.file("nope.bin")) }
    }

    @Test func knownVectorMatchesAnIndependentHash() {
        let key = ContentKey(size: 3, head: Data([1, 2, 3]), tail: Data())
        // SHA-256 of 03 00 00 00 00 00 00 00 01 02 03 (size as little-endian UInt64, then the bytes).
        #expect(key.hex == "265540042a8cde29ccc2ba937d5b4dd770b6d9efd2a7a8a07545d22a960b6d7c")
    }
}
