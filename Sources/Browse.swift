// The pages that list things: galleries of images, and tags

import SwiftUI

// MARK: - Gallery

/// A grid of the images with `tag` (all if nil) that match `query`, under `header`. The list is
/// made again only by a search, a reload, or another tag, so that editing an image does not
/// reorder or refilter it
struct Gallery<Header: View>: View {
    let tag: String?
    let query: String
    /// Whether to say so when nothing matches `query`
    var noResults = true
    @ViewBuilder var header: Header

    @Environment(Shelf.self) private var shelf
    @Environment(Router.self) private var router
    @AppStorage("tileSize") private var tileSize = TileSize.medium
    @State private var ids: [String] = []
    /// The image the user is asked about deleting
    @State private var deleting: String?

    var body: some View {
        // Images removed since the list was made are left out
        let shown = ids.filter { shelf.library.get($0) != nil }
        ScrollView {
            header
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize.minimum), spacing: 2)], spacing: 2) {
                ForEach(shown, id: \.self) { id in
                    Button {
                        router.view(id, in: shown)
                    } label: {
                        Thumbnail(id: id)
                    }
                    .buttonStyle(.plain)
                    .zoomSource(id)
                    .contextMenu {
                        ShareLink(item: shelf.library.file(id))
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = id }
                    }
                    .confirmsDeleting(Binding { deleting == id } set: { if !$0 { deleting = nil } }) {
                        shelf.remove(id)
                    }
                }
            }
        }
        .overlay {
            if noResults && shown.isEmpty && !query.trimmed.isEmpty {
                ContentUnavailableView.search(text: query.trimmed)
            }
        }
        .task(id: Listing(generation: shelf.generation, tag: tag, query: query)) {
            ids = shelf.library.paths(tag: tag, query: query)
        }
    }

    /// What a gallery lists. It lists again when this changes
    private struct Listing: Equatable {
        let generation: Int
        let tag: String?
        let query: String
    }
}

extension Gallery where Header == EmptyView {
    init(tag: String?, query: String = "") {
        self.init(tag: tag, query: query) { EmptyView() }
    }
}

// MARK: - Library

/// The Library tab: every image, newest first
struct LibraryPage: View {
    @Environment(Shelf.self) private var shelf

    var body: some View {
        Group {
            if !shelf.library.isEmpty {
                Gallery(tag: nil)
            } else if shelf.loading {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label("No Illustrations", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("This folder has no images. Add some to it, or choose another folder.")
                } actions: {
                    Button("Choose Folder…") { shelf.choosingFolder = true }
                }
            }
        }
        .navigationTitle("Library")
        .toolbarTitleDisplayMode(.inlineLarge)
        .refreshable { await shelf.reload() }
        .addsImages()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { LibraryMenu() }
        }
    }
}

// MARK: - Tags

/// The Tags tab: a shelf of tags for each namespace
struct TagsPage: View {
    @Environment(Shelf.self) private var shelf

    var body: some View {
        let shelves = sections(shelf.tags)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(shelves) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        NavigationLink(value: Route.namespace(section.namespace)) {
                            HStack(spacing: 4) {
                                Text(verbatim: heading(section.namespace))
                                    .font(.title2.bold())
                                Image(systemName: "chevron.forward")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                        TagShelf(tags: section.tags)
                    }
                }
            }
            .padding(.vertical)
        }
        .overlay {
            if shelves.isEmpty {
                ContentUnavailableView("No Tags", systemImage: "tag",
                                       description: Text("Tags you add to illustrations appear here."))
            }
        }
        .navigationTitle("Tags")
        .toolbarTitleDisplayMode(.inlineLarge)
    }
}

/// A section's heading: the namespace with its first letter in upper case
private func heading(_ namespace: String) -> String {
    namespace.isEmpty ? "Other Tags" : namespace.prefix(1).uppercased() + namespace.dropFirst()
}

/// All the tags of a namespace: what a search for `<namespace>:` finds. Those without a namespace
/// for ""
struct NamespacePage: View {
    let namespace: String
    @Environment(Shelf.self) private var shelf

    var body: some View {
        let tags = namespace.isEmpty
            ? shelf.tags.filter { $0.namespace.isEmpty }
            : searchTags(shelf.tags, namespace + ":")
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: TagCard.width), spacing: 12, alignment: .top)], spacing: 20) {
                ForEach(tags) { TagCard(tag: $0) }
            }
            .padding()
        }
        .navigationTitle(heading(namespace))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A tag's gallery, with its own search
struct TagPage: View {
    let tag: String
    @State private var query = ""

    var body: some View {
        Gallery(tag: tag, query: query)
            .navigationTitle(tag)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query)
    }
}

/// Tags side by side, to scroll through
struct TagShelf: View {
    let tags: [Tag]
    var fullNames = false

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(tags) { tag in
                    TagCard(tag: tag, fullName: fullNames)
                        .frame(width: TagCard.width)
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
    }
}

/// A tag, as an album is shown in Photos: its cover, its name, and the number of its images
struct TagCard: View {
    static let width: CGFloat = 132

    let tag: Tag
    /// With the namespace, where tags of several are shown together
    var fullName = false

    var body: some View {
        NavigationLink(value: Route.tag(tag.name)) {
            VStack(alignment: .leading, spacing: 2) {
                Thumbnail(id: tag.cover)
                    .clipShape(.rect(cornerRadius: 10))
                    .padding(.bottom, 4)
                Text(verbatim: fullName ? tag.name : tag.short)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(tag.count, format: .number)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search

/// The Search tab: the tags and the images that match
struct SearchPage: View {
    @Environment(Shelf.self) private var shelf
    @State private var query = ""

    var body: some View {
        let text = query.trimmed
        let tags = text.isEmpty ? [] : searchTags(shelf.tags, text)
        Group {
            if text.isEmpty {
                ContentUnavailableView("Search", systemImage: "magnifyingglass",
                                       description: Text("Find illustrations by title, note, or tag."))
            } else {
                Gallery(tag: nil, query: query, noResults: tags.isEmpty) {
                    if !tags.isEmpty {
                        TagShelf(tags: tags, fullNames: true)
                            .padding(.vertical)
                    }
                }
            }
        }
        .navigationTitle("Search")
        .toolbarTitleDisplayMode(.inlineLarge)
        .searchable(text: $query, prompt: "Titles, Notes, and Tags")
        .textInputAutocapitalization(.never)
    }
}
