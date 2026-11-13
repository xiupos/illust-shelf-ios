// The app: the state the screens share (`Shelf`), the folder and its bookmark, the tabs, and
// navigation. The counterpart of src/main.rs of the GTK app

import SwiftUI
import UniformTypeIdentifiers

@main
struct IllustShelfApp: App {
    @State private var shelf = Shelf()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(shelf)
        }
    }
}

// MARK: - Shelf

/// The library and how it is loading. One for the app
@MainActor
@Observable
final class Shelf {
    private(set) var library = Library()
    private(set) var tags: [Tag] = []
    /// The chosen folder, while the app has access to it
    private(set) var folder: URL?
    private(set) var loading = false
    /// Counts the loads that finished, so that galleries refresh after a reload, and only then
    private(set) var generation = 0
    /// Shown in an alert
    var error: String?
    /// Whether the folder picker is shown
    var choosingFolder = false

    private var started = 0
    /// Names the folder of thumbnails, which is made new for each chosen folder
    private var cacheID: String
    private let defaults = UserDefaults.standard

    init() {
        cacheID = defaults.string(forKey: "cacheID") ?? UUID().uuidString
        defaults.set(cacheID, forKey: "cacheID")
        guard let bookmark = defaults.data(forKey: "folder") else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) {
            open(url, remember: stale)
        } else {
            error = "The folder could not be found. Choose it again."
        }
    }

    /// Opens a folder the user chose, in place of the current one
    func choose(_ url: URL) {
        folder?.stopAccessingSecurityScopedResource()
        try? FileManager.default.removeItem(at: thumbs)
        cacheID = UUID().uuidString
        defaults.set(cacheID, forKey: "cacheID")
        library = Library()
        tags = []
        open(url, remember: true)
    }

    private func open(_ url: URL, remember: Bool) {
        // false for folders the app may read anyway, such as its own
        _ = url.startAccessingSecurityScopedResource()
        folder = url
        if remember, let bookmark = try? url.bookmarkData() {
            defaults.set(bookmark, forKey: "folder")
        }
        Task { await reload() }
    }

    /// Scans the folder again. A load overtaken by a newer one is dropped
    func reload() async {
        guard let folder else { return }
        started += 1
        let mine = started
        loading = true
        let library = await Task.detached { Library(loading: folder) }.value
        guard mine == started else { return }
        self.library = library
        tags = library.tags()
        loading = false
        generation += 1
    }

    /// Re-reads the image's sidecar, before it is edited
    func refresh(_ id: String) {
        library.refresh(id)
    }

    /// Saves the image's metadata, if it changed. The tags in use follow
    func save(_ id: String, _ meta: Meta) {
        guard let item = library.get(id), item.editable else { return }
        do {
            try library.save(id, meta, now: timestamp())
            tags = library.tags()
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
    }

    /// Where the image's thumbnail is cached
    func thumb(_ id: String) -> URL {
        thumbs.appendingPathComponent(sha1(id) + ".jpg")
    }

    private var thumbs: URL {
        URL.cachesDirectory.appendingPathComponent("thumbs/\(cacheID)")
    }
}

// MARK: - Tabs

/// Library, Tags, and Search, as in Photos. Before a folder is chosen, an invitation to choose one
struct RootView: View {
    @Environment(Shelf.self) private var shelf

    var body: some View {
        @Bindable var shelf = shelf
        Group {
            if shelf.folder == nil {
                ContentUnavailableView {
                    Label("Illust Shelf", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Choose a folder of illustrations to browse and tag.")
                } actions: {
                    Button("Choose Folder…") { shelf.choosingFolder = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                TabView {
                    Tab("Library", systemImage: "photo.on.rectangle") {
                        Stack { LibraryPage() }
                    }
                    Tab("Tags", systemImage: "tag") {
                        Stack { TagsPage() }
                    }
                    Tab(role: .search) {
                        Stack { SearchPage() }
                    }
                }
            }
        }
        .fileImporter(isPresented: $shelf.choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): shelf.choose(url)
            case .failure(let error): shelf.error = error.localizedDescription
            }
        }
        .alert("Error", isPresented: Binding { shelf.error != nil } set: { if !$0 { shelf.error = nil } }) {
            Button("OK") {}
        } message: {
            Text(shelf.error ?? "")
        }
    }
}

// MARK: - Navigation

/// The pages a tab can show above its first
enum Route: Hashable {
    /// An image, in the gallery `ids` it was opened from
    case image(ids: [String], id: String)
    /// A tag's gallery
    case tag(String)
    /// All the tags of a namespace
    case namespace(String)
}

/// A tab's pages. Each tab has its own
@MainActor
@Observable
final class Router {
    var path: [Route] = []

    /// Whether the page on top is an image's
    var showsImage: Bool {
        if case .image = path.last { true } else { false }
    }

    func open(_ route: Route) {
        path.append(route)
    }

    /// Opens the tag's gallery in place of the pages above the tab's first: of the image the tag
    /// was chosen on
    func open(tag: String) {
        path = [.tag(tag)]
    }
}

/// A tab's navigation stack. Gives its pages the `Router`, and the namespace in which a thumbnail
/// grows into its image
struct Stack<Root: View>: View {
    @ViewBuilder let root: Root
    @State private var router = Router()
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $router.path) {
            root.navigationDestination(for: Route.self) { route in
                switch route {
                case .image(let ids, let id): Viewer(ids: ids, start: id)
                case .tag(let tag): TagPage(tag: tag)
                case .namespace(let namespace): NamespacePage(namespace: namespace)
                }
            }
        }
        // Hidden here, by what the stack shows, and not by the viewer: a bar that a page hides
        // does not always come back when the page is left with the zoom transition
        .toolbarVisibility(router.showsImage ? .hidden : .visible, for: .tabBar)
        .environment(router)
        .environment(\.zoomNamespace, zoom)
    }
}

// MARK: - Settings

/// Thumbnail sizes
enum TileSize: String, CaseIterable {
    case small, medium, large

    var name: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// The smallest width of a tile, in points
    var minimum: CGFloat {
        switch self {
        case .small: 80
        case .medium: 120
        case .large: 180
        }
    }
}

/// The Library tab's menu: the thumbnail size and the folder
struct LibraryMenu: View {
    @Environment(Shelf.self) private var shelf
    @AppStorage("tileSize") private var tileSize = TileSize.medium

    var body: some View {
        Menu("More", systemImage: "ellipsis") {
            Picker("Thumbnail Size", selection: $tileSize) {
                ForEach(TileSize.allCases, id: \.self) { Text($0.name) }
            }
            Section {
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await shelf.reload() }
                }
                Button("Choose Folder…", systemImage: "folder") { shelf.choosingFolder = true }
            }
        }
    }
}
