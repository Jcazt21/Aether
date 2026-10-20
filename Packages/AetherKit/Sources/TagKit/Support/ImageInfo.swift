import Foundation
import ImageIO

enum ImageInfo {
    static func pixelSize(of data: Data) -> (width: UInt32, height: UInt32)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (UInt32(w), UInt32(h))
    }
}
