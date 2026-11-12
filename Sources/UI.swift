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

/// The image to show on its page: at most `maxPixels` on its long side, which is enough to zoom
/// into and keeps the pages next to it in memory. EXIF orientation is applied
func loadImage(_ file: URL, maxPixels: Int = 3072) async -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
}

/// An image that fits its space and zooms with a pinch or a double tap, in a UIScrollView: the
/// pages around it scroll when it is not zoomed or is at its edge, as in Photos
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    /// The image is fitted inside these, and can be scrolled out from under them when zoomed
    let insets: UIEdgeInsets
    let onTap: () -> Void

    func makeUIView(context: Context) -> ZoomView {
        let view = ZoomView()
        view.delegate = context.coordinator
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: ZoomView, context: Context) {
        context.coordinator.onTap = onTap
        view.fitInsets = insets
        if view.imageView.image !== image {
            view.imageView.image = image
            view.setZoomScale(1, animated: false)
            view.setNeedsLayout()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var onTap: () -> Void

        init(onTap: @escaping () -> Void) {
            self.onTap = onTap
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomView)?.center()
        }

        @objc func tapped() {
            onTap()
        }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? ZoomView else { return }
            if view.zoomScale > 1 {
                view.setZoomScale(1, animated: true)
            } else {
                let point = recognizer.location(in: view.imageView)
                let size = CGSize(width: view.bounds.width / 2.5, height: view.bounds.height / 2.5)
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                view.zoom(to: rect, animated: true)
            }
        }
    }

    final class ZoomView: UIScrollView {
        let imageView = UIImageView()
        var fitInsets = UIEdgeInsets.zero {
            didSet { if fitInsets != oldValue { setNeedsLayout() } }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            minimumZoomScale = 1
            maximumZoomScale = 6
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            decelerationRate = .fast
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        /// Not zoomed, the image fits inside `fitInsets`, still
        override func layoutSubviews() {
            super.layoutSubviews()
            let area = bounds.inset(by: fitInsets)
            guard zoomScale == minimumZoomScale, let size = imageView.image?.size,
                  size.width > 0, size.height > 0, area.width > 0, area.height > 0
            else { return center() }
            let fit = min(area.width / size.width, area.height / size.height)
            let fitted = CGSize(width: size.width * fit, height: size.height * fit)
            if imageView.frame.size != fitted {
                imageView.frame = CGRect(origin: .zero, size: fitted)
                contentSize = fitted
            }
            center()
            if !isTracking && !isDecelerating && !isZooming {
                contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
            }
        }

        /// Keeps an image smaller than the area inside `fitInsets` in its middle
        func center() {
            let area = bounds.inset(by: fitInsets)
            let dx = max(0, (area.width - contentSize.width) / 2)
            let dy = max(0, (area.height - contentSize.height) / 2)
            contentInset = UIEdgeInsets(top: fitInsets.top + dy, left: fitInsets.left + dx,
                                        bottom: fitInsets.bottom + dy, right: fitInsets.right + dx)
        }
    }
}

/// The SHA-1 of a text, in hex: names a thumbnail after an image's ID
func sha1(_ text: String) -> String {
    Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
