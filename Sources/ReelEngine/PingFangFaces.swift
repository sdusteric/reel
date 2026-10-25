import CoreGraphics
import CoreText
import CReelDeps
import CryptoKit
import Foundation
import ReelCore

/// PingFang SC, TC, HK and MO Medium for libass. On macOS 27 PingFang ships only in PingFangUI.ttc
/// with `hvgl` outlines, which FreeType cannot read, but CoreText still hands out every glyph as
/// a quadratic path. This writes those paths (same glyph ids, same advances, the original GSUB)
/// into one TrueType collection that FreeType reads, so subtitles draw with PingFang itself
/// (design 8.4, D31). Built once in about a second and cached under `REEL_HOME/Caches/fonts`.
enum PingFangFaces {
    struct Face: Sendable {
        /// The CoreText named instance the outlines come from.
        let postScriptName: String
        let family: String
        /// The Chinese family name (Simplified, Traditional or Hong Kong locale).
        let localizedFamily: String
        let localizedFullName: String
        let windowsLanguage: UInt16
    }

    static let faces: [Face] = [
        Face(postScriptName: "PingFangSC-Medium", family: "PingFang SC", localizedFamily: "苹方-简", localizedFullName: "苹方-简 中黑体", windowsLanguage: 0x0804),
        Face(postScriptName: "PingFangTC-Medium", family: "PingFang TC", localizedFamily: "蘋方-繁", localizedFullName: "蘋方-繁 中黑體", windowsLanguage: 0x0404),
        Face(postScriptName: "PingFangHK-Medium", family: "PingFang HK", localizedFamily: "蘋方-港", localizedFullName: "蘋方-港 中黑體", windowsLanguage: 0x0C04),
        Face(postScriptName: "PingFangMO-Medium", family: "PingFang MO", localizedFamily: "蘋方-澳", localizedFullName: "蘋方-澳 中黑體", windowsLanguage: 0x1404),
    ]

    /// Bumped when the output changes, so old cache files are not reused.
    static let formatVersion = 1
    static let weightClass: UInt16 = 500

    struct Collection: Sendable {
        let data: Data
        /// Lowercased families the collection holds ("pingfang sc").
        let families: Set<String>
        /// "built" or "cache".
        let source: String
    }

    /// The collection for this system's PingFang, from the cache when one matches, else built
    /// (and cached when allowed). Nil when PingFang is missing or already drawable as it is.
    static func load(cacheDirectory: URL?) -> Collection? {
        let fonts = faces.map { CTFontCreateWithName($0.postScriptName as CFString, 1000, nil) }
        for (face, font) in zip(faces, fonts) where CTFontCopyPostScriptName(font) as String != face.postScriptName {
            return nil
        }
        let families = Set(faces.map { $0.family.lowercased() })
        let key = cacheKey(fonts[0])
        let file = cacheDirectory?.appending(path: "PingFang-Medium-\(key).ttc", directoryHint: .notDirectory)
        if let file, let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count > 12 {
            return Collection(data: data, families: families, source: "cache")
        }
        guard let data = build(fonts: fonts) else { return nil }
        if let file, let directory = cacheDirectory {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                // A read-only home only costs the build on the next launch.
            }
        }
        return Collection(data: data, families: families, source: "built")
    }

    /// The font file's identity plus the OS build: a system update that changes PingFang
    /// changes the key.
    static func cacheKey(_ font: CTFont) -> String {
        var parts = ["v\(formatVersion)", ProcessInfo.processInfo.operatingSystemVersionString]
        if let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL {
            parts.append(url.path(percentEncoded: false))
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)) {
                parts.append("\((attributes[.size] as? NSNumber)?.intValue ?? 0)")
                parts.append("\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)")
            }
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Building

    static func build(fonts: [CTFont]) -> Data? {
        guard let primary = fonts.first else { return nil }
        let glyphCount = CTFontGetGlyphCount(primary)
        guard glyphCount > 1, CTFontGetUnitsPerEm(primary) > 0 else { return nil }
        guard let outlines = GlyphOutlines(font: primary, glyphCount: glyphCount) else { return nil }
        guard let head = copyTable(primary, "head"), head.count >= 54,
              let hhea = copyTable(primary, "hhea"), hhea.count >= 36,
              let post = copyTable(primary, "post"), post.count >= 32 else { return nil }

        var shared: [UInt32: Data] = [:]
        shared[tag("glyf")] = outlines.glyf
        shared[tag("loca")] = outlines.loca
        shared[tag("hmtx")] = outlines.hmtx
        shared[tag("maxp")] = outlines.maxp
        shared[tag("head")] = patchedHead(head, outlines: outlines)
        shared[tag("hhea")] = patchedHhea(hhea, outlines: outlines)
        var postTable = Data(post.prefix(32))
        postTable.replaceSubrange(0..<4, with: be32(0x0003_0000))
        shared[tag("post")] = postTable
        if let gsub = copyTable(primary, "GSUB") { shared[tag("GSUB")] = gsub }

        var perFace: [[UInt32: Data]] = []
        for (face, font) in zip(faces, fonts) {
            var tables: [UInt32: Data] = [:]
            tables[tag("cmap")] = cmapTable(font)
            tables[tag("name")] = nameTable(face)
            if var os2 = copyTable(font, "OS/2"), os2.count >= 78 {
                os2.replaceSubrange(4..<6, with: be16(weightClass))
                tables[tag("OS/2")] = os2
            }
            perFace.append(tables)
        }
        return collection(shared: shared, perFace: perFace)
    }

    /// One `ttcf` file: shared tables once, then each face's own; every face's directory points
    /// at its own tables plus the shared ones.
    static func collection(shared: [UInt32: Data], perFace: [[UInt32: Data]]) -> Data {
        let headerSize = 12 + 4 * perFace.count
        let directorySizes = perFace.map { 12 + 16 * (shared.count + $0.count) }
        var offset = headerSize + directorySizes.reduce(0, +)
        var body = Data()
        var sharedOffsets: [UInt32: Int] = [:]
        var sharedChecksums: [UInt32: UInt32] = [:]
        func place(_ data: Data) -> Int {
            let start = offset
            body.append(data)
            let padding = (4 - data.count % 4) % 4
            body.append(Data(count: padding))
            offset += data.count + padding
            return start
        }
        for key in shared.keys.sorted() {
            sharedOffsets[key] = place(shared[key] ?? Data())
        }
        var directories: [Data] = []
        for tables in perFace {
            var records: [(tag: UInt32, data: Data, offset: Int)] = []
            for key in tables.keys.sorted() {
                let data = tables[key] ?? Data()
                records.append((key, data, place(data)))
            }
            for (key, data) in shared {
                records.append((key, data, sharedOffsets[key] ?? 0))
            }
            records.sort { $0.tag < $1.tag }
            // Shared tables are summed once, not once per face.
            for record in records where sharedChecksums[record.tag] == nil && shared[record.tag] != nil {
                sharedChecksums[record.tag] = checksum(record.data)
            }
            var directory = Data()
            let count = records.count
            var power = 1
            var exponent = 0
            while power * 2 <= count {
                power *= 2
                exponent += 1
            }
            directory.append(be32(0x0001_0000))
            directory.append(be16(UInt16(count)))
            directory.append(be16(UInt16(power * 16)))
            directory.append(be16(UInt16(exponent)))
            directory.append(be16(UInt16(count * 16 - power * 16)))
            for record in records {
                directory.append(be32(record.tag))
                directory.append(be32(shared[record.tag] != nil ? sharedChecksums[record.tag] ?? 0 : checksum(record.data)))
                directory.append(be32(UInt32(record.offset)))
                directory.append(be32(UInt32(record.data.count)))
            }
            directories.append(directory)
        }
        var file = Data()
        file.append(be32(tag("ttcf")))
        file.append(be32(0x0001_0000))
        file.append(be32(UInt32(perFace.count)))
        var directoryOffset = headerSize
        for directory in directories {
            file.append(be32(UInt32(directoryOffset)))
            directoryOffset += directory.count
        }
        for directory in directories { file.append(directory) }
        file.append(body)
        return file
    }

    static func patchedHead(_ original: Data, outlines: GlyphOutlines) -> Data {
        var head = Data(original.prefix(54))
        head.replaceSubrange(8..<12, with: be32(0))
        head.replaceSubrange(36..<38, with: be16(UInt16(bitPattern: outlines.bounds.xMin)))
        head.replaceSubrange(38..<40, with: be16(UInt16(bitPattern: outlines.bounds.yMin)))
        head.replaceSubrange(40..<42, with: be16(UInt16(bitPattern: outlines.bounds.xMax)))
        head.replaceSubrange(42..<44, with: be16(UInt16(bitPattern: outlines.bounds.yMax)))
        // Long loca offsets, glyf data format 0.
        head.replaceSubrange(50..<52, with: be16(1))
        head.replaceSubrange(52..<54, with: be16(0))
        return head
    }

    static func patchedHhea(_ original: Data, outlines: GlyphOutlines) -> Data {
        var hhea = Data(original.prefix(36))
        hhea.replaceSubrange(10..<12, with: be16(outlines.maximumAdvance))
        hhea.replaceSubrange(12..<14, with: be16(UInt16(bitPattern: outlines.minimumLeftBearing)))
        hhea.replaceSubrange(14..<16, with: be16(UInt16(bitPattern: outlines.minimumRightBearing)))
        hhea.replaceSubrange(16..<18, with: be16(UInt16(bitPattern: outlines.maximumExtent)))
        hhea.replaceSubrange(34..<36, with: be16(UInt16(outlines.glyphCount)))
        return hhea
    }

    // MARK: cmap

    /// Code point to glyph for every scalar the face maps.
    static func characterMap(_ font: CTFont) -> [(UInt32, UInt16)] {
        var codes: UnsafeMutablePointer<UInt32>?
        var glyphs: UnsafeMutablePointer<UInt16>?
        let count = reel_font_character_map(Unmanaged.passUnretained(font).toOpaque(), &codes, &glyphs)
        defer {
            free(codes)
            free(glyphs)
        }
        guard count > 0, let codes, let glyphs else { return [] }
        return (0..<count).map { (codes[$0], glyphs[$0]) }
    }

    static func cmapTable(_ font: CTFont) -> Data {
        let map = characterMap(font)
        // Format 4 caps its length at 65535 bytes, which a full CJK map can exceed; FreeType,
        // HarfBuzz and libass all take the format 12 (3, 10) subtable first.
        var format4 = cmapFormat4(map.filter { $0.0 <= 0xFFFF })
        if format4.count > 0xFFFF { format4 = Data() }
        let format12 = cmapFormat12(map)
        let count = format4.isEmpty ? 1 : 2
        var table = Data()
        table.append(be16(0))
        table.append(be16(UInt16(count)))
        if !format4.isEmpty {
            table.append(be16(3))
            table.append(be16(1))
            table.append(be32(UInt32(4 + count * 8)))
        }
        table.append(be16(3))
        table.append(be16(10))
        table.append(be32(UInt32(4 + count * 8 + format4.count)))
        table.append(format4)
        table.append(format12)
        return table
    }

    static func cmapFormat4(_ map: [(UInt32, UInt16)]) -> Data {
        // Runs of consecutive code points; each run is one segment through glyphIdArray unless
        // its glyphs are consecutive too.
        var segments: [(start: UInt16, end: UInt16, glyphs: [UInt16])] = []
        for (code, glyph) in map where code < 0xFFFF {
            let value = UInt16(code)
            if let last = segments.last, last.end &+ 1 == value {
                segments[segments.count - 1].end = value
                segments[segments.count - 1].glyphs.append(glyph)
            } else {
                segments.append((value, value, [glyph]))
            }
        }
        segments.append((0xFFFF, 0xFFFF, [0]))
        let count = segments.count
        var deltas: [UInt16] = []
        var rangeOffsets: [UInt16] = []
        var glyphArray: [UInt16] = []
        for (index, segment) in segments.enumerated() {
            let consecutive = segment.glyphs.enumerated().allSatisfy { Int($0.element) == Int(segment.glyphs[0]) + $0.offset }
            if consecutive || segment.start == 0xFFFF {
                let delta = segment.start == 0xFFFF ? 1 : (Int(segment.glyphs[0]) - Int(segment.start))
                deltas.append(UInt16(truncatingIfNeeded: delta))
                rangeOffsets.append(0)
            } else {
                deltas.append(0)
                // Bytes from this idRangeOffset entry to its first glyphIdArray entry.
                rangeOffsets.append(UInt16(truncatingIfNeeded: 2 * (count - index + glyphArray.count)))
                glyphArray.append(contentsOf: segment.glyphs)
            }
        }
        var power = 1
        var exponent = 0
        while power * 2 <= count {
            power *= 2
            exponent += 1
        }
        let length = 16 + 8 * count + 2 * glyphArray.count
        guard length <= 0xFFFF else { return Data(count: length) }
        var data = Data()
        data.append(be16(4))
        data.append(be16(UInt16(length)))
        data.append(be16(0))
        data.append(be16(UInt16(2 * count)))
        data.append(be16(UInt16(2 * power)))
        data.append(be16(UInt16(exponent)))
        data.append(be16(UInt16(2 * count - 2 * power)))
        for segment in segments { data.append(be16(segment.end)) }
        data.append(be16(0))
        for segment in segments { data.append(be16(segment.start)) }
        for delta in deltas { data.append(be16(delta)) }
        for offset in rangeOffsets { data.append(be16(offset)) }
        for glyph in glyphArray { data.append(be16(glyph)) }
        return data
    }

    static func cmapFormat12(_ map: [(UInt32, UInt16)]) -> Data {
        var groups: [(start: UInt32, end: UInt32, glyph: UInt32)] = []
        for (code, glyph) in map {
            if let last = groups.last, last.end + 1 == code, last.glyph + (code - last.start) == UInt32(glyph) {
                groups[groups.count - 1].end = code
            } else {
                groups.append((code, code, UInt32(glyph)))
            }
        }
        var data = Data()
        data.append(be16(12))
        data.append(be16(0))
        data.append(be32(UInt32(16 + 12 * groups.count)))
        data.append(be32(0))
        data.append(be32(UInt32(groups.count)))
        for group in groups {
            data.append(be32(group.start))
            data.append(be32(group.end))
            data.append(be32(group.glyph))
        }
        return data
    }

    // MARK: name

    static func nameTable(_ face: Face) -> Data {
        let subfamily = "Medium"
        var records: [(language: UInt16, id: UInt16, text: String)] = [
            (0x0409, 1, face.family),
            (0x0409, 2, subfamily),
            (0x0409, 3, "Reel: \(face.postScriptName) from CoreText outlines"),
            (0x0409, 4, "\(face.family) \(subfamily)"),
            (0x0409, 6, face.postScriptName),
            (0x0409, 16, face.family),
            (0x0409, 17, subfamily),
            (face.windowsLanguage, 1, face.localizedFamily),
            (face.windowsLanguage, 4, face.localizedFullName),
        ]
        records.sort { ($0.language, $0.id) < ($1.language, $1.id) }
        var strings = Data()
        var directory = Data()
        for record in records {
            let bytes = Data(record.text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
            directory.append(be16(3))
            directory.append(be16(1))
            directory.append(be16(record.language))
            directory.append(be16(record.id))
            directory.append(be16(UInt16(bytes.count)))
            directory.append(be16(UInt16(strings.count)))
            strings.append(bytes)
        }
        var data = Data()
        data.append(be16(0))
        data.append(be16(UInt16(records.count)))
        data.append(be16(UInt16(6 + directory.count)))
        data.append(directory)
        data.append(strings)
        return data
    }

    // MARK: Bytes

    /// A private copy of one table. CoreText can hand out bytes mapped read-only from the font
    /// file, and editing those in place crashes with SIGBUS.
    static func copyTable(_ font: CTFont, _ name: String) -> Data? {
        guard let table = CTFontCopyTable(font, tag(name), []) else { return nil }
        let length = CFDataGetLength(table)
        guard length > 0, let bytes = CFDataGetBytePtr(table) else { return nil }
        return Data(UnsafeBufferPointer(start: bytes, count: length))
    }

    static func tag(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func be16(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }

    static func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            reel_table_checksum(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
    }
}

/// Every glyph of one CoreText font as TrueType `glyf`, `loca`, `hmtx` and `maxp` data. The
/// outlines are converted in C (`reel_build_glyf`): 47,000 glyphs take about a second there, and
/// over ten in an unoptimised Swift build, which made tests wait.
struct GlyphOutlines {
    let glyphCount: Int
    private(set) var glyf = Data()
    private(set) var loca = Data()
    private(set) var hmtx = Data()
    private(set) var maxp = Data()
    private(set) var bounds = (xMin: Int16.max, yMin: Int16.max, xMax: Int16.min, yMax: Int16.min)
    private(set) var maximumAdvance: UInt16 = 0
    private(set) var minimumLeftBearing = Int16.max
    private(set) var minimumRightBearing = Int16.max
    private(set) var maximumExtent = Int16.min

    init?(font: CTFont, glyphCount: Int) {
        self.glyphCount = glyphCount
        var result = reel_glyf_result()
        guard reel_build_glyf(Unmanaged.passUnretained(font).toOpaque(), UInt32(glyphCount), &result) == 0,
              let offsets = result.offsets, let boxes = result.bounds else { return nil }
        defer { reel_glyf_free(&result) }
        if let bytes = result.glyf { glyf = Data(bytes: bytes, count: result.glyf_size) }
        var advances = [CGSize](repeating: .zero, count: glyphCount)
        let glyphIDs = (0..<glyphCount).map { CGGlyph($0) }
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphIDs, &advances, glyphCount)
        var locaBytes = [UInt8](repeating: 0, count: (glyphCount + 1) * 4)
        var hmtxBytes = [UInt8](repeating: 0, count: glyphCount * 4)
        for glyph in 0...glyphCount {
            let offset = offsets[glyph]
            locaBytes[glyph * 4] = UInt8(offset >> 24)
            locaBytes[glyph * 4 + 1] = UInt8((offset >> 16) & 0xFF)
            locaBytes[glyph * 4 + 2] = UInt8((offset >> 8) & 0xFF)
            locaBytes[glyph * 4 + 3] = UInt8(offset & 0xFF)
        }
        for glyph in 0..<glyphCount {
            let advance = UInt16(clamping: Int(advances[glyph].width.rounded()))
            maximumAdvance = max(maximumAdvance, advance)
            var leftBearing: Int16 = 0
            if offsets[glyph + 1] > offsets[glyph] {
                let box = (xMin: boxes[glyph * 4], yMin: boxes[glyph * 4 + 1], xMax: boxes[glyph * 4 + 2], yMax: boxes[glyph * 4 + 3])
                leftBearing = box.xMin
                bounds = (min(bounds.xMin, box.xMin), min(bounds.yMin, box.yMin), max(bounds.xMax, box.xMax), max(bounds.yMax, box.yMax))
                minimumLeftBearing = min(minimumLeftBearing, box.xMin)
                minimumRightBearing = min(minimumRightBearing, Int16(clamping: Int(advance) - Int(box.xMax)))
                maximumExtent = max(maximumExtent, box.xMax)
            }
            hmtxBytes[glyph * 4] = UInt8(advance >> 8)
            hmtxBytes[glyph * 4 + 1] = UInt8(advance & 0xFF)
            let bearing = UInt16(bitPattern: leftBearing)
            hmtxBytes[glyph * 4 + 2] = UInt8(bearing >> 8)
            hmtxBytes[glyph * 4 + 3] = UInt8(bearing & 0xFF)
        }
        loca = Data(locaBytes)
        hmtx = Data(hmtxBytes)
        if bounds.xMin > bounds.xMax { bounds = (0, 0, 0, 0) }
        if minimumLeftBearing == .max { minimumLeftBearing = 0 }
        if minimumRightBearing == .max { minimumRightBearing = 0 }
        if maximumExtent == .min { maximumExtent = 0 }
        var table = Data()
        table.append(PingFangFaces.be32(0x0001_0000))
        table.append(PingFangFaces.be16(UInt16(glyphCount)))
        table.append(PingFangFaces.be16(result.max_points))
        table.append(PingFangFaces.be16(result.max_contours))
        // maxComponentPoints, maxComponentContours, maxZones 2, then twigs, storage, function
        // and instruction defs, stack, instruction size, component elements and depth: unused.
        for value: UInt16 in [0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0] { table.append(PingFangFaces.be16(value)) }
        maxp = table
    }
}
