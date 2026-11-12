// The app: the state the screens share (`Shelf`), the folder and its bookmark, and the top page.
// The counterpart of src/main.rs of the GTK app

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

    /// Where the image's thumbnail is cached
    func thumb(_ id: String) -> URL {
        thumbs.appendingPathComponent(sha1(id) + ".jpg")
    }

    private var thumbs: URL {
        URL.cachesDirectory.appendingPathComponent("thumbs/\(cacheID)")
    }
}

/// The pages above the top page
enum Page: Hashable {
    /// A tag's gallery
    case tag(String)
    /// An image, in the gallery `ids` it was opened from
    case image(ids: [String], index: Int)
}

/// Thumbnail sizes: the smallest width of a tile, in points
enum Zoom: Double, CaseIterable {
    case small = 80, medium = 120, large = 160

    var name: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

struct RootView: View {
    @Environment(Shelf.self) private var shelf
    @AppStorage("zoom") private var zoom = Zoom.medium.rawValue
    @State private var path: [Page] = []
    @State private var query = ""
    @State private var choosing = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Illust Shelf")
                .toolbar { menu }
                .navigationDestination(for: Page.self) { page in
                    switch page {
                    case .image(let ids, let index): Detail(ids: ids, index: index)
                    case .tag: EmptyView()
                    }
                }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
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

    @ViewBuilder
    private var content: some View {
        if shelf.library.isEmpty && shelf.loading {
            ProgressView("Loading…")
        } else if shelf.library.isEmpty {
            ContentUnavailableView {
                Label("No Illustrations", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Choose a folder with images in it")
            } actions: {
                Button("Choose Folder…") { choosing = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            Gallery(tag: nil, query: query)
                .searchable(text: $query)
                .refreshable { await shelf.reload() }
        }
    }

    private var menu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker(selection: $zoom) {
                    ForEach(Zoom.allCases, id: \.self) { Text($0.name).tag($0.rawValue) }
                } label: {
                    Label("Thumbnail Size", systemImage: "square.grid.2x2")
                }
                .pickerStyle(.menu)
                Button("Choose Folder…", systemImage: "folder") { choosing = true }
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await shelf.reload() }
                }
                .disabled(shelf.folder == nil)
            } label: {
                Label("Menu", systemImage: "ellipsis")
            }
        }
    }
}
