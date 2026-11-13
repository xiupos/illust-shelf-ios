// The images of a folder and their sidecars. Foundation only, so that it also builds on Linux,
// where the tests at the end of this file check it against the cases that every Illust Shelf
// app shares (spec/cases.json).

import Foundation

let imageExtensions = ["png", "jpg", "jpeg", "webp", "gif"]
/// Galleries of tags with this prefix are in file name order
private let setPrefix = "set:"
/// The number of tags suggested while typing one
let suggestionCount = 5

// MARK: - Meta

/// A sidecar's content, in the illust-sidecar format: https://github.com/xiupos/illust-sidecar
struct Meta: Equatable {
    var v: UInt64 = 1
    var title = ""
    var tags: [String] = []
    var urls: [String] = []
    var note = ""
    var added: String?
    /// Keys the app does not know, kept as they are, in their order
    var extra: [(String, JSON)] = []

    /// Reads a sidecar. Throws if it is not an object, a known key has the wrong type, or `v` is
    /// missing or not a non-negative integer. The caller checks that `v` is 1
    init(json: JSON) throws {
        guard case .object(let pairs) = json else { throw LibraryError.badSidecar }
        var v: UInt64?
        for (key, value) in pairs {
            switch key {
            case "v":
                guard case .number(let text) = value, let n = UInt64(text) else { throw LibraryError.badSidecar }
                v = n
            case "title", "note":
                guard case .string(let s) = value else { throw LibraryError.badSidecar }
                if key == "title" { title = s } else { note = s }
            case "tags", "urls":
                guard let list = value.strings else { throw LibraryError.badSidecar }
                if key == "tags" { tags = list } else { urls = list }
            case "added":
                switch value {
                case .null: added = nil
                case .string(let s): added = s
                default: throw LibraryError.badSidecar
                }
            default:
                extra.append((key, value))
            }
        }
        guard let v else { throw LibraryError.badSidecar }
        self.v = v
    }

    init(added: String? = nil) {
        self.added = added
    }

    /// The sidecar to write. Empty fields are left out
    var json: JSON {
        var pairs: [(String, JSON)] = [("v", .number(String(v)))]
        if !title.isEmpty { pairs.append(("title", .string(title))) }
        if !tags.isEmpty { pairs.append(("tags", .array(tags.map(JSON.string)))) }
        if !urls.isEmpty { pairs.append(("urls", .array(urls.map(JSON.string)))) }
        if !note.isEmpty { pairs.append(("note", .string(note))) }
        if let added { pairs.append(("added", .string(added))) }
        return .object(pairs + extra)
    }

    /// Trims the texts, and drops empty and repeated tags and URLs
    mutating func normalize() {
        title = title.trimmed
        note = note.trimmed
        for path in [\Meta.tags, \Meta.urls] {
            var seen = Set<String>()
            self[keyPath: path] = self[keyPath: path].map(\.trimmed).filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }

    static func == (a: Meta, b: Meta) -> Bool {
        a.v == b.v && a.title == b.title && a.tags == b.tags && a.urls == b.urls && a.note == b.note
            && a.added == b.added && JSON.object(a.extra) == JSON.object(b.extra)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Item

struct Item {
    /// The image's path relative to the library's folder, with `/` between the parts; also the
    /// item's ID. It stays the same when the folder moves, which it does on iOS
    let id: String
    var meta = Meta()
    /// false if the sidecar cannot be read as a `Meta` or its `v` is not 1. It is then never written
    var editable = true

    init(root: URL, id: String) {
        self.id = id
        reload(root: root)
    }

    mutating func reload(root: URL) {
        let url = sidecarURL(root.appendingPathComponent(id))
        guard FileManager.default.fileExists(atPath: url.path) else {
            (meta, editable) = (Meta(), true)
            return
        }
        do {
            let meta = try Meta(json: JSON(parsing: Data(contentsOf: url)))
            (self.meta, editable) = (meta, meta.v == 1)
        } catch {
            (meta, editable) = (Meta(), false)
        }
    }

    /// The file name: the last part of the ID
    var name: Substring { id.split(separator: "/").last ?? "" }

    /// `query` is trimmed and lower case
    func matches(tag: String?, query: String) -> Bool {
        let hit = { (s: String) in s.lowercased().contains(query) }
        return (tag.map { meta.tags.contains($0) } ?? true)
            && (query.isEmpty || hit(meta.title) || hit(meta.note) || meta.tags.contains(where: hit))
    }
}

/// File name order, then ID order, by bytes
private func byName(_ a: Item, _ b: Item) -> Bool {
    a.name == b.name ? idPrecedes(a.id, b.id) : bytesPrecede(a.name, b.name)
}

private func bytesPrecede(_ a: some StringProtocol, _ b: some StringProtocol) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
}

/// IDs are ordered part by part, each by its bytes, not as whole strings: `a/b` is before `a.b`.
/// Every Illust Shelf app must order them alike, for galleries to be in the same order
func idPrecedes(_ a: String, _ b: String) -> Bool {
    a.split(separator: "/").lexicographicallyPrecedes(b.split(separator: "/"), by: bytesPrecede)
}

// MARK: - Tags

/// A tag in use
struct Tag: Identifiable, Equatable {
    let name: String
    /// The number of items with the tag
    let count: Int
    /// The first image of the tag's gallery
    let cover: String

    var id: String { name }

    /// The part before the first `:`, or "" if there is none
    var namespace: String {
        name.firstIndex(of: ":").map { String(name[..<$0]) } ?? ""
    }

    /// The name without its namespace
    var short: String {
        name.firstIndex(of: ":").map { String(name[name.index(after: $0)...]) } ?? name
    }
}

struct TagSection: Identifiable {
    let namespace: String
    var tags: [Tag]

    var id: String { namespace }
}

/// The tags by namespace, for the Tags tab. `tags` is in the order of `Library.tags()`, which each
/// section keeps. Namespaces are in the order of their most used tag; the tags without one ("")
/// come last
func sections(_ tags: [Tag]) -> [TagSection] {
    var sections: [TagSection] = []
    for tag in tags {
        if let i = sections.firstIndex(where: { $0.namespace == tag.namespace }) {
            sections[i].tags.append(tag)
        } else {
            sections.append(TagSection(namespace: tag.namespace, tags: [tag]))
        }
    }
    return sections.filter { !$0.namespace.isEmpty } + sections.filter { $0.namespace.isEmpty }
}

/// The tags whose name contains `query`, ignoring case
func searchTags(_ tags: [Tag], _ query: String) -> [Tag] {
    let query = query.trimmed.lowercased()
    return tags.filter { query.isEmpty || $0.name.lowercased().contains(query) }
}

/// Tags to offer while `text` is typed as a new tag of an image: the first `suggestionCount` of
/// `known` (every tag in use, most used first) that start with it, ignoring case, and are not
/// `attached` to the image yet
func suggest(_ known: [String], attached: [String], text: String) -> [String] {
    let text = text.trimmed.lowercased()
    guard !text.isEmpty else { return [] }
    return Array(known.filter { $0.lowercased().hasPrefix(text) && !attached.contains($0) }.prefix(suggestionCount))
}

/// Adds `value`, trimmed, to an image's tags or URLs. false if it is empty or already there
@discardableResult
func pushUnique(_ list: inout [String], _ value: String) -> Bool {
    let value = value.trimmed
    let new = !value.isEmpty && !list.contains(value)
    if new { list.append(value) }
    return new
}

// MARK: - Library

struct Library {
    /// The folder, nil before one is loaded
    private(set) var root: URL?
    private(set) var items: [Item] = []
    private var index: [String: Int] = [:]

    init() {}

    /// Scans `folder` and reads the sidecars. Slow, so run it off the main thread. Thumbnails are
    /// not made here: the app makes them as they come into view
    init(loading folder: URL) {
        root = folder
        var found = scan(folder)
        // Newest first
        found.sort { $0.mtime != $1.mtime ? $0.mtime > $1.mtime : idPrecedes($0.id, $1.id) }
        items = found.map { Item(root: folder, id: $0.id) }
        reindex()
    }

    private mutating func reindex() {
        index = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
    }

    /// The image's file
    func file(_ id: String) -> URL {
        (root ?? URL(fileURLWithPath: "/")).appendingPathComponent(id)
    }

    /// The image's sidecar: `foo.png.json` for `foo.png`
    func sidecar(_ id: String) -> URL {
        sidecarURL(file(id))
    }

    var isEmpty: Bool { items.isEmpty }

    func get(_ id: String) -> Item? {
        index[id].map { items[$0] }
    }

    private func editableIndex(_ id: String) throws -> Int {
        guard let i = index[id] else { throw LibraryError.notFound }
        guard items[i].editable else { throw LibraryError.readOnly }
        return i
    }

    /// A gallery: the items with `tag` (all if nil) whose title, note, or tags contain `query`,
    /// ignoring case. Newest first, except a `set:` tag's, which is in file name order
    func paths(tag: String?, query: String) -> [String] {
        let query = query.trimmed.lowercased()
        var found = items.filter { $0.matches(tag: tag, query: query) }
        if let tag, tag.hasPrefix(setPrefix) {
            found.sort(by: byName)
        }
        return found.map(\.id)
    }

    /// The tags in use, most used first, then by name
    func tags() -> [Tag] {
        var tags: [String: (count: Int, cover: Int)] = [:]
        for (i, item) in items.enumerated() {
            for name in Set(item.meta.tags) {
                var tag = tags[name] ?? (0, i)
                tag.count += 1
                if name.hasPrefix(setPrefix) && byName(item, items[tag.cover]) {
                    tag.cover = i
                }
                tags[name] = tag
            }
        }
        return tags.map { Tag(name: $0.key, count: $0.value.count, cover: items[$0.value.cover].id) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : bytesPrecede($0.name, $1.name) }
    }

    /// Saves the item's sidecar as `meta`, normalized. Writes nothing if that changes nothing. A
    /// new sidecar gets `added: now`
    mutating func save(_ id: String, _ meta: Meta, now: String) throws {
        let i = try editableIndex(id)
        var meta = meta
        meta.normalize()
        guard meta != items[i].meta else { return }
        let url = sidecar(id)
        if meta.added == nil && !FileManager.default.fileExists(atPath: url.path) {
            meta.added = now
        }
        try writeJSON(url, meta.json)
        items[i].meta = meta
    }

    /// Re-reads the item's sidecar
    mutating func refresh(_ id: String) {
        guard let i = index[id], let root else { return }
        items[i].reload(root: root)
    }

    /// Deletes the image and its sidecar. iOS has no trash for the user's folders
    mutating func remove(_ id: String) throws {
        guard let i = index[id] else { throw LibraryError.notFound }
        let fm = FileManager.default
        if fm.fileExists(atPath: sidecar(id).path) {
            try fm.removeItem(at: sidecar(id))
        }
        try fm.removeItem(at: file(id))
        items.remove(at: i)
        reindex()
    }
}

/// Copies an image into `folder` as `<UUIDv7>.<ext>`, so names sort by time added, with a sidecar
/// that has only `added`. Returns the copy's ID
func importImage(into folder: URL, from src: URL, now: String) throws -> String {
    guard isImage(src.lastPathComponent) else { throw LibraryError.notImage }
    return try add(into: folder, ext: src.pathExtension, now: now) { tmp in
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: src, to: tmp)
        // A copy keeps the original's modification time, which would put an old image far down
        // the galleries, not first as one just added
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: tmp.path)
    }
}

/// Like `importImage`, for PNG data
func importPNG(into folder: URL, _ png: Data, now: String) throws -> String {
    try add(into: folder, ext: "png", now: now) { try png.write(to: $0) }
}

private func add(into folder: URL, ext: String, now: String, write: (URL) throws -> Void) throws -> String {
    let name = "\(uuidV7()).\(ext)"
    let dst = folder.appendingPathComponent(name)
    let fm = FileManager.default
    guard !fm.fileExists(atPath: dst.path), !fm.fileExists(atPath: sidecarURL(dst).path) else {
        throw LibraryError.nameTaken
    }
    try writeAtomic(dst, write)
    try writeJSON(sidecarURL(dst), Meta(added: now).json)
    return name
}

/// `.json` appended to the whole name: replacing the extension would give `foo.png` and `foo.jpg`
/// the same sidecar
func sidecarURL(_ image: URL) -> URL {
    image.deletingLastPathComponent().appendingPathComponent(image.lastPathComponent + ".json")
}

/// The images under `folder`, as IDs, with their mtimes. Follows symlinks; a folder reached twice
/// is walked once, which also ends loops, and a file reached twice counts once
private func scan(_ folder: URL) -> [(id: String, mtime: Date)] {
    let fm = FileManager.default
    var found: [(id: String, mtime: Date)] = []
    var seenFiles = Set<String>()
    var seenFolders: Set<String> = [folder.resolvingSymlinksInPath().path]

    func walk(_ dir: URL, _ prefix: String) {
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names.sorted(by: bytesPrecede) {
            if name.hasPrefix(".") || name.contains(".sync-conflict-") { continue }
            let url = dir.appendingPathComponent(name)
            let real = url.resolvingSymlinksInPath().path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if seenFolders.insert(real).inserted {
                    walk(url, prefix + name + "/")
                }
            } else if isImage(name) && seenFiles.insert(real).inserted {
                let mtime = (try? fm.attributesOfItem(atPath: real)[.modificationDate]) as? Date
                found.append((prefix + name, mtime ?? Date(timeIntervalSince1970: 0)))
            }
        }
    }
    walk(folder, "")
    return found
}

func isImage(_ name: String) -> Bool {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
    return imageExtensions.contains(name[name.index(after: dot)...].lowercased())
}

/// Has `write` fill a hidden temporary file next to `url` (`.<name>.tmp`, which scans skip), then
/// renames it into place
func writeAtomic(_ url: URL, _ write: (URL) throws -> Void) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
    do {
        try write(tmp)
        guard rename(tmp.path, url.path) == 0 else { throw LibraryError.renameFailed }
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        throw error
    }
}

/// Indented JSON with a trailing newline
func writeJSON(_ url: URL, _ value: JSON) throws {
    try writeAtomic(url) { try Data((value.pretty() + "\n").utf8).write(to: $0) }
}

/// The current local time in ISO 8601 with an offset, for `added`
func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    return formatter.string(from: Date())
}

/// A UUID version 7: 48 bits of Unix time in milliseconds, then random bits. Lower case, as names
/// of added images
func uuidV7(_ date: Date = Date()) -> String {
    let ms = UInt64(max(0, date.timeIntervalSince1970 * 1000))
    var b = (0..<16).map { _ in UInt8.random(in: 0...255) }
    for i in 0..<6 { b[i] = UInt8(truncatingIfNeeded: ms >> (40 - 8 * i)) }
    b[6] = 0x70 | (b[6] & 0x0f)
    b[8] = 0x80 | (b[8] & 0x3f)
    let hex = b.map { String(format: "%02x", $0) }.joined()
    let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { r in
        String(hex.dropFirst(r.lowerBound).prefix(r.count))
    }
    return parts.joined(separator: "-")
}

enum LibraryError: LocalizedError {
    case notFound, readOnly, notImage, nameTaken, renameFailed, badSidecar

    var errorDescription: String? {
        switch self {
        case .notFound: "Image not found"
        case .readOnly: "The sidecar is read-only"
        case .notImage: "Not a supported image"
        case .nameTaken: "The name is taken"
        case .renameFailed: "Could not save the file"
        case .badSidecar: "The sidecar is not valid"
        }
    }
}

// MARK: - JSON

/// A JSON value. Numbers keep their text, so that `1` and `1.0` stay apart, and unknown keys are
/// written back as they were read. Objects keep their order; duplicate keys are an error.
/// JSONSerialization does neither, and behaves differently on Linux
enum JSON: Equatable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    init(parsing data: Data) throws {
        var parser = JSONParser(bytes: Array(data))
        self = try parser.document()
    }

    subscript(key: String) -> JSON? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }

    var string: String? {
        if case .string(let s) = self { s } else { nil }
    }

    var array: [JSON]? {
        if case .array(let a) = self { a } else { nil }
    }

    var strings: [String]? {
        guard let array else { return nil }
        let strings = array.compactMap(\.string)
        return strings.count == array.count ? strings : nil
    }

    /// Objects are equal whatever their order
    static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case let (.bool(x), .bool(y)): x == y
        case let (.number(x), .number(y)): x == y
        case let (.string(x), .string(y)): x == y
        case let (.array(x), .array(y)): x == y
        case let (.object(x), .object(y)):
            x.count == y.count && x.allSatisfy { key, value in b[key] == value }
        default: false
        }
    }

    /// Indented by two spaces, as serde_json writes it
    func pretty(_ indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return JSON.quote(s)
        case .array(let a):
            if a.isEmpty { return "[]" }
            return "[\n" + a.map { inner + $0.pretty(inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        case .object(let o):
            if o.isEmpty { return "{}" }
            let lines = o.map { inner + JSON.quote($0.0) + ": " + $0.1.pretty(inner) }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\u{c}": out += "\\f"
            case _ where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var i = 0

    struct Invalid: Error {}

    mutating func document() throws -> JSON {
        let value = try self.value(depth: 0)
        skipSpace()
        guard i == bytes.count else { throw Invalid() }
        return value
    }

    private var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

    private mutating func skipSpace() {
        while let c = peek, c == 0x20 || c == 0x0a || c == 0x0d || c == 0x09 { i += 1 }
    }

    private mutating func eat(_ c: Character) -> Bool {
        skipSpace()
        guard peek == c.asciiValue else { return false }
        i += 1
        return true
    }

    private mutating func expect(_ c: Character) throws {
        guard eat(c) else { throw Invalid() }
    }

    private mutating func value(depth: Int) throws -> JSON {
        skipSpace()
        guard depth < 128, let c = peek else { throw Invalid() }
        switch c {
        case UInt8(ascii: "{"):
            i += 1
            var pairs: [(String, JSON)] = []
            if eat("}") { return .object([]) }
            repeat {
                skipSpace()
                let key = try string()
                guard !pairs.contains(where: { $0.0 == key }) else { throw Invalid() }
                try expect(":")
                pairs.append((key, try value(depth: depth + 1)))
            } while eat(",")
            try expect("}")
            return .object(pairs)
        case UInt8(ascii: "["):
            i += 1
            var items: [JSON] = []
            if eat("]") { return .array([]) }
            repeat {
                items.append(try value(depth: depth + 1))
            } while eat(",")
            try expect("]")
            return .array(items)
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default:
            return .number(try number())
        }
    }

    private mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw Invalid() }
        i += w.count
    }

    private mutating func digits() -> Int {
        let start = i
        while let c = peek, c >= 0x30 && c <= 0x39 { i += 1 }
        return i - start
    }

    /// -? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?
    private mutating func number() throws -> String {
        let start = i
        if peek == UInt8(ascii: "-") { i += 1 }
        if peek == UInt8(ascii: "0") {
            i += 1
        } else {
            guard digits() > 0 else { throw Invalid() }
        }
        if peek == UInt8(ascii: ".") {
            i += 1
            guard digits() > 0 else { throw Invalid() }
        }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            i += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { throw Invalid() }
        }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count,
              let n = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16)
        else { throw Invalid() }
        i += 4
        return n
    }

    private mutating func string() throws -> String {
        guard peek == UInt8(ascii: "\"") else { throw Invalid() }
        i += 1
        var out: [UInt8] = []
        while true {
            guard let c = peek else { throw Invalid() }
            i += 1
            switch c {
            case UInt8(ascii: "\""):
                guard let s = String(bytes: out, encoding: .utf8) else { throw Invalid() }
                return s
            case UInt8(ascii: "\\"):
                guard let e = peek else { throw Invalid() }
                i += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0c)
                case UInt8(ascii: "n"): out.append(0x0a)
                case UInt8(ascii: "r"): out.append(0x0d)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xd800..<0xdc00).contains(code) {
                        try literal("\\u")
                        let low = try hex4()
                        guard (0xdc00..<0xe000).contains(low) else { throw Invalid() }
                        code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw Invalid() }
                    out.append(contentsOf: Array(String(scalar).utf8))
                default: throw Invalid()
                }
            case 0..<0x20: throw Invalid()
            default: out.append(c)
            }
        }
    }
}

// MARK: - Tests

// Linux only: the app never builds this. Run with
//   swiftc -parse-as-library Sources/Library.swift -o /tmp/illust-shelf-spec && /tmp/illust-shelf-spec
// It runs spec/cases.json of this project, or the file whose path it is given
#if os(Linux)
@main
enum Tests {
    static var failures = 0
    static var checks = 0

    static func check(_ ok: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL:", message())
        }
    }

    static func tmpdir(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("illust-shelf-\(name)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Image content does not matter: the library does not decode images
    static func png(_ url: URL) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("png".utf8).write(to: url)
    }

    static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    static func main() throws {
        let path = CommandLine.arguments.dropFirst().first
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("spec/cases.json").path
        let cases = try JSON(parsing: Data(contentsOf: URL(fileURLWithPath: path)))
        specCases(cases)
        jsonRoundTrip()
        readOnly()
        adding()
        removing()
        symlinks()
        print(failures == 0 ? "ok: \(checks) checks" : "\(failures) of \(checks) checks failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// The cases every Illust Shelf app shares, run as the spec says (SPEC.md, "Test cases")
    static func specCases(_ cases: JSON) {
        let now = cases["now"]!.string!

        for c in cases["sidecars"]!.array! {
            let name = c["name"]!.string!
            let dir = tmpdir("spec-sidecar")
            let image = dir.appendingPathComponent("a.png")
            png(image)
            let before = c["sidecar"]!.string
            if let before { try! Data(before.utf8).write(to: sidecarURL(image)) }
            var lib = Library(loading: dir)
            let editable = c["editable"].map { $0 == .bool(true) } ?? true
            check(lib.get("a.png")!.editable == editable, "\(name): editable")
            var m = lib.get("a.png")!.meta
            let set = c["set"] ?? .object([])
            if let s = set["title"]?.string { m.title = s }
            if let s = set["note"]?.string { m.note = s }
            if let s = set["tags"]?.strings { m.tags = s }
            if let s = set["urls"]?.strings { m.urls = s }
            if !editable { m.title = "changed" }
            let saved = (try? lib.save("a.png", m, now: now)) != nil
            check(saved == editable, "\(name): saving")
            if !editable || c["unchanged"] == .bool(true) {
                check(read(sidecarURL(image)) == before, "\(name): unchanged")
            } else {
                let found = read(sidecarURL(image)).flatMap { try? JSON(parsing: Data($0.utf8)) }
                check(found == c["expect"], "\(name): \(String(describing: found?.pretty()))")
            }
        }

        let dir = tmpdir("spec-library")
        let library = cases["library"]!
        for f in library["files"]!.array! {
            let file = dir.appendingPathComponent(f["path"]!.string!)
            png(file)
            let mtime = Date(timeIntervalSince1970: Double(f["mtime"]!.pretty())!)
            try! FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
            if let sidecar = f["sidecar"] {
                try! Data(sidecar.pretty().utf8).write(to: sidecarURL(file))
            }
        }
        for skipped in library["skipped"]!.strings! {
            png(dir.appendingPathComponent(skipped))
        }
        let lib = Library(loading: dir)
        for g in library["galleries"]!.array! {
            let found = lib.paths(tag: g["tag"]!.string, query: g["query"]!.string!)
            check(found == g["expect"]!.strings!, "gallery \(g.pretty()): \(found)")
        }
        let tags = lib.tags()
        let expected = library["tags"]!.array!.map {
            Tag(name: $0["name"]!.string!, count: Int($0["count"]!.pretty())!, cover: $0["cover"]!.string!)
        }
        check(tags == expected, "tags: \(tags)")
        let found = sections(tags).map { "\($0.namespace): \($0.tags.map(\.name))" }
        let sectionsExpected = library["sections"]!.array!.map {
            "\($0["namespace"]!.string!): \($0["tags"]!.strings!)"
        }
        check(found == sectionsExpected, "sections: \(found)")
        for s in library["tag_searches"]!.array! {
            let names = searchTags(tags, s["query"]!.string!).map(\.name)
            check(names == s["expect"]!.strings!, "tag search \(s.pretty()): \(names)")
        }

        let suggestions = cases["suggestions"]!
        let known = suggestions["known"]!.strings!
        for s in suggestions["cases"]!.array! {
            let found = suggest(known, attached: s["attached"]!.strings!, text: s["text"]!.string!)
            check(found == s["expect"]!.strings!, "suggestions \(s.pretty()): \(found)")
        }
    }

    static func jsonRoundTrip() {
        let text = #"{"a": "q\"\\\/\n\u0001 é 😀", "b": [1, -0.5e+3, true, null, {}, []], "c": {"d": 0}}"#
        let value = try? JSON(parsing: Data(text.utf8))
        check(value?["a"]?.string == "q\"\\/\n\u{1} é 😀", "JSON strings")
        let again = value.flatMap { try? JSON(parsing: Data($0.pretty().utf8)) }
        check(value != nil && again == value, "JSON round trip")
        check(value?.pretty().contains(#""b": ["#) == true, "JSON indent")
        for bad in ["{broken", #"{"a":1,"a":2}"#, "[1,]", "01", #""\ud800""#, "{} x", "\"\u{1}\""] {
            check((try? JSON(parsing: Data(bad.utf8))) == nil, "JSON rejects \(bad)")
        }
    }

    static func readOnly() {
        let dir = tmpdir("read-only")
        let image = dir.appendingPathComponent("a.png")
        png(image)
        try! Data(#"{"v":2,"title":"future"}"#.utf8).write(to: sidecarURL(image))
        var lib = Library(loading: dir)
        check(lib.get("a.png")?.meta.title == "future", "a newer version is shown")
        try! Data(#"{"v":1,"title":"now"}"#.utf8).write(to: sidecarURL(image))
        lib.refresh("a.png")
        check(lib.get("a.png")?.editable == true && lib.get("a.png")?.meta.title == "now", "refresh re-reads")
    }

    static func adding() {
        let dir = tmpdir("add")
        let src = tmpdir("add-src").appendingPathComponent("x.JPG")
        png(src)
        try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: src.path)
        let now = "2026-11-11T09:00:00+09:00"
        let id = try? importImage(into: dir, from: src, now: now)
        let mtime = id.flatMap { try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($0).path)[.modificationDate] as? Date }
        check((mtime ?? .distantPast).timeIntervalSinceNow > -60, "an added image is modified now: \(String(describing: mtime))")
        check(id?.count == 40 && id?.hasSuffix(".JPG") == true && Array(id ?? "")[14] == "7", "import name: \(id ?? "")")
        if let id {
            let sidecar = read(sidecarURL(dir.appendingPathComponent(id))).flatMap { try? JSON(parsing: Data($0.utf8)) }
            check(sidecar == .object([("v", .number("1")), ("added", .string(now))]), "import sidecar")
        }
        let text = tmpdir("add-src").appendingPathComponent("readme.txt")
        png(text)
        check((try? importImage(into: dir, from: text, now: now)) == nil, "import refuses a non-image")
        let pasted = try? importPNG(into: dir, Data("png bytes".utf8), now: now)
        check(pasted?.hasSuffix(".png") == true, "pasted PNG")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        check(names.count == 4 && !names.contains { $0.hasPrefix(".") }, "no temporary files: \(names)")
        check(Library(loading: dir).items.count == 2, "added images are found")
        check(uuidV7(Date(timeIntervalSince1970: 1)) < uuidV7(Date(timeIntervalSince1970: 2)), "UUIDv7 order")
        check(timestamp().count >= 20, "timestamp: \(timestamp())")
    }

    static func removing() {
        let dir = tmpdir("remove")
        let image = dir.appendingPathComponent("a.png")
        png(image)
        try! Data(#"{"v":1}"#.utf8).write(to: sidecarURL(image))
        var lib = Library(loading: dir)
        check((try? lib.remove("a.png")) != nil && lib.isEmpty, "remove")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? ["?"]
        check(names.isEmpty, "remove deletes the sidecar: \(names)")
    }

    static func symlinks() {
        let dir = tmpdir("links")
        png(dir.appendingPathComponent("sub/a.png"))
        let fm = FileManager.default
        try! fm.createSymbolicLink(atPath: dir.appendingPathComponent("sub/loop").path, withDestinationPath: dir.path)
        try! fm.createSymbolicLink(atPath: dir.appendingPathComponent("b.png").path,
                                   withDestinationPath: dir.appendingPathComponent("sub/a.png").path)
        let ids = Library(loading: dir).items.map(\.id)
        check(ids.count == 1, "symlinks: loops end and a file counts once: \(ids)")
        check(idPrecedes("a/b", "a.b") && !idPrecedes("a.b", "a/b"), "IDs are ordered by part")
    }
}
#endif
