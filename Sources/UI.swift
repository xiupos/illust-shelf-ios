// Shared views and the thumbnails. The counterpart of src/ui.rs of the GTK app

import CryptoKit
import ImageIO
import SwiftUI

/// A square tile with the image's thumbnail, made when it first comes into view
struct Thumbnail: View {
    let file: URL
    let thumb: URL
    @State private var image: UIImage?

    var body: some View {
        Color(uiColor: .secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: file) {
                image = await Thumbnails.image(of: file, cachedAt: thumb)
            }
    }
}

/// Thumbnails are center-cropped squares, at most 512 px, saved as JPEG in the app's caches, and
/// remade when older than the image. EXIF orientation is applied. Made off the main thread, as
/// many at a time as there are cores
enum Thumbnails {
    static let size = 512
    private static let memory = NSCache<NSURL, UIImage>()

    static func image(of file: URL, cachedAt thumb: URL) async -> UIImage? {
        if let hit = memory.object(forKey: thumb as NSURL) { return hit }
        guard !Task.isCancelled else { return nil }
        let image = cached(file, thumb) ?? make(file, thumb)
        if let image { memory.setObject(image, forKey: thumb as NSURL) }
        return image
    }

    private static func cached(_ file: URL, _ thumb: URL) -> UIImage? {
        let mtime = { (url: URL) in try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        guard let made = mtime(thumb), let changed = mtime(file), made >= changed else { return nil }
        return UIImage(contentsOfFile: thumb.path)
    }

    private static func make(_ file: URL, _ thumb: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        // The short side becomes at most `size`, for the square to be cut from it
        let long = max(width, height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(long, size * long / min(width, height)),
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        // Center-cropped, onto white: JPEG has no alpha
        let side = min(scaled.width, scaled.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let square = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let x = CGFloat(side - scaled.width) / 2
            let y = CGFloat(side - scaled.height) / 2
            UIImage(cgImage: scaled).draw(in: CGRect(x: x, y: y, width: CGFloat(scaled.width), height: CGFloat(scaled.height)))
        }
        if let jpeg = square.jpegData(compressionQuality: 0.85) {
            try? FileManager.default.createDirectory(at: thumb.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? jpeg.write(to: thumb, options: .atomic)
        }
        return square
    }
}

/// The SHA-1 of a text, in hex: names a thumbnail after an image's ID
func sha1(_ text: String) -> String {
    Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
