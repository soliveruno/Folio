import SwiftUI
import PDFKit

/// PDFView with "Highlight" and "Note" in the text-selection menu.
final class ReaderPDFView: PDFView {
    var onHighlight: (() -> Void)?
    var onNote: (() -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(ReaderWebView.folioHighlight(_:)) || action == #selector(ReaderWebView.folioNote(_:)) {
            return currentSelection != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func folioHighlight(_ sender: Any?) { onHighlight?() }
    @objc func folioNote(_ sender: Any?) { onNote?() }
}

struct PDFReaderView: UIViewRepresentable {
    let model: ReaderModel
    let direction: ReadingDirection
    let background: UIColor
    var onNote: () -> Void

    func makeCoordinator() -> PDFCoordinator { PDFCoordinator(model: model) }

    func makeUIView(context: Context) -> ReaderPDFView {
        context.coordinator.onNote = onNote
        return context.coordinator.makeView()
    }

    func updateUIView(_ view: ReaderPDFView, context: Context) {
        context.coordinator.onNote = onNote
        context.coordinator.apply(direction: direction, background: background)
    }

    static func dismantleUIView(_ view: ReaderPDFView, coordinator: PDFCoordinator) {
        coordinator.teardown()
    }
}

final class PDFCoordinator: NSObject, ReaderEngine, UIGestureRecognizerDelegate {
    weak var model: ReaderModel?
    weak var view: ReaderPDFView?
    var onNote: (() -> Void)?
    private var document: PDFDocument?
    private var direction: ReadingDirection?
    private var lastReported = -1
    private static let prefix = "folio:"

    init(model: ReaderModel) {
        self.model = model
        super.init()
        model.engine = self
    }

    func makeView() -> ReaderPDFView {
        let v = ReaderPDFView()
        v.autoScales = true
        v.displaysPageBreaks = true
        v.pageShadowsEnabled = true
        v.pageBreakMargins = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        v.onHighlight = { [weak self] in self?.highlightSelection(color: .yellow) }
        v.onNote = { [weak self] in self?.onNote?() }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: v)
        nc.addObserver(self, selector: #selector(selectionChanged(_:)), name: .PDFViewSelectionChanged, object: v)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        v.addGestureRecognizer(tap)

        SelectionMenu.install()
        view = v

        if let doc = PDFDocument(url: model?.book.url ?? URL(fileURLWithPath: "/")) {
            document = doc
            v.document = doc
            if let id = model?.book.id {
                for h in model?.annotations.highlights(forBook: id) ?? [] { addAnnotations(for: h) }
            }
            let toc = outline(of: doc)
            // Published state is updated after the current view update finishes
            DispatchQueue.main.async { [weak self] in
                self?.model?.pageCount = doc.pageCount
                self?.model?.toc = toc
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.model?.errorText = "This PDF couldn't be opened."
            }
        }
        return v
    }

    func apply(direction d: ReadingDirection, background: UIColor) {
        guard let v = view else { return }
        if v.backgroundColor != background { v.backgroundColor = background }
        guard d != direction else { return }
        let first = direction == nil
        let page = v.currentPage
        direction = d
        if d == .paged {
            v.displayMode = .singlePage
            v.displayDirection = .horizontal
            v.usePageViewController(true, withViewOptions: [UIPageViewController.OptionsKey.interPageSpacing: 18])
        } else {
            v.usePageViewController(false, withViewOptions: nil)
            v.displayMode = .singlePageContinuous
            v.displayDirection = .vertical
        }
        v.autoScales = true
        v.maxScaleFactor = 6

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if first { self.restoreInitialPosition() } else if let p = page { v.go(to: p) }
            self.lastReported = -1
            self.report()
        }
    }

    func teardown() {
        NotificationCenter.default.removeObserver(self)
    }

    private func restoreInitialPosition() {
        guard let v = view, let doc = document, doc.pageCount > 0 else { return }
        let last = doc.pageCount - 1
        if let target = model?.initialTarget {
            switch target {
            case .highlight(let h): jump(toHighlight: h)
            case .location(let c, _): if let p = doc.page(at: min(max(c, 0), last)) { v.go(to: p) }
            }
        } else {
            let saved = min(max(model?.savedState.chapter ?? 0, 0), last)
            if saved > 0, let p = doc.page(at: saved) { v.go(to: p) }
        }
    }

    private func outline(of doc: PDFDocument) -> [TOCEntry] {
        var out: [TOCEntry] = []
        func walk(_ node: PDFOutline, level: Int) {
            for i in 0..<node.numberOfChildren {
                guard out.count < 1500, let child = node.child(at: i) else { continue }
                if let page = child.destination?.page {
                    let title = (child.label ?? "").collapsedWhitespace
                    out.append(TOCEntry(id: out.count, title: title.isEmpty ? "Untitled" : title,
                                        chapter: doc.index(for: page), fragment: nil, level: level))
                }
                if level < 4 { walk(child, level: level + 1) }
            }
        }
        if let root = doc.outlineRoot { walk(root, level: 1) }
        return out
    }

    // MARK: Position

    @objc private func pageChanged(_ note: Notification) { report() }

    private func report() {
        guard let v = view, let doc = document, let page = v.currentPage, doc.pageCount > 0 else { return }
        let idx = doc.index(for: page)
        guard idx != lastReported else { return }
        lastReported = idx
        let count = doc.pageCount
        let left = count - idx - 1
        model?.report(chapter: idx,
                      fraction: 0,
                      progress: Double(idx + 1) / Double(count),
                      position: "Page \(idx + 1) of \(count)",
                      detail: left == 0 ? "Last page" : (left == 1 ? "1 page left" : "\(left) pages left"))
    }

    @objc private func selectionChanged(_ note: Notification) {
        let text = view?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let has = !text.isEmpty
        if model?.hasSelection != has { model?.hasSelection = has }
    }

    // MARK: ReaderEngine

    private func go(page index: Int) {
        guard let v = view, let doc = document, doc.pageCount > 0 else { return }
        if let p = doc.page(at: min(max(index, 0), doc.pageCount - 1)) { v.go(to: p) }
    }

    func jump(toProgress p: Double) {
        guard let doc = document, doc.pageCount > 0 else { return }
        go(page: Int((p * Double(doc.pageCount) - 0.0001).rounded(.up)) - 1)
    }

    func jump(chapter: Int, fragment: String?) { go(page: chapter) }
    func jump(chapter: Int, fraction: Double) { go(page: chapter) }

    func jump(toHighlight h: Highlight) {
        guard let v = view, let doc = document else { return }
        if let r = h.rects?.first, let page = doc.page(at: r.page), v.displayMode == .singlePageContinuous {
            v.go(to: r.rect.insetBy(dx: 0, dy: -80), on: page)
        } else {
            go(page: h.chapter)
        }
    }

    func highlightSelection(color: HighlightColor) {
        guard let v = view, let doc = document, let model = model, let sel = v.currentSelection else { return }
        let text = (sel.string ?? "").collapsedWhitespace
        guard !text.isEmpty else { return }
        var rects: [PDFMarkRect] = []
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                if b.width > 0.5, b.height > 0.5 { rects.append(PDFMarkRect(page: doc.index(for: page), rect: b)) }
            }
        }
        guard let first = rects.first else { return }
        let h = Highlight(bookID: model.book.id, bookTitle: model.displayTitle, text: text, color: color,
                          chapter: first.page,
                          progress: Double(first.page + 1) / Double(max(doc.pageCount, 1)),
                          locationLabel: "Page \(first.page + 1)",
                          start: nil, end: nil, rects: rects)
        model.annotations.add(h)
        addAnnotations(for: h)
        v.clearSelection()
        model.hasSelection = false
        Haptics.tap()
    }

    func removeHighlight(_ h: Highlight) {
        guard let doc = document else { return }
        let name = Self.prefix + h.id.uuidString
        let pages = Set((h.rects ?? []).map { $0.page })
        for i in pages {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where a.userName == name { page.removeAnnotation(a) }
        }
    }

    func selectedText(_ completion: @escaping (String?) -> Void) {
        let s = view?.currentSelection?.string?.collapsedWhitespace
        completion((s?.isEmpty ?? true) ? nil : s)
    }

    func clearSelection() { view?.clearSelection() }

    func zoom(in zoomIn: Bool) {
        guard let v = view else { return }
        let fit = v.scaleFactorForSizeToFit
        v.autoScales = false
        let target = v.scaleFactor * (zoomIn ? 1.25 : 0.8)
        v.scaleFactor = min(max(target, fit > 0 ? fit : v.minScaleFactor), v.maxScaleFactor)
        let pct = fit > 0 ? Int((v.scaleFactor / fit * 100).rounded()) : 100
        model?.showHUD("Zoom \(pct)%")
    }

    private func addAnnotations(for h: Highlight) {
        guard let doc = document else { return }
        for r in h.rects ?? [] {
            guard let page = doc.page(at: r.page) else { continue }
            let a = PDFAnnotation(bounds: r.rect, forType: .highlight, withProperties: nil)
            a.color = h.color.uiColor.withAlphaComponent(0.45)
            a.userName = Self.prefix + h.id.uuidString
            page.addAnnotation(a)
        }
    }

    // MARK: Taps

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard let v = view, g.state == .ended else { return }
        let pt = g.location(in: v)
        if let page = v.page(for: pt, nearest: false) {
            let p = v.convert(pt, to: page)
            if let a = page.annotation(at: p), let name = a.userName, name.hasPrefix(Self.prefix),
               let id = UUID(uuidString: String(name.dropFirst(Self.prefix.count))) {
                model?.requestRemoveHighlight(id)
                return
            }
        }
        if let s = v.currentSelection?.string, !s.isEmpty { return }
        if direction == .paged {
            let w = v.bounds.width
            if pt.x < w * 0.2 {
                if v.canGoToPreviousPage { v.goToPreviousPage(nil) }
                model?.setChrome(false)
                return
            }
            if pt.x > w * 0.8 {
                if v.canGoToNextPage { v.goToNextPage(nil) }
                model?.setChrome(false)
                return
            }
        }
        model?.toggleChrome()
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
