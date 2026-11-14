// One image: the viewer, which pages through the gallery the image was opened from, and the Info
// panel, which edits its sidecar

import SwiftUI

// MARK: - Viewer

/// The images of a gallery, one at a time, as Photos shows them: swipe for the next, pinch or
/// double tap to zoom, tap to hide the buttons. Shown over the tab, with a stack of its own for
/// its toolbar
struct Viewer: View {
    /// The gallery the image was opened from, less the images deleted here
    @State private var ids: [String]
    @State private var current: String
    /// Whether the bars are hidden, leaving the image alone on the screen
    @State private var hidden = false
    @State private var showsInfo = false
    @State private var deleting = false
    @Environment(Shelf.self) private var shelf
    @Environment(\.dismiss) private var dismiss

    init(ids: [String], start: String) {
        _ids = State(initialValue: ids)
        _current = State(initialValue: start)
    }

    var body: some View {
        NavigationStack {
            pages
                // No title: the image's is in Info. The bar is only its buttons
                .navigationBarTitleDisplayMode(.inline)
                .toolbarVisibility(hidden ? .hidden : .visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        ShareLink(item: shelf.library.file(current))
                        Button("Delete", systemImage: "trash") { deleting = true }
                            .keyboardShortcut(.delete)
                            .confirmsDeleting($deleting, delete: delete)
                        Button("Info", systemImage: "info.circle") { showsInfo.toggle() }
                            .keyboardShortcut("i")
                    }
                }
                // Info hides and comes back with the bars
                .inspector(isPresented: Binding { showsInfo && !hidden } set: { showsInfo = $0 }) {
                    // Made anew for each image: the old one saves as it goes
                    Info(id: current)
                        .id(current)
                        .inspectorColumnWidth(min: 280, ideal: 340)
                        .presentationDetents([.medium, .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                }
        }
        .statusBarHidden(hidden)
        .zoomDestination(current)
    }

    private var pages: some View {
        // Full height, under the bars, so that the image does not move when they hide. Within
        // the safe area on the sides, where the Info column is
        Pager(ids: ids, current: $current) { id in
            ImagePage(file: shelf.library.file(id), hidden: $hidden)
        }
        .ignoresSafeArea(edges: .vertical)
        .background(hidden ? Color.black : Color(uiColor: .systemBackground))
        // The arrow keys page. Invisible, not `hidden()`, which would disable the shortcuts
        .background {
            Group {
                Button("Previous") { step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next") { step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    /// Shows the image `by` places further on in the gallery, if there is one
    private func step(_ by: Int) {
        if let next = ids.neighbour(of: current, by: by) { current = next }
    }

    /// Deletes the image shown, and shows the next, or the one before the last. Closes after
    /// the only one
    private func delete() {
        guard let index = ids.firstIndex(of: current), shelf.remove(current) else { return }
        ids.remove(at: index)
        if ids.isEmpty {
            dismiss()
        } else {
            current = ids[min(index, ids.count - 1)]
        }
    }
}

/// One page: the image, decoded off the main thread, to zoom into. A tap hides the viewer's
/// bars, or shows them
private struct ImagePage: View {
    let file: URL
    @Binding var hidden: Bool
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image) {
                    withAnimation { hidden.toggle() }
                }
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

// MARK: - Info

/// The image's title, note, tags, and URLs, to edit, and facts about its file. Edits are saved as
/// they are made: text half a second after the last change and when the panel goes, tags and
/// URLs at once
private struct Info: View {
    let id: String
    @Environment(Shelf.self) private var shelf
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL
    @State private var meta = Meta()
    /// What was read or last saved: an image that is only looked at is never written
    @State private var saved = Meta()
    @State private var editable = true
    @State private var loaded = false
    @State private var file = FileInfo()
    @State private var newTag = ""
    @State private var newURL = ""
    @FocusState private var focus: Field?

    private enum Field { case tag, url }

    var body: some View {
        Form {
            if loaded && !editable {
                Section {
                    Label("This image's sidecar can't be edited: it is unreadable, or made by a newer version.",
                          systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                TextField("Title", text: $meta.title, axis: .vertical)
                TextField("Note", text: $meta.note, axis: .vertical)
                    .lineLimit(3...)
            }
            .disabled(!editable)
            Section("Tags") {
                ForEach(meta.tags, id: \.self, content: tagRow)
                    .onDelete { remove($0, from: \.tags) }
                    .deleteDisabled(!editable)
                if editable {
                    addField("Add Tag", text: $newTag, field: .tag, to: \.tags)
                    // Rows to choose: the text being typed is never changed (input methods)
                    ForEach(suggest(shelf.tags.map(\.name), attached: meta.tags, text: newTag), id: \.self) { tag in
                        Button {
                            add(tag, to: \.tags)
                            newTag = ""
                        } label: {
                            Text(verbatim: tag)
                        }
                    }
                }
            }
            Section("Sources") {
                ForEach(meta.urls, id: \.self, content: urlRow)
                    .onDelete { remove($0, from: \.urls) }
                    .deleteDisabled(!editable)
                if editable {
                    addField("Add URL", text: $newURL, field: .url, to: \.urls)
                        .keyboardType(.URL)
                }
            }
            Section("File") {
                let parts = id.split(separator: "/")
                LabeledContent("Name") {
                    Text(verbatim: String(parts.last ?? "")).lineLimit(1).truncationMode(.middle)
                }
                if parts.count > 1 {
                    LabeledContent("Folder") {
                        Text(verbatim: parts.dropLast().joined(separator: "/")).lineLimit(1).truncationMode(.middle)
                    }
                }
                if let pixels = file.pixels {
                    LabeledContent("Dimensions", value: "\(Int(pixels.width)) × \(Int(pixels.height))")
                }
                if let size = file.size {
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if let modified = file.modified {
                    LabeledContent("Modified") { Text(modified, format: .dateTime) }
                }
                if let added = meta.added.flatMap({ ISO8601DateFormatter().date(from: $0) }) {
                    LabeledContent("Added") { Text(added, format: .dateTime) }
                }
            }
        }
        .onAppear(perform: load)
        .onDisappear(perform: save)
        .task(id: meta) {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { save() }
        }
    }

    /// A tag: its name, with its namespace after it. Tapped, it opens the tag's gallery
    private func tagRow(_ name: String) -> some View {
        let (namespace, short) = splitTag(name)
        return Button { router.open(tag: name) } label: {
            LinkRow(systemImage: "chevron.forward") {
                LabeledContent {
                    Text(verbatim: namespace)
                } label: {
                    Text(verbatim: short)
                }
            }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = name }
        }
    }

    /// A URL: its site, with the whole URL under it. Tapped, it opens
    private func urlRow(_ text: String) -> some View {
        let url = URL(string: text)
        let host = url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        return Button { if let url { openURL(url) } } label: {
            LinkRow(systemImage: "arrow.up.forward") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: host ?? text)
                    if host != nil {
                        Text(verbatim: text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        }
    }

    /// A field that adds what is typed when Return is pressed, and stays for the next one
    private func addField(_ title: LocalizedStringKey, text: Binding<String>, field: Field,
                          to list: WritableKeyPath<Meta, [String]>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: field)
            .onSubmit {
                add(text.wrappedValue, to: list)
                text.wrappedValue = ""
                focus = field
            }
    }

    /// The sidecar is read again each time the image is opened for editing
    private func load() {
        shelf.refresh(id)
        if let item = shelf.library.get(id) {
            meta = item.meta
            saved = item.meta
            editable = item.editable
        }
        file = FileInfo(shelf.library.file(id))
        loaded = true
    }

    private func save() {
        guard loaded, editable, meta != saved else { return }
        shelf.save(id, meta)
        saved = meta
    }

    private func add(_ value: String, to list: WritableKeyPath<Meta, [String]>) {
        if pushUnique(&meta[keyPath: list], value) { save() }
    }

    private func remove(_ offsets: IndexSet, from list: WritableKeyPath<Meta, [String]>) {
        meta[keyPath: list].remove(atOffsets: offsets)
        save()
    }
}

/// A row that goes somewhere when tapped: its content in the text's colour, and a small symbol
/// at its end, as a navigation link has
private struct LinkRow<Content: View>: View {
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        // `Color.primary`, not `.primary`: in a button, `.primary` is the button's tint, and the
        // `.secondary` and `.tertiary` inside are made from it
        .foregroundStyle(Color.primary)
        .contentShape(.rect)
    }
}

/// What the File section shows
private struct FileInfo {
    var size: Int64?
    var modified: Date?
    var pixels: CGSize?

    init() {}

    init(_ url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        size = (attributes?[.size] as? NSNumber)?.int64Value
        modified = attributes?[.modificationDate] as? Date
        pixels = imageSize(url)
    }
}
