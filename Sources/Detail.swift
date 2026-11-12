// One image, with previous / next through the gallery it was opened from. The counterpart of
// src/detail.rs of the GTK app

import SwiftUI

struct Detail: View {
    /// The gallery the image was opened from
    let ids: [String]
    @State private var current: String
    @State private var position: ScrollPosition
    @State private var barsHidden = false
    @Environment(Shelf.self) private var shelf

    init(ids: [String], index: Int) {
        self.ids = ids
        _current = State(initialValue: ids[index])
        _position = State(initialValue: ScrollPosition(id: ids[index]))
    }

    var body: some View {
        // The pages are full screen, so that the image can use it all while the bars are hidden.
        // While they are shown, the image fits between them. The reader keeps to the safe area,
        // so that it can tell where the bars are: one that ignores it is told of no insets
        GeometryReader { geometry in
            let safe = geometry.safeAreaInsets
            let width = geometry.size.width + safe.leading + safe.trailing
            let height = geometry.size.height + safe.top + safe.bottom
            let insets = barsHidden
                ? UIEdgeInsets.zero
                : UIEdgeInsets(top: safe.top, left: safe.leading, bottom: safe.bottom, right: safe.trailing)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(ids, id: \.self) { id in
                        ImagePage(file: shelf.library.file(id), insets: insets) {
                            withAnimation { barsHidden.toggle() }
                        }
                        .frame(width: width, height: height)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition($position)
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.5) { visible in
                if let id = visible.first { current = id }
            }
            .ignoresSafeArea()
        }
        .background(barsHidden ? Color.black : Color(uiColor: .systemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(barsHidden ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(barsHidden)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shelf.library.file(current))
            }
        }
    }

    /// The image's title, or its file name
    private var title: String {
        let title = shelf.library.get(current)?.meta.title ?? ""
        return title.isEmpty ? String(current.split(separator: "/").last ?? "") : title
    }
}

/// One page: the image, decoded off the main thread, to zoom into
private struct ImagePage: View {
    let file: URL
    /// Where the bars are, which the image is fitted between
    let insets: UIEdgeInsets
    let onTap: () -> Void
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image, insets: insets, onTap: onTap)
            } else if failed {
                ContentUnavailableView("Cannot Show the Image", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView()
            }
        }
        .task(id: file) {
            image = await loadImage(file)
            failed = image == nil
        }
    }
}
