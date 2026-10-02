import SwiftUI
import PDFKit

// MARK: - Books

enum BookKind { case pdf, epub }

struct Book: Identifiable, Hashable {
    let url: URL
    var id: String { url.lastPathComponent }
    var fileTitle: String { url.deletingPathExtension().lastPathComponent }
    var kind: BookKind { url.pathExtension.lowercased() == "pdf" ? .pdf : .epub }
}

struct BookMeta: Codable, Equatable {
    var title: String
    var author: String
}

/// Where the reader stopped. `chapter` is the EPUB chapter or PDF page, `fraction` the
/// position inside it, `progress` the position in the whole book (0…1).
struct ReadingState: Codable, Equatable {
    var chapter: Int = 0
    var fraction: Double = 0
    var progress: Double = 0
    var lastOpened: Date?
}

final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published private(set) var meta: [String: BookMeta] = [:]

    /// Reading positions change constantly while reading, so they are stored silently and
    /// only announced to the UI when the reader closes (`publishStates`).
    private(set) var states: [String: ReadingState] = [:]
    private let statesBox = DiskBox<[String: ReadingState]>("reading-state.json")
    private let metaBox = DiskBox<[String: BookMeta]>("book-meta.json")

    init() {
        states = statesBox.load() ?? [:]
        meta = metaBox.load() ?? [:]
        refresh()
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.documents, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let found = files
            .filter { FileKind(url: $0).isBook }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(Book.init)
        if found != books { books = found }
    }

    func title(of book: Book) -> String {
        if let t = meta[book.id]?.title, !t.isEmpty { return t }
        return book.fileTitle
    }

    func author(of book: Book) -> String? {
        guard let a = meta[book.id]?.author, !a.isEmpty else { return nil }
        return a
    }

    func setMeta(_ m: BookMeta, for book: Book) {
        guard meta[book.id] != m else { return }
        meta[book.id] = m
        metaBox.save(meta)
    }

    func state(for book: Book) -> ReadingState { states[book.id] ?? ReadingState() }

    func record(_ state: ReadingState, for book: Book) {
        states[book.id] = state
        statesBox.save(states, delay: 1.5)
    }

    func publishStates() { objectWillChange.send() }
    func flush() { statesBox.flush(states) }

    var recentBook: Book? {
        books
            .filter { states[$0.id]?.lastOpened != nil }
            .max { (states[$0.id]?.lastOpened ?? .distantPast) < (states[$1.id]?.lastOpened ?? .distantPast) }
    }

    func resetProgress(_ book: Book) {
        states[book.id] = nil
        statesBox.save(states)
        objectWillChange.send()
    }

    func delete(_ book: Book) {
        try? FileManager.default.removeItem(at: book.url)
        EPUBBook.clearCache(for: book.url)
        CoverCache.shared.remove(id: book.id)
        states[book.id] = nil
        statesBox.save(states)
        refresh()
    }
}

// MARK: - Covers (generated once, cached on disk + memory)

final class CoverCache {
    static let shared = CoverCache()
    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL

    private init() {
        dir = AppPaths.caches.appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.countLimit = 80
    }

    func cached(_ book: Book) -> UIImage? { memory.object(forKey: book.id as NSString) }

    func cover(for book: Book) async -> (UIImage?, BookMeta?) {
        if let img = cached(book) { return (img, nil) }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: self.load(book))
            }
        }
    }

    func remove(id: String) {
        memory.removeObject(forKey: id as NSString)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".jpg"))
    }

    private func load(_ book: Book) -> (UIImage?, BookMeta?) {
        let file = dir.appendingPathComponent(book.id + ".jpg")
        if let img = UIImage(contentsOfFile: file.path) {
            memory.setObject(img, forKey: book.id as NSString)
            return (img, nil)
        }
        var image: UIImage?
        var meta: BookMeta?
        switch book.kind {
        case .pdf:
            if let page = PDFDocument(url: book.url)?.page(at: 0) {
                image = page.thumbnail(of: CGSize(width: 360, height: 540), for: .cropBox)
            }
        case .epub:
            if let epub = try? EPUBBook.open(book.url) {
                meta = BookMeta(title: epub.title, author: epub.author)
                if let c = epub.coverURL { image = ImageDownsampler.image(url: c, maxPixel: 560) }
            }
        }
        if let img = image {
            memory.setObject(img, forKey: book.id as NSString)
            if let data = img.jpegData(compressionQuality: 0.82) { try? data.write(to: file, options: .atomic) }
        }
        return (image, meta)
    }
}

// MARK: - Highlights & notes

enum HighlightColor: String, Codable, CaseIterable, Identifiable {
    case yellow, green, blue, pink
    var id: String { rawValue }

    var rgb: (Int, Int, Int) {
        switch self {
        case .yellow: return (255, 204, 0)
        case .green: return (52, 199, 89)
        case .blue: return (64, 156, 255)
        case .pink: return (255, 85, 130)
        }
    }

    var color: Color {
        let c = rgb
        return Color(red: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255)
    }

    var uiColor: UIColor {
        let c = rgb
        return UIColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
    }
}

struct PDFMarkRect: Codable, Hashable {
    var page: Int
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    init(page: Int, rect: CGRect) {
        self.page = page
        x = Double(rect.origin.x); y = Double(rect.origin.y)
        w = Double(rect.width); h = Double(rect.height)
    }

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct Highlight: Codable, Identifiable, Hashable {
    var id = UUID()
    var bookID: String
    var bookTitle: String
    var text: String
    var color: HighlightColor = .yellow
    var created = Date()
    /// EPUB chapter index or PDF page index
    var chapter: Int
    var progress: Double
    var locationLabel: String
    /// EPUB: character offsets inside the chapter
    var start: Int?
    var end: Int?
    /// PDF: highlighted line rectangles
    var rects: [PDFMarkRect]?
}

struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var quote: String?
    var bookID: String?
    var bookTitle: String?
    var chapter: Int?
    var fraction: Double?
    var progress: Double?
    var locationLabel: String?
    var created = Date()
    var updated = Date()

    var title: String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? "Untitled note" : first
    }

    var body: String {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        return lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

final class AnnotationStore: ObservableObject {
    @Published private(set) var highlights: [Highlight] = []
    @Published private(set) var notes: [Note] = []
    private let highlightBox = DiskBox<[Highlight]>("highlights.json")
    private let noteBox = DiskBox<[Note]>("notes.json")

    init() {
        highlights = highlightBox.load() ?? []
        notes = noteBox.load() ?? []
    }

    func highlights(forBook id: String) -> [Highlight] {
        highlights.filter { $0.bookID == id }.sorted { $0.progress < $1.progress }
    }

    func highlights(forBook id: String, chapter: Int) -> [Highlight] {
        highlights.filter { $0.bookID == id && $0.chapter == chapter }
    }

    func notes(forBook id: String) -> [Note] {
        notes.filter { $0.bookID == id }.sorted { ($0.progress ?? 0) < ($1.progress ?? 0) }
    }

    func add(_ h: Highlight) {
        highlights.append(h)
        highlightBox.save(highlights)
    }

    func remove(_ h: Highlight) {
        highlights.removeAll { $0.id == h.id }
        highlightBox.save(highlights)
    }

    func removeHighlights(forBook id: String) {
        highlights.removeAll { $0.bookID == id }
        highlightBox.save(highlights)
    }

    func contains(note: Note) -> Bool { notes.contains { $0.id == note.id } }

    func upsert(_ note: Note) {
        var n = note
        n.updated = Date()
        if let i = notes.firstIndex(where: { $0.id == n.id }) { notes[i] = n } else { notes.append(n) }
        noteBox.save(notes)
    }

    func remove(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        noteBox.save(notes)
    }

    func flush() {
        highlightBox.flush(highlights)
        noteBox.flush(notes)
    }
}

// MARK: - Navigation

enum ReaderTarget {
    case highlight(Highlight)
    case location(chapter: Int, fraction: Double)
}

struct ReaderRequest: Identifiable {
    let id = UUID()
    let book: Book
    var target: ReaderTarget?
}

final class AppRouter: ObservableObject {
    @Published var reader: ReaderRequest?
    @Published var selectedTab = 0
    @Published var showDownloads = false

    func open(_ book: Book, at target: ReaderTarget? = nil) {
        reader = ReaderRequest(book: book, target: target)
    }
}
