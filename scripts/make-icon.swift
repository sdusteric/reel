// swift make-icon.swift out.png : placeholder 1024x1024 app icon (dark rounded square, white play glyph)
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("make-icon: cannot create bitmap\n".utf8))
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

// Apple icon grid: an 824 point shape centred in the 1024 canvas.
let shape = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 184, yRadius: 184)
NSGradient(
    starting: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.27, alpha: 1),
    ending: NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)
)?.draw(in: shape, angle: -90)

// Play triangle, nudged right so its centroid sits in the middle of the square.
NSColor.white.setFill()
let play = NSBezierPath()
play.move(to: NSPoint(x: 410, y: 700))
play.line(to: NSPoint(x: 410, y: 324))
play.line(to: NSPoint(x: 736, y: 512))
play.close()
play.lineJoinStyle = .round
play.lineWidth = 36
play.fill()
play.stroke()
NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("make-icon: PNG encoding failed\n".utf8))
    exit(1)
}
do {
    try data.write(to: URL(fileURLWithPath: out))
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
    exit(1)
}
