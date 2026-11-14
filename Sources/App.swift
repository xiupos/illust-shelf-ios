// The app: the state the screens share (`Shelf`), the folder and its bookmark, the tabs, and
// navigation

import PhotosUI
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
    var showingAbout = false

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

    /// Copies the images into the folder, then reloads it. A file of another kind is added as a
    /// PNG if it decodes. `failed` counts images already lost on the way, for the error
    func add(files: [URL], failed: Int = 0) async {
        guard let folder else { return }
        let now = timestamp()
        let refused = await Task.detached {
            files.filter { file -> Bool in
                let scoped = file.startAccessingSecurityScopedResource()
                defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                do {
                    if isImage(file.lastPathComponent) {
                        _ = try importImage(into: folder, from: file, now: now)
                    } else if let png = pngData(file) {
                        _ = try importPNG(into: folder, png, now: now)
                    } else {
                        return true
                    }
                    return false
                } catch {
                    return true
                }
            }.count
        }.value
        switch failed + refused {
        case 0: break
        case 1: error = "An image could not be added."
        case let count: error = "\(count) images could not be added."
        }
        await reload()
    }

    /// Adds images picked from the photo library
    func add(photos: [PhotosPickerItem]) async {
        await add(photos) { photo, folder in
            guard let data = try? await photo.loadTransferable(type: Data.self) else { return nil }
            let type = photo.supportedContentTypes.first?.preferredFilenameExtension ?? "image"
            let file = folder.appendingPathComponent("\(UUID().uuidString).\(type)")
            return (try? data.write(to: file)) != nil ? file : nil
        }
    }

    /// Adds dropped or pasted images
    func add(providers: [NSItemProvider]) async {
        await add(providers, copying: copy(of:into:))
    }

    /// Adds images that have no file of their own: `copy` writes each into a temporary folder,
    /// which is removed after. One it makes no file of could not be added
    private func add<Source>(_ sources: [Source], copying copy: (Source, URL) async -> URL?) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("adding-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var files: [URL] = []
        for source in sources {
            if let file = await copy(source, folder) { files.append(file) }
        }
        await add(files: files, failed: sources.count - files.count)
    }

    /// Deletes the image and its sidecar. false if that fails
    @discardableResult
    func remove(_ id: String) -> Bool {
        do {
            try library.remove(id)
            tags = library.tags()
            return true
        } catch {
            self.error = "Could not delete: \(error.localizedDescription)"
            return false
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

/// The provider's image as a file in `folder`, with the extension of its kind
private func copy(of provider: NSItemProvider, into folder: URL) async -> URL? {
    await withCheckedContinuation { continuation in
        // The file is gone when this returns, so it is copied here
        _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { file, _ in
            guard let file else { return continuation.resume(returning: nil) }
            let copy = folder.appendingPathComponent("\(UUID().uuidString).\(file.pathExtension)")
            let copied = (try? FileManager.default.copyItem(at: file, to: copy)) != nil
            continuation.resume(returning: copied ? copy : nil)
        }
    }
}

// MARK: - Tabs

/// Library and Search, as in Photos. Before a folder is chosen, an invitation to choose one
struct RootView: View {
    @Environment(Shelf.self) private var shelf
    @Environment(\.horizontalSizeClass) private var sizeClass

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
                    // An ordinary tab where the tab bar is at the bottom, which a search tab would
                    // turn into its search field
                    if sizeClass == .regular {
                        Tab(role: .search) {
                            Stack { SearchPage() }
                        }
                    } else {
                        Tab("Search", systemImage: "magnifyingglass") {
                            Stack { SearchPage() }
                        }
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
        .sheet(isPresented: $shelf.showingAbout) { About() }
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
    /// A tag's gallery
    case tag(String)
    /// All the tags of a namespace
    case namespace(String)
}

/// An image to look at, and the gallery it was opened from
struct Viewing: Identifiable {
    let ids: [String]
    let id: String
}

/// A tab's pages, and the image shown over them. Each tab has its own
@MainActor
@Observable
final class Router {
    var path: [Route] = []
    var viewing: Viewing?

    /// Shows the image, to page through `ids` from
    func view(_ id: String, in ids: [String]) {
        viewing = Viewing(ids: ids, id: id)
    }

    /// Opens the tag's gallery in place of the image the tag was chosen on, and of the pages
    /// above the tab's first
    func open(tag: String) {
        viewing = nil
        path = [.tag(tag)]
    }
}

/// A tab's navigation stack, with the viewer over it. Gives its pages the `Router`, and the
/// namespace in which a thumbnail grows into its image
struct Stack<Root: View>: View {
    @ViewBuilder let root: Root
    @State private var router = Router()
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $router.path) {
            root.navigationDestination(for: Route.self) { route in
                switch route {
                case .tag(let tag): TagPage(tag: tag)
                case .namespace(let namespace): NamespacePage(namespace: namespace)
                }
            }
        }
        // Over the whole tab, bars and all, as Photos shows a photo. A page would have to hide
        // the tab bar
        .fullScreenCover(item: $router.viewing) { viewing in
            Viewer(ids: viewing.ids, start: viewing.id)
        }
        .environment(router)
        .environment(\.zoomNamespace, zoom)
    }
}

// MARK: - Settings

/// Thumbnail sizes, and the sizes of the tags' cards that go with them
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

    /// The width of a tag's card, in points
    var card: CGFloat {
        switch self {
        case .small: 100
        case .medium: 132
        case .large: 180
        }
    }
}

/// The Library tab's menu: thumbnail size, reloading, the folder, About
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
                .keyboardShortcut("r")
                Button("Choose Folder…", systemImage: "folder") { shelf.choosingFolder = true }
                    .keyboardShortcut("o")
            }
            Button("About Illust Shelf", systemImage: "info.circle") { shelf.showingAbout = true }
        }
    }
}

/// What the app is, and its version
private struct About: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    LabeledContent("License", value: "MIT")
                } footer: {
                    Text("Browse and organize illustrations with tags. The tags, sources, and notes are kept in a JSON file next to each image.")
                }
                Section {
                    Link("The illust-sidecar Format", destination: URL(string: "https://github.com/xiupos/illust-sidecar")!)
                }
            }
            .navigationTitle("Illust Shelf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Adding images

extension View {
    /// Gives a page the ways to add images: a + menu in its toolbar (the photo library, files,
    /// the clipboard), and dropping them on it
    func addsImages() -> some View {
        modifier(AddsImages())
    }
}

private struct AddsImages: ViewModifier {
    @Environment(Shelf.self) private var shelf
    @State private var pickingPhotos = false
    @State private var pickingFiles = false
    @State private var photos: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Add", systemImage: "plus") {
                        Button("Photo Library", systemImage: "photo.on.rectangle") { pickingPhotos = true }
                        Button("Files", systemImage: "folder") { pickingFiles = true }
                        Button("Paste", systemImage: "doc.on.clipboard", action: paste)
                            .keyboardShortcut("v")
                    }
                }
            }
            .photosPicker(isPresented: $pickingPhotos, selection: $photos, matching: .images)
            .onChange(of: photos) { _, picked in
                guard !picked.isEmpty else { return }
                photos = []
                Task { await shelf.add(photos: picked) }
            }
            .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.png, .jpeg, .webP, .gif],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let files): Task { await shelf.add(files: files) }
                case .failure(let error): shelf.error = error.localizedDescription
                }
            }
            .onDrop(of: [.image], isTargeted: nil) { providers in
                Task { await shelf.add(providers: providers) }
                return true
            }
    }

    private func paste() {
        if UIPasteboard.general.hasImages {
            let providers = UIPasteboard.general.itemProviders
            Task { await shelf.add(providers: providers) }
        } else {
            shelf.error = "There is no image on the clipboard."
        }
    }
}
