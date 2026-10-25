// Usage: shot-stats <png> [x y w h]
//        shot-stats <png> --ink [x y w h]
//        shot-stats <png> --patch x y w h
// The first form prints "<width> <height> <mean> <stddev> <min> <max>" for the luminance
// (Rec. 709, 0 to 255) of the whole image, or of the pixel rectangle x y w h (origin top-left).
// Used by accept.sh to check that background screenshots are the right size, not blank and differ
// between light and dark.
// The second form prints one number: the count of pixels in the rectangle (default the whole
// image) with luma at least 235 that have a pixel with luma at most 40 within 4 px, which is how
// white subtitle text with a dark outline looks (design 14 and 16, M2 acceptance 5).
// The third form prints "<r> <g> <b>": the mean sRGB value (0 to 255, one decimal place of
// precision is kept) of the rectangle, which is how the HDR shots are checked numerically
// (design 7.7 and 14: the 203-nit patch of hdr-badge must be 190 to 250).
import CoreGraphics
import Foundation
import ImageIO

let inkRadius = 4
let inkBright = 235.0
let inkDark = 40.0

/// Bright pixels with a dark pixel inside the (2 * radius + 1) square around them. A summed-area
/// table of the dark pixels makes each lookup constant time.
func inkCount(pixels: [UInt8], width: Int, height: Int) -> Int {
    var luma = [Double](repeating: 0, count: width * height)
    for index in 0..<(width * height) {
        let base = index * 4
        luma[index] = 0.2126 * Double(pixels[base]) + 0.7152 * Double(pixels[base + 1]) + 0.0722 * Double(pixels[base + 2])
    }
    let stride = width + 1
    var table = [Int32](repeating: 0, count: stride * (height + 1))
    for y in 0..<height {
        var row: Int32 = 0
        for x in 0..<width {
            if luma[y * width + x] <= inkDark { row += 1 }
            table[(y + 1) * stride + x + 1] = table[y * stride + x + 1] + row
        }
    }
    var count = 0
    for y in 0..<height {
        let top = max(0, y - inkRadius)
        let bottom = min(height, y + inkRadius + 1)
        for x in 0..<width where luma[y * width + x] >= inkBright {
            let left = max(0, x - inkRadius)
            let right = min(width, x + inkRadius + 1)
            let dark = table[bottom * stride + right] - table[top * stride + right]
                - table[bottom * stride + left] + table[top * stride + left]
            if dark > 0 { count += 1 }
        }
    }
    return count
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var args = CommandLine.arguments
var inkMode = false
var patchMode = false
if let flag = args.firstIndex(of: "--ink") {
    inkMode = true
    args.remove(at: flag)
}
if let flag = args.firstIndex(of: "--patch") {
    patchMode = true
    args.remove(at: flag)
}
guard args.count == 6 || (args.count == 2 && !patchMode) else {
    fail(
        "usage: shot-stats <png> [x y w h]\n       shot-stats <png> --ink [x y w h]\n       shot-stats <png> --patch x y w h",
        code: 2
    )
}
let url = URL(fileURLWithPath: args[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("shot-stats: cannot read \(args[1])", code: 1)
}
var region = CGRect(x: 0, y: 0, width: image.width, height: image.height)
if args.count == 6 {
    let numbers = args[2...5].compactMap { Double($0) }
    guard numbers.count == 4 else {
        fail("shot-stats: rectangle must be four numbers", code: 2)
    }
    region = region.intersection(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]).integral)
}
guard !region.isEmpty, let cropped = image.cropping(to: region) else {
    fail("shot-stats: empty region", code: 1)
}
let width = cropped.width
let height = cropped.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
guard drawn else {
    fail("shot-stats: cannot read pixels", code: 1)
}
if inkMode {
    print(inkCount(pixels: pixels, width: width, height: height))
    exit(0)
}
if patchMode {
    var red = 0.0
    var green = 0.0
    var blue = 0.0
    for index in 0..<(width * height) {
        let base = index * 4
        red += Double(pixels[base])
        green += Double(pixels[base + 1])
        blue += Double(pixels[base + 2])
    }
    let total = Double(width * height)
    print(String(format: "%.2f %.2f %.2f", red / total, green / total, blue / total))
    exit(0)
}
var sum = 0.0
var sumSquares = 0.0
var low = 255.0
var high = 0.0
let count = Double(width * height)
for index in 0..<(width * height) {
    let base = index * 4
    let luma = 0.2126 * Double(pixels[base]) + 0.7152 * Double(pixels[base + 1]) + 0.0722 * Double(pixels[base + 2])
    sum += luma
    sumSquares += luma * luma
    low = min(low, luma)
    high = max(high, luma)
}
let mean = sum / count
let deviation = (max(sumSquares / count - mean * mean, 0)).squareRoot()
print("\(image.width) \(image.height) " + String(format: "%.3f %.3f %.1f %.1f", mean, deviation, low, high))
