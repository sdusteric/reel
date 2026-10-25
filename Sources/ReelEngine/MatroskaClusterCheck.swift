import CReelDeps
import Foundation
import Synchronization

/// Verifies the CRC-32 elements of Matroska and WebM clusters (design section 7.10). FFmpeg's
/// Matroska demuxer skips a cluster's CRC-32, and some damage inside video data (a VP9 tile, an
/// H.263 block) decodes without any error, so a cluster whose checksum fails is the only sign of
/// it. Clusters are found by walking the Segment's top-level elements from the file, lazily, as
/// packets ask for them; each cluster is read and checked once.
///
/// A cluster without a CRC-32, of unknown size, larger than `maximumClusterBytes` or not wholly
/// in the file (a file cut short) is never reported: only a checksum that is present and wrong
/// counts as damage.
final class MatroskaClusterCheck: Sendable {
    static let maximumClusterBytes = 64 << 20

    private static let segmentID: UInt32 = 0x1853_8067
    private static let clusterID: UInt32 = 0x1F43_B675
    private static let crcID: UInt32 = 0xBF

    private struct Cluster {
        /// Offset of the cluster's data (after its ID and size).
        var dataStart: Int64
        var dataEnd: Int64
        /// nil until checked; then whether its CRC-32 failed.
        var damaged: Bool?
        var queued = false
    }

    private struct State {
        var handle: FileHandle?
        var fileSize: Int64
        /// Where the walk of the Segment's children continues, and where the Segment ends.
        var nextElement: Int64
        var segmentEnd: Int64
        var walkEnded = false
        var clusters: [Cluster] = []
    }

    private let state: Mutex<State>
    /// Background reads and checksums, one cluster at a time.
    private let queue = DispatchQueue(label: "reel.matroska-cluster-check", qos: .utility)

    /// Nil when the file is not Matroska or its Segment cannot be found.
    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        guard let size = try? handle.seekToEnd(), size > 0,
              let segment = MatroskaClusterCheck.findSegment(handle, fileSize: Int64(size)) else {
            try? handle.close()
            return nil
        }
        state = Mutex(State(handle: handle, fileSize: Int64(size), nextElement: segment.dataStart, segmentEnd: segment.dataEnd))
    }

    deinit {
        close()
    }

    func close() {
        let handle = state.withLock { state -> FileHandle? in
            defer { state.handle = nil }
            return state.handle
        }
        try? handle?.close()
    }

    /// Checks the cluster holding a packet at `position` once, off the caller's thread (a seek
    /// must not wait for a cluster to be read twice), and calls `damaged` there if its CRC-32
    /// fails. Packets of a cluster already queued or checked cost a binary search.
    func check(position: Int64, damaged: @escaping @Sendable () -> Void) {
        let queued = state.withLock { state -> Bool in
            guard let index = MatroskaClusterCheck.cluster(containing: position, in: &state),
                  !state.clusters[index].queued else { return false }
            state.clusters[index].queued = true
            return true
        }
        guard queued else { return }
        queue.async { [self] in
            if checksumFails(position: position) { damaged() }
        }
    }

    /// Synchronous check of the cluster holding `position` (tests, and the queue above).
    func checksumFails(position: Int64) -> Bool {
        state.withLock { state in
            guard let index = MatroskaClusterCheck.cluster(containing: position, in: &state) else { return false }
            if let known = state.clusters[index].damaged { return known }
            let damaged = MatroskaClusterCheck.checksumFails(state.clusters[index], state: state)
            state.clusters[index].damaged = damaged
            return damaged
        }
    }

    // MARK: Walking

    private static func cluster(containing position: Int64, in state: inout State) -> Int? {
        if let last = state.clusters.last, position < last.dataEnd {
            // Binary search over the clusters found so far.
            var low = 0
            var high = state.clusters.count - 1
            while low <= high {
                let middle = (low + high) / 2
                let cluster = state.clusters[middle]
                if position < cluster.dataStart {
                    high = middle - 1
                } else if position >= cluster.dataEnd {
                    low = middle + 1
                } else {
                    return middle
                }
            }
            return nil
        }
        while !state.walkEnded {
            guard let handle = state.handle else { return nil }
            let offset = state.nextElement
            guard offset < min(state.segmentEnd, state.fileSize),
                  let header = readHeader(handle, at: offset, fileSize: state.fileSize),
                  let size = header.size else {
                state.walkEnded = true
                return nil
            }
            let dataStart = offset + Int64(header.length)
            let dataEnd = dataStart + size
            state.nextElement = dataEnd
            guard header.id == clusterID else { continue }
            state.clusters.append(Cluster(dataStart: dataStart, dataEnd: dataEnd))
            if position < dataStart { return nil }
            if position < dataEnd { return state.clusters.count - 1 }
        }
        return nil
    }

    private static func checksumFails(_ cluster: Cluster, state: State) -> Bool {
        guard let handle = state.handle, cluster.dataEnd <= state.fileSize,
              cluster.dataEnd - cluster.dataStart <= Int64(maximumClusterBytes),
              let first = readHeader(handle, at: cluster.dataStart, fileSize: state.fileSize),
              first.id == crcID, first.size == 4 else { return false }
        let crcStart = cluster.dataStart + Int64(first.length)
        let covered = crcStart + 4
        guard let stored = read(handle, at: crcStart, count: 4), stored.count == 4,
              let data = read(handle, at: covered, count: Int(cluster.dataEnd - covered)),
              data.count == Int(cluster.dataEnd - covered) else { return false }
        // EBML stores the CRC-32 (IEEE, reflected) little-endian.
        let expected = UInt32(stored[0]) | UInt32(stored[1]) << 8 | UInt32(stored[2]) << 16 | UInt32(stored[3]) << 24
        let crc = data.withUnsafeBytes { bytes in
            reel_crc32(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        return crc != expected
    }

    private static func findSegment(_ handle: FileHandle, fileSize: Int64) -> (dataStart: Int64, dataEnd: Int64)? {
        // The EBML header, then the Segment.
        guard let ebml = readHeader(handle, at: 0, fileSize: fileSize), ebml.id == 0x1A45_DFA3, let ebmlSize = ebml.size else { return nil }
        var offset = Int64(ebml.length) + ebmlSize
        while offset < fileSize, let header = readHeader(handle, at: offset, fileSize: fileSize) {
            let dataStart = offset + Int64(header.length)
            if header.id == segmentID { return (dataStart, header.size.map { dataStart + $0 } ?? fileSize) }
            guard let size = header.size else { return nil }
            offset = dataStart + size
        }
        return nil
    }

    // MARK: EBML

    /// An element's ID (with its length marker, as the spec writes IDs), data size (nil when
    /// unknown) and header length.
    private static func readHeader(_ handle: FileHandle, at offset: Int64, fileSize: Int64) -> (id: UInt32, size: Int64?, length: Int)? {
        guard let bytes = read(handle, at: offset, count: Int(min(12, fileSize - offset))), !bytes.isEmpty else { return nil }
        let raw = [UInt8](bytes)
        guard let idLength = vintLength(raw[0]), idLength <= 4, raw.count >= idLength else { return nil }
        var id: UInt32 = 0
        for byte in raw[0..<idLength] { id = id << 8 | UInt32(byte) }
        guard raw.count > idLength, let sizeLength = vintLength(raw[idLength]), raw.count >= idLength + sizeLength else { return nil }
        var size = UInt64(raw[idLength]) & (0xFF >> UInt64(sizeLength))
        var allOnes = size == (0xFF >> UInt64(sizeLength))
        for byte in raw[(idLength + 1)..<(idLength + sizeLength)] {
            size = size << 8 | UInt64(byte)
            allOnes = allOnes && byte == 0xFF
        }
        let known = allOnes ? nil : Int64(exactly: size)
        return (id, known, idLength + sizeLength)
    }

    /// Length of a variable-length integer from its first byte (1 to 8), nil for 0.
    private static func vintLength(_ first: UInt8) -> Int? {
        guard first != 0 else { return nil }
        return first.leadingZeroBitCount + 1
    }

    private static func read(_ handle: FileHandle, at offset: Int64, count: Int) -> Data? {
        guard count >= 0, offset >= 0 else { return nil }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            return nil
        }
    }
}
