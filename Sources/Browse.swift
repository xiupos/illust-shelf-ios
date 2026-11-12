// Galleries, grids of thumbnails. The counterpart of src/browse.rs of the GTK app

import SwiftUI

/// The images with `tag` (all if nil) that match `query`. The list is made again only by a search,
/// a reload, or another tag, so that editing an image does not reorder or refilter it
struct Gallery: View {
    let tag: String?
    let query: String
    @Environment(Shelf.self) private var shelf
    @AppStorage("zoom") private var zoom = Zoom.medium.rawValue
    @State private var ids: [String] = []

    var body: some View {
        // Images removed since the list was made are left out
        let shown = ids.filter { shelf.library.get($0) != nil }
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: zoom), spacing: 2)], spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.element) { index, id in
                    NavigationLink(value: Page.image(ids: shown, index: index)) {
                        Thumbnail(file: shelf.library.file(id), thumb: shelf.thumb(id))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay {
            if shown.isEmpty && !query.trimmed.isEmpty {
                ContentUnavailableView.search(text: query.trimmed)
            }
        }
        .task(id: "\(shelf.generation) \(tag ?? "") \(query)") {
            ids = shelf.library.paths(tag: tag, query: query)
        }
    }
}
