import SwiftUI
import UIKit

// MARK: - Reader settings

enum ReadingDirection: String, CaseIterable, Identifiable {
    case paged, scroll
    var id: String { rawValue }
    var title: String { self == .paged ? "Swipe Left" : "Scroll Down" }
    var subtitle: String { self == .paged ? "Turn pages like a book" : "One continuous page" }
    var symbol: String { self == .paged ? "arrow.left.and.right" : "arrow.up.and.down" }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case paper, sepia, dusk, night
    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var backgroundHex: String {
        switch self {
        case .paper: return "#FBFBF8"
        case .sepia: return "#F4ECD8"
        case .dusk: return "#2A2A2E"
        case .night: return "#0F0F11"
        }
    }

    var textHex: String {
        switch self {
        case .paper: return "#1D1D1F"
        case .sepia: return "#4F3B2A"
        case .dusk: return "#E3E3E8"
        case .night: return "#C8C8CE"
        }
    }

    var linkHex: String {
        switch self {
        case .paper: return "#B4530F"
        case .sepia: return "#9C5B2E"
        case .dusk: return "#FFB066"
        case .night: return "#FF9F43"
        }
    }

    var isDark: Bool { self == .dusk || self == .night }
    var background: Color { Color(hex: backgroundHex) }
    var foreground: Color { Color(hex: textHex) }
    var uiBackground: UIColor { UIColor(hex: backgroundHex) }

    var pdfBackground: UIColor {
        switch self {
        case .paper: return UIColor(hex: "#E8E8EC")
        case .sepia: return UIColor(hex: "#E4D9BF")
        case .dusk: return UIColor(hex: "#2A2A2E")
        case .night: return UIColor(hex: "#0F0F11")
        }
    }
}

enum ReaderFont: String, CaseIterable, Identifiable {
    case original, serif, sans
    var id: String { rawValue }
    var name: String {
        switch self {
        case .original: return "Book"
        case .serif: return "Serif"
        case .sans: return "Sans"
        }
    }

    var css: String? {
        switch self {
        case .original: return nil
        case .serif: return "ui-serif, 'New York', Georgia, 'Times New Roman', serif"
        case .sans: return "-apple-system, system-ui, 'Helvetica Neue', sans-serif"
        }
    }
}

final class ReaderSettings: ObservableObject {
    static let shared = ReaderSettings()
    private let d = UserDefaults.standard

    @Published var direction: ReadingDirection { didSet { d.set(direction.rawValue, forKey: "rs.direction") } }
    @Published var theme: ReaderTheme { didSet { d.set(theme.rawValue, forKey: "rs.theme") } }
    @Published var font: ReaderFont { didSet { d.set(font.rawValue, forKey: "rs.font") } }
    @Published var fontScale: Double { didSet { d.set(fontScale, forKey: "rs.fontScale") } }
    @Published var lineSpacing: Double { didSet { d.set(lineSpacing, forKey: "rs.lineSpacing") } }

    static let fontRange: ClosedRange<Double> = 60...260

    private init() {
        let d = UserDefaults.standard
        direction = ReadingDirection(rawValue: d.string(forKey: "rs.direction") ?? "") ?? .paged
        theme = ReaderTheme(rawValue: d.string(forKey: "rs.theme") ?? "") ?? .night
        font = ReaderFont(rawValue: d.string(forKey: "rs.font") ?? "") ?? .serif
        let fs = d.double(forKey: "rs.fontScale")
        fontScale = fs > 0 ? fs : 110
        let ls = d.double(forKey: "rs.lineSpacing")
        lineSpacing = ls > 0 ? ls : 1.6
    }

    /// Theme + typography CSS injected into every EPUB chapter.
    var css: String {
        let alpha = theme.isDark ? 0.38 : 0.42
        var marks = ""
        for c in HighlightColor.allCases {
            let v = c.rgb
            marks += "mark.__hl[data-c=\"\(c.rawValue)\"]{background-color:rgba(\(v.0),\(v.1),\(v.2),\(alpha)) !important;}\n"
        }
        let family = font.css.map { "font-family: \($0) !important;" } ?? ""
        let inherit = font.css == nil ? "" : "font-family: inherit !important;"
        return """
        html, body { background-color: \(theme.backgroundHex) !important; }
        body {
          color: \(theme.textHex) !important;
          font-size: \(Int(fontScale))% !important;
          line-height: \(String(format: "%.2f", lineSpacing)) !important;
          -webkit-text-size-adjust: none !important;
          overflow-wrap: break-word;
          -webkit-hyphens: auto; hyphens: auto;
          -webkit-tap-highlight-color: transparent;
          \(family)
        }
        body * { color: inherit !important; background-color: transparent !important; \(inherit) }
        p, li, blockquote, dd, dt, div { line-height: inherit !important; }
        a, a * { color: \(theme.linkHex) !important; text-decoration: none !important; }
        pre, code, pre *, code * { font-family: ui-monospace, Menlo, monospace !important; white-space: pre-wrap !important; }
        img, svg, video { max-width: 100% !important; height: auto !important; }
        ::selection { background: rgba(255, 159, 67, 0.35); }
        mark.__hl { color: inherit !important; border-radius: 3px; -webkit-box-decoration-break: clone; box-decoration-break: clone; }
        \(marks)
        """
    }
}

// MARK: - Engine protocol (implemented by the EPUB and PDF views)

protocol ReaderEngine: AnyObject {
    func jump(toProgress p: Double)
    func jump(chapter: Int, fragment: String?)
    func jump(chapter: Int, fraction: Double)
    func jump(toHighlight h: Highlight)
    func highlightSelection(color: HighlightColor)
    func removeHighlight(_ h: Highlight)
    func selectedText(_ completion: @escaping (String?) -> Void)
    func clearSelection()
    func zoom(in zoomIn: Bool)
}

// MARK: - Reader session state

final class ReaderModel: ObservableObject {
    let book: Book
    let library: LibraryStore
    let annotations: AnnotationStore
    let initialTarget: ReaderTarget?

    @Published var progress: Double = 0
    @Published var chapter = 0
    @Published var positionText = ""
    @Published var detailText = ""
    @Published var chromeVisible = true
    @Published var hasSelection = false
    @Published var toc: [TOCEntry] = []
    @Published var hud: String?
    @Published var highlightToRemove: Highlight?
    @Published var errorText: String?
    @Published var displayTitle: String
    @Published var pageCount = 0

    weak var engine: ReaderEngine?
    private(set) var epub: EPUBBook?
    private(set) var fraction: Double = 0
    private var reports = 0
    private var lastJump = Date()
    private var hudWork: DispatchWorkItem?

    init(book: Book, target: ReaderTarget?, library: LibraryStore, annotations: AnnotationStore) {
        self.book = book
        self.library = library
        self.annotations = annotations
        self.initialTarget = target
        displayTitle = library.title(of: book)
        let s = library.state(for: book)
        progress = s.progress
        chapter = s.chapter
        fraction = s.fraction
    }

    var savedState: ReadingState { library.state(for: book) }

    func attach(epub: EPUBBook) {
        self.epub = epub
        toc = epub.toc
        displayTitle = epub.title
        library.setMeta(BookMeta(title: epub.title, author: epub.author), for: book)
    }

    /// Called by the engines whenever the visible position settles.
    func report(chapter c: Int, fraction f: Double, progress p: Double, position: String, detail: String) {
        let pr = min(max(p, 0), 1)
        if chapter != c { chapter = c }
        fraction = f
        if abs(progress - pr) > 0.0001 { progress = pr }
        if positionText != position { positionText = position }
        if detailText != detail { detailText = detail }

        var s = library.state(for: book)
        s.chapter = c
        s.fraction = f
        s.progress = pr
        s.lastOpened = Date()
        library.record(s, for: book)

        reports += 1
        // Tuck the controls away once the reader starts turning pages
        if reports > 1, chromeVisible, Date().timeIntervalSince(lastJump) > 1.2 {
            chromeVisible = false
        }
    }

    func toggleChrome() { chromeVisible.toggle() }
    func setChrome(_ visible: Bool) { if chromeVisible != visible { chromeVisible = visible } }

    // MARK: Navigation

    func jump(toProgress p: Double) {
        lastJump = Date()
        engine?.jump(toProgress: p)
    }

    func jump(to entry: TOCEntry) {
        lastJump = Date()
        engine?.jump(chapter: entry.chapter, fragment: entry.fragment)
    }

    func jump(to h: Highlight) {
        lastJump = Date()
        engine?.jump(toHighlight: h)
    }

    func jump(to note: Note) {
        guard let c = note.chapter else { return }
        lastJump = Date()
        engine?.jump(chapter: c, fraction: note.fraction ?? 0)
    }

    /// Label shown while dragging the progress slider.
    func label(forProgress p: Double) -> String {
        switch book.kind {
        case .epub:
            guard let e = epub else { return "" }
            return e.chapterTitle(e.locate(progress: p).chapter)
        case .pdf:
            guard pageCount > 0 else { return "" }
            let page = min(max(Int((p * Double(pageCount)).rounded(.up)), 1), pageCount)
            return "Page \(page) of \(pageCount)"
        }
    }

    // MARK: Zoom HUD

    func showHUD(_ text: String) {
        hud = text
        hudWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hud = nil }
        hudWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)
    }

    // MARK: Highlights

    func addHighlight(text: String, color: HighlightColor, chapter: Int, progress: Double,
                      location: String, start: Int? = nil, end: Int? = nil, rects: [PDFMarkRect]? = nil) {
        let h = Highlight(bookID: book.id, bookTitle: displayTitle, text: text, color: color,
                          chapter: chapter, progress: progress, locationLabel: location,
                          start: start, end: end, rects: rects)
        annotations.add(h)
        hasSelection = false
        Haptics.tap()
    }

    func requestRemoveHighlight(_ id: UUID) {
        highlightToRemove = annotations.highlights.first { $0.id == id }
    }

    func removeHighlight(_ h: Highlight) {
        annotations.remove(h)
        engine?.removeHighlight(h)
    }

    // MARK: Notes

    func makeNote(quote: String?) -> Note {
        let q = quote?.collapsedWhitespace
        return Note(text: "",
                    quote: (q?.isEmpty ?? true) ? nil : q,
                    bookID: book.id,
                    bookTitle: displayTitle,
                    chapter: chapter,
                    fraction: fraction,
                    progress: progress,
                    locationLabel: positionText.isEmpty ? Format.percent(progress) : "\(positionText) · \(Format.percent(progress))")
    }

    func close() {
        library.publishStates()
        library.flush()
    }
}
