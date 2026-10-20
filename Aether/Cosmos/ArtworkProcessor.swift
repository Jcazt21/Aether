import CoreGraphics
import Foundation
import ImageIO
import TagKit
import UniformTypeIdentifiers

nonisolated enum ArtworkProcessor {
    /// Keeps JPEG/PNG ≤ 2 MB and ≤ 1500 px as-is; otherwise re-encodes to a 1400 px JPEG (q 0.9).
    static func prepare(_ data: Data) -> TrackTags.Artwork? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let isJPEG = type == UTType.jpeg.identifier
        let isPNG = type == UTType.png.identifier
        if (isJPEG || isPNG), data.count <= 2_000_000, max(width, height) <= 1500 {
            return TrackTags.Artwork(data: data, mimeType: isJPEG ? "image/jpeg" : "image/png")
        }
        guard let image = thumbnail(data, maxPixel: 1400) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return TrackTags.Artwork(data: out as Data, mimeType: "image/jpeg")
    }

    /// Decodes straight to display size — never a full-resolution bitmap in memory.
    static func thumbnail(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
