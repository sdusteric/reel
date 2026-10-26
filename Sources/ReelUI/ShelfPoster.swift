import CoreGraphics
import Foundation
import ImageIO
import ReelCore
import UniformTypeIdentifiers

/// The Shelf preview: a JPEG at most 240 px wide and 30 KB.
enum ShelfPoster {
    static func jpeg(from image: CGImage) -> Data? {
        let width = ShelfStatusWriter.maxPosterWidth
        let scaled = image.width > width ? resized(image, width: width) : image
        guard let scaled else { return nil }
        for quality in stride(from: 0.8, through: 0.2, by: -0.15) {
            if let data = encode(scaled, quality: quality), data.count <= ShelfStatusWriter.maxPosterBytes { return data }
        }
        return nil
    }

    private static func encode(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func resized(_ image: CGImage, width: Int) -> CGImage? {
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
