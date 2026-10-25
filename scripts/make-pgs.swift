// Writes the PGS fixture for subs_pgs.mkv: a raw HDMV presentation graphics stream (.sup) with
// two display sets of one object each, each cleared two seconds later, plus a JSON file with the
// rectangles so tests can check positions.
//
// Usage: swift scripts/make-pgs.swift <out.sup> <out-rects.json>
//
// Segment layout follows the HDMV PG format: "PG", pts and dts (90 kHz), type, size, payload.
// Types: 0x14 palette (PDS), 0x15 object (ODS), 0x16 presentation composition (PCS),
// 0x17 window (WDS), 0x80 end of display set.
import Foundation

struct Rect {
    var start: Double
    var end: Double
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

let canvasWidth = 1920
let canvasHeight = 1080
let rects = [
    Rect(start: 1.0, end: 3.0, x: 660, y: 900, width: 600, height: 90),
    Rect(start: 4.0, end: 6.0, x: 460, y: 960, width: 1000, height: 60),
]

// Palette entries: 0 transparent, 1 white, 2 black, 3 grey. Y, Cr, Cb in video range.
let palette: [(id: UInt8, y: UInt8, cr: UInt8, cb: UInt8, alpha: UInt8)] = [
    (0, 16, 128, 128, 0),
    (1, 235, 128, 128, 255),
    (2, 16, 128, 128, 255),
    (3, 126, 128, 128, 255),
]

func be16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
func be24(_ value: Int) -> [UInt8] { [UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
func be32(_ value: Int) -> [UInt8] {
    [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

func segment(_ type: UInt8, pts: Int, _ payload: [UInt8]) -> [UInt8] {
    [0x50, 0x47] + be32(pts) + be32(0) + [type] + be16(payload.count) + payload
}

/// A black 3 px frame around the whole object, transparent inside, with white blocks outlined
/// in black 2 px, so the visible ink spans exactly the object rectangle.
func pixels(width: Int, height: Int) -> [[UInt8]] {
    var rows = Array(repeating: Array(repeating: UInt8(0), count: width), count: height)
    for row in 0..<height {
        for column in 0..<width where row < 3 || row >= height - 3 || column < 3 || column >= width - 3 {
            rows[row][column] = 2
        }
    }
    let margin = 12
    let blockWidth = 44
    let gap = 22
    let count = (width - 36 + gap) / (blockWidth + gap)
    var left = (width - (count * blockWidth + (count - 1) * gap)) / 2
    for _ in 0..<count {
        for row in margin..<(height - margin) {
            for column in left..<(left + blockWidth) {
                let edge = row < margin + 2 || row >= height - margin - 2 || column < left + 2 || column >= left + blockWidth - 2
                rows[row][column] = edge ? 2 : 1
            }
        }
        left += blockWidth + gap
    }
    return rows
}

/// PGS run-length encoding, one line at a time, each line ending with 0x00 0x00.
func encodeRLE(_ rows: [[UInt8]]) -> [UInt8] {
    var output: [UInt8] = []
    for row in rows {
        var index = 0
        while index < row.count {
            let color = row[index]
            var length = 1
            while index + length < row.count, row[index + length] == color, length < 16_383 { length += 1 }
            if color == 0 {
                output += length < 64 ? [0x00, UInt8(length)] : [0x00, UInt8(0x40 | (length >> 8)), UInt8(length & 0xFF)]
            } else if length < 3 {
                output += Array(repeating: color, count: length)
            } else if length < 64 {
                output += [0x00, UInt8(0x80 | length), color]
            } else {
                output += [0x00, UInt8(0xC0 | (length >> 8)), UInt8(length & 0xFF), color]
            }
            index += length
        }
        output += [0x00, 0x00]
    }
    return output
}

var stream: [UInt8] = []
var composition = 0

for rect in rects {
    let showPTS = Int((rect.start * 90_000).rounded())
    let clearPTS = Int((rect.end * 90_000).rounded())
    let window = [UInt8(1), 0] + be16(rect.x) + be16(rect.y) + be16(rect.width) + be16(rect.height)

    // Epoch start with one object.
    var pcs = be16(canvasWidth) + be16(canvasHeight) + [0x10] + be16(composition) + [0x80, 0x00, 0x00, 0x01]
    pcs += be16(0) + [0x00, 0x00] + be16(rect.x) + be16(rect.y)
    composition += 1
    var pds: [UInt8] = [0x00, 0x00]
    for entry in palette { pds += [entry.id, entry.y, entry.cr, entry.cb, entry.alpha] }
    let rle = encodeRLE(pixels(width: rect.width, height: rect.height))
    precondition(rle.count + 11 <= 65_535, "object too large for one ODS segment")
    let ods = be16(0) + [0x00, 0xC0] + be24(rle.count + 4) + be16(rect.width) + be16(rect.height) + rle
    stream += segment(0x16, pts: showPTS, pcs)
    stream += segment(0x17, pts: showPTS, window)
    stream += segment(0x14, pts: showPTS, pds)
    stream += segment(0x15, pts: showPTS, ods)
    stream += segment(0x80, pts: showPTS, [])

    // A composition with no objects clears the screen.
    let clear = be16(canvasWidth) + be16(canvasHeight) + [0x10] + be16(composition) + [0x00, 0x00, 0x00, 0x00]
    composition += 1
    stream += segment(0x16, pts: clearPTS, clear)
    stream += segment(0x17, pts: clearPTS, window)
    stream += segment(0x80, pts: clearPTS, [])
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-pgs.swift <out.sup> <out-rects.json>\n".utf8))
    exit(2)
}

struct RectsFile: Encodable {
    struct Entry: Encodable {
        var start: Double
        var end: Double
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }
    var canvasWidth: Int
    var canvasHeight: Int
    var rects: [Entry]
}

let report = RectsFile(
    canvasWidth: canvasWidth,
    canvasHeight: canvasHeight,
    rects: rects.map { .init(start: $0.start, end: $0.end, x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
encoder.keyEncodingStrategy = .convertToSnakeCase
do {
    try Data(stream).write(to: URL(filePath: arguments[1]))
    try encoder.encode(report).write(to: URL(filePath: arguments[2]))
} catch {
    FileHandle.standardError.write(Data("make-pgs: \(error)\n".utf8))
    exit(1)
}
