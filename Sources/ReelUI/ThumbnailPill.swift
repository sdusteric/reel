import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// The seek-bar hover container with a thumbnail (design 9.4, mockup png/05 and png/06): a 12 pt
/// radius material with 4 pt padding, a 192 pt wide image with 8 pt radius and the time on a 22 pt
/// row under it.
struct ThumbnailPill: View {
    static let imageWidth: CGFloat = 192
    static let padding: CGFloat = 4
    static let timeRowHeight: CGFloat = 22
    static let cornerRadius: CGFloat = 12
    static let imageRadius: CGFloat = 8
    /// The bottom edge sits this far above the controller's top edge.
    static let gap: CGFloat = 8

    static var width: CGFloat { imageWidth + padding * 2 }

    let image: CGImage
    let time: String

    /// 192 x 108 for 16:9; the height follows the video aspect, clamped to 80 to 144 pt.
    static func imageHeight(width: Int, height: Int) -> CGFloat {
        guard width > 0, height > 0 else { return 108 }
        return min(max((imageWidth * CGFloat(height) / CGFloat(width)).rounded(), 80), 144)
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: ThumbnailPill.imageWidth, height: ThumbnailPill.imageHeight(width: image.width, height: image.height))
                .clipShape(RoundedRectangle(cornerRadius: ThumbnailPill.imageRadius, style: .continuous))
            Text(time)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.primary.opacity(0.9))
                .frame(height: ThumbnailPill.timeRowHeight)
        }
        .padding(ThumbnailPill.padding)
        .continuousSurface(radius: ThumbnailPill.cornerRadius, shadow: .small)
    }
}

/// JPEG thumbnails from the engine as `CGImage`s.
nonisolated enum ThumbnailDecoder {
    static func image(from jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
