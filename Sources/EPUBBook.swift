import Foundation
import ZIPFoundation

enum EPUBError: LocalizedError {
    case invalid
    var errorDescription: String? { "This EPUB couldn't be opened." }
}

struct TOCEntry: Identifiable, Hashable {
    let id: Int
    let title: String
    let chapter: Int
    let fragment: String?
    let level: Int
}

/// An unzipped EPUB: metadata, reading order, table of contents and the relative
/// size of every chapter (used to turn a chapter position into a whole-book percentage).
struct EPUBBook {
    let root: URL
    let title: String
    let author: String
    let chapters: [URL]
    let coverURL: URL?
    let toc: [TOCEntry]
    /// Share of the whole book for each chapter (sums to 1)
    let sizes: [Double]
    /// Where each chapter starts in the whole book (0…1)
    let starts: [Double]
    let chapterTitles: [String]

    // MARK: Progress math

    func progress(chapter: Int, fraction: Double) -> Double {
        guard sizes.indices.contains(chapter) else { return 0 }
        let f = min(max(fraction, 0), 1)
        return min(1, starts[chapter] + sizes[chapter] * f)
    }

    func locate(progress p: Double) -> (chapter: Int, fraction: Double) {
        let p = min(max(p, 0), 1)
        for i in chapters.indices where p <= starts[i] + sizes[i] || i == chapters.count - 1 {
            let f = sizes[i] > 0 ? (p - starts[i]) / sizes[i] : 0
            return (i, min(max(f, 0), 1))
        }
        return (0, 0)
    }

    func chapterTitle(_ index: Int) -> String {
        chapterTitles.indices.contains(index) ? chapterTitles[index] : "Chapter \(index + 1)"
    }

    // MARK: Opening

    private static let unzipLock = NSLock()

    private static var cacheRoot: URL {
        AppPaths.caches.appendingPathComponent("epub", isDirectory: true)
    }

    private static func folder(for file: URL) -> URL {
        cacheRoot.appendingPathComponent(file.lastPathComponent, isDirectory: true)
    }

    static func clearCache(for file: URL) {
        try? FileManager.default.removeItem(at: folder(for: file))
    }

    static func open(_ file: URL) throws -> EPUBBook {
        let fm = FileManager.default
        let root = folder(for: file)
        let containerURL = root.appendingPathComponent("META-INF/container.xml")

        // Unzip once (serialized so the library and the reader never unzip the same book twice)
        unzipLock.lock()
        defer { unzipLock.unlock() }
        if !fm.fileExists(atPath: containerURL.path) {
            try? fm.removeItem(at: root)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.unzipItem(at: file, to: root)
        }

        let container = ContainerParser.parse(try Data(contentsOf: containerURL))
        guard let opfPath = container.opfPath else { throw EPUBError.invalid }
        let opfURL = root.appendingPathComponent(opfPath)
        let opfDir = opfURL.deletingLastPathComponent()
        let opf = OPFParser.parse(try Data(contentsOf: opfURL))

        let chapters = opf.spine.compactMap { opf.manifest[$0] }.map { resolve($0.href, base: opfDir) }
        guard !chapters.isEmpty else { throw EPUBError.invalid }

        // EPUB 3 marks the cover with properties="cover-image"; EPUB 2 uses <meta name="cover">
        let coverItem = opf.manifest.values.first { $0.properties.contains("cover-image") }
            ?? opf.coverID.flatMap { opf.manifest[$0] }
        let cover = coverItem.flatMap { $0.mediaType.hasPrefix("image") ? resolve($0.href, base: opfDir) : nil }

        // Chapter weights from file sizes – cheap and good enough for a percentage
        var raw: [Double] = chapters.map { url in
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 0
            return max(size, 512)
        }
        let total = raw.reduce(0, +)
        raw = raw.map { $0 / total }
        var starts: [Double] = []
        var acc = 0.0
        for s in raw { starts.append(acc); acc += s }

        // Table of contents: EPUB 3 nav document first, then EPUB 2 NCX
        var entries: [(title: String, href: String, level: Int)] = []
        var tocBase = opfDir
        if let nav = opf.manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }) {
            let navURL = resolve(nav.href, base: opfDir)
            if let data = try? Data(contentsOf: navURL) {
                entries = NavParser.parse(data).entries
                tocBase = navURL.deletingLastPathComponent()
            }
        }
        if entries.isEmpty {
            let ncxItem = opf.tocID.flatMap { opf.manifest[$0] }
                ?? opf.manifest.values.first { $0.mediaType == "application/x-dtbncx+xml" }
            if let ncx = ncxItem {
                let ncxURL = resolve(ncx.href, base: opfDir)
                if let data = try? Data(contentsOf: ncxURL) {
                    entries = NCXParser.parse(data).entries
                    tocBase = ncxURL.deletingLastPathComponent()
                }
            }
        }
        var chapterIndex: [String: Int] = [:]
        for (i, url) in chapters.enumerated() where chapterIndex[url.path] == nil { chapterIndex[url.path] = i }
        var toc: [TOCEntry] = []
        for e in entries {
            let parts = e.href.components(separatedBy: "#")
            guard let first = parts.first, !first.isEmpty,
                  let ch = chapterIndex[resolve(first, base: tocBase).path] else { continue }
            let title = e.title.collapsedWhitespace
            toc.append(TOCEntry(id: toc.count,
                                title: title.isEmpty ? "Untitled" : title,
                                chapter: ch,
                                fragment: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil,
                                level: max(e.level, 1)))
        }

        let bookTitle = opf.title.isEmpty ? file.deletingPathExtension().lastPathComponent : opf.title
        var titles: [String] = []
        for i in chapters.indices {
            if let exact = toc.first(where: { $0.chapter == i }) {
                titles.append(exact.title)
            } else if let before = toc.last(where: { $0.chapter < i }) {
                titles.append(before.title)
            } else {
                titles.append(i == 0 ? bookTitle : "Section \(i + 1)")
            }
        }

        return EPUBBook(root: root,
                        title: bookTitle,
                        author: opf.creator,
                        chapters: chapters,
                        coverURL: cover,
                        toc: toc,
                        sizes: raw,
                        starts: starts,
                        chapterTitles: titles)
    }

    private static func resolve(_ href: String, base: URL) -> URL {
        let clean = href.components(separatedBy: "#")[0]
        return base.appendingPathComponent(clean.removingPercentEncoding ?? clean).standardizedFileURL
    }
}

// MARK: - XML parsing

private func localName(_ name: String) -> String {
    name.components(separatedBy: ":").last ?? name
}

private final class ContainerParser: NSObject, XMLParserDelegate {
    var opfPath: String?

    static func parse(_ data: Data) -> ContainerParser {
        let p = ContainerParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return p
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if localName(elementName) == "rootfile", opfPath == nil {
            opfPath = attributes["full-path"]
        }
    }
}

private final class OPFParser: NSObject, XMLParserDelegate {
    struct Item {
        let href: String
        let mediaType: String
        let properties: String
    }

    var manifest: [String: Item] = [:]
    var spine: [String] = []
    var title = ""
    var creator = ""
    var coverID: String?
    var tocID: String?
    private var text = ""

    static func parse(_ data: Data) -> OPFParser {
        let p = OPFParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return p
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch localName(elementName) {
        case "item":
            if let id = a["id"], let href = a["href"] {
                manifest[id] = Item(href: href,
                                    mediaType: a["media-type"] ?? "",
                                    properties: a["properties"] ?? "")
            }
        case "itemref":
            if let id = a["idref"], a["linear"] != "no" { spine.append(id) }
        case "spine":
            tocID = a["toc"]
        case "meta":
            if a["name"] == "cover" { coverID = a["content"] }
        default:
            break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch localName(elementName) {
        case "title" where title.isEmpty: title = value
        case "creator" where creator.isEmpty: creator = value
        default: break
        }
        text = ""
    }
}

/// EPUB 3 navigation document: <nav epub:type="toc"><ol><li><a href>…
private final class NavParser: NSObject, XMLParserDelegate {
    var entries: [(title: String, href: String, level: Int)] = []
    private var inTOC = false
    private var done = false
    private var olDepth = 0
    private var href: String?
    private var text = ""

    static func parse(_ data: Data) -> NavParser {
        let p = NavParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return p
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch localName(elementName) {
        case "nav":
            let type = a["epub:type"] ?? a["type"] ?? a["role"] ?? ""
            if !done, type.contains("toc") { inTOC = true }
        case "ol" where inTOC:
            olDepth += 1
        case "a" where inTOC:
            href = a["href"]
            text = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if href != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        switch localName(elementName) {
        case "a" where inTOC:
            if let h = href { entries.append((text, h, olDepth)) }
            href = nil
        case "ol" where inTOC:
            olDepth -= 1
        case "nav" where inTOC:
            inTOC = false
            done = true
        default:
            break
        }
    }
}

/// EPUB 2 NCX: <navPoint><navLabel><text>…</text></navLabel><content src=…/>
private final class NCXParser: NSObject, XMLParserDelegate {
    var entries: [(title: String, href: String, level: Int)] = []
    private var depth = 0
    private var inLabel = false
    private var inText = false
    private var label = ""

    static func parse(_ data: Data) -> NCXParser {
        let p = NCXParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return p
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch localName(elementName) {
        case "navPoint":
            depth += 1
            label = ""
        case "navLabel":
            inLabel = true
        case "text" where inLabel:
            inText = true
            label = ""
        case "content":
            if depth > 0, let src = a["src"] { entries.append((label, src, depth)) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { label += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        switch localName(elementName) {
        case "navPoint": depth -= 1
        case "navLabel": inLabel = false
        case "text": inText = false
        default: break
        }
    }
}
