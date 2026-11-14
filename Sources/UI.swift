// Views that the pages share: thumbnails, the zoom transition, the pager, the zoomable image

import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Thumbnails

/// A square tile with the image's thumbnail, made when it first comes into view
struct Thumbnail: View {
    let id: String
    @Environment(Shelf.self) private var shelf
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
            .contentShape(.rect)
            .task(id: id) {
                image = await Thumbnails.image(of: shelf.library.file(id), cachedAt: shelf.thumb(id))
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
        guard let pixels = imageSize(file), pixels.width > 0, pixels.height > 0 else { return nil }
        // The short side becomes at most `size`, for the square to be cut from it
        let long = Int(max(pixels.width, pixels.height))
        let short = Int(min(pixels.width, pixels.height))
        guard let scaled = decode(file, maxPixels: min(long, size * long / short)) else { return nil }

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

// MARK: - The zoom transition

extension EnvironmentValues {
    /// The namespace of a tab's zoom transitions: see `Stack`
    @Entry var zoomNamespace: Namespace.ID?
}

extension View {
    /// Marks a thumbnail as what the image's page grows out of, and shrinks back into
    func zoomSource(_ id: String) -> some View {
        modifier(ZoomTransition(id: id, isSource: true))
    }

    /// Makes a page open by growing out of the thumbnail of the image it shows
    func zoomDestination(_ id: String) -> some View {
        modifier(ZoomTransition(id: id, isSource: false))
    }
}

private struct ZoomTransition: ViewModifier {
    let id: String
    let isSource: Bool
    @Environment(\.zoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace, isSource {
            content.matchedTransitionSource(id: id, in: namespace)
        } else if let namespace {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

// MARK: - Deleting

extension View {
    /// Asks before `delete` is done, from the view that this is on
    func confirmsDeleting(_ isPresented: Binding<Bool>, delete: @escaping () -> Void) -> some View {
        confirmationDialog("Delete Image", isPresented: isPresented) {
            Button("Delete Image", role: .destructive, action: delete)
        } message: {
            Text("The image and its title, tags, and note will be deleted from the folder. This can't be undone.")
        }
    }
}

// MARK: - Images

/// The image to show on its page: at most `maxPixels` on its long side, which is enough to zoom
/// into and keeps the pages next to it in memory. EXIF orientation is applied
func loadImage(_ file: URL, maxPixels: Int = 3072) async -> UIImage? {
    decode(file, maxPixels: maxPixels).map { UIImage(cgImage: $0) }
}

/// The image as PNG data, turned by its EXIF orientation: for adding an image of a kind the
/// library does not keep
func pngData(_ file: URL) -> Data? {
    let data = NSMutableData()
    guard let size = imageSize(file),
          let image = decode(file, maxPixels: Int(max(size.width, size.height))),
          let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

/// The image's size in pixels, as shown: turned by its EXIF orientation. Reads only the header
func imageSize(_ file: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int,
          let height = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let turned = ((props[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
    return turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
}

/// The image's pixels, scaled down to at most `maxPixels` on the long side and turned by its EXIF
/// orientation
private func decode(_ file: URL, maxPixels: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

// MARK: - The pager

/// Pages to swipe through, one for each ID, made as they are needed. A UIPageViewController: it
/// keeps to a page when its size changes, which a paging ScrollView does not
struct Pager<Page: View>: UIViewControllerRepresentable {
    let ids: [String]
    @Binding var current: String
    @ViewBuilder let page: (String) -> Page

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                         options: [.interPageSpacing: 20])
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .clear
        pager.setViewControllers([context.coordinator.controller(for: current)], direction: .forward, animated: false)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        // `current` was set from outside, not by a swipe: its page takes the place of the one
        // shown, and of those kept ready next to it
        if context.coordinator.id(of: pager.viewControllers?.first) != current {
            pager.setViewControllers([context.coordinator.controller(for: current)], direction: .forward, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: Pager
        /// The ID each page shows
        private let shown = NSMapTable<UIViewController, NSString>.weakToStrongObjects()

        init(_ parent: Pager) {
            self.parent = parent
        }

        func controller(for id: String) -> UIViewController {
            let controller = UIHostingController(rootView: parent.page(id))
            // The pages are full screen, under the bars
            controller.safeAreaRegions = []
            controller.view.backgroundColor = .clear
            shown.setObject(id as NSString, forKey: controller)
            return controller
        }

        func id(of controller: UIViewController?) -> String? {
            controller.flatMap { shown.object(forKey: $0) } as String?
        }

        private func neighbour(of controller: UIViewController, by step: Int) -> UIViewController? {
            guard let id = id(of: controller), let next = parent.ids.neighbour(of: id, by: step) else { return nil }
            return self.controller(for: next)
        }

        func pageViewController(_ pager: UIPageViewController,
                                viewControllerBefore controller: UIViewController) -> UIViewController? {
            neighbour(of: controller, by: -1)
        }

        func pageViewController(_ pager: UIPageViewController,
                                viewControllerAfter controller: UIViewController) -> UIViewController? {
            neighbour(of: controller, by: 1)
        }

        func pageViewController(_ pager: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            if completed, let id = id(of: pager.viewControllers?.first) {
                parent.current = id
            }
        }
    }
}

extension Array where Element: Equatable {
    /// The element `step` places from `element`, if there is one
    func neighbour(of element: Element, by step: Int) -> Element? {
        guard let index = firstIndex(of: element), indices.contains(index + step) else { return nil }
        return self[index + step]
    }
}

// MARK: - The zoomable image

/// An image that fits its space and zooms with a pinch or a double tap, in a UIScrollView: the
/// pages of the `Pager` around it scroll when it is not zoomed or is at its edge, as in Photos
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
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

        override init(frame: CGRect) {
            super.init(frame: frame)
            minimumZoomScale = 1
            maximumZoomScale = 6
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            decelerationRate = .fast
            // The image runs under the viewer's bars: no blur at its top
            topEdgeEffect.isHidden = true
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        /// Not zoomed, the image fits the view, still
        override func layoutSubviews() {
            super.layoutSubviews()
            guard zoomScale == minimumZoomScale, let size = imageView.image?.size,
                  size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0
            else { return center() }
            let fit = min(bounds.width / size.width, bounds.height / size.height)
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

        /// Keeps an image smaller than the view in its middle
        func center() {
            let dx = max(0, (bounds.width - contentSize.width) / 2)
            let dy = max(0, (bounds.height - contentSize.height) / 2)
            contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
        }
    }
}
