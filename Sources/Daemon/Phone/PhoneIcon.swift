import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A project's icon for the phone's page: the largest picture in the file (an .icns or .ico holds several), drawn
/// into `side` pixels as a PNG. Nil for what isn't a picture ImageIO reads, and for a wordmark (much wider than tall),
/// which the sidebar doesn't show either.
enum PhoneIcon {
    static func png(from data: Data, side: Int = 128) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        func width(_ index: Int) -> Int {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        }
        guard let largest = (0..<CGImageSourceGetCount(source)).max(by: { width($0) < width($1) }) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, largest, options as CFDictionary),
            image.width <= image.height * 2
        else { return nil }
        let out = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
