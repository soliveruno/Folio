import SwiftUI
import WebKit

/// WKWebView with "Highlight" and "Note" in the text-selection menu.
final class ReaderWebView: WKWebView {
    var onHighlight: (() -> Void)?
    var onNote: (() -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(folioHighlight(_:)) || action == #selector(folioNote(_:)) { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func folioHighlight(_ sender: Any?) { onHighlight?() }
    @objc func folioNote(_ sender: Any?) { onNote?() }
}

enum SelectionMenu {
    /// Adds Highlight / Note to the system text-selection menu (shared by EPUB and PDF views).
    static func install() {
        UIMenuController.shared.menuItems = [
            UIMenuItem(title: "Highlight", action: #selector(ReaderWebView.folioHighlight(_:))),
            UIMenuItem(title: "Note", action: #selector(ReaderWebView.folioNote(_:)))
        ]
    }
}

/// Avoids the retain cycle WKUserContentController creates with its message handlers.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

struct EPUBReaderView: UIViewRepresentable {
    let epub: EPUBBook
    let model: ReaderModel
    let css: String
    let direction: ReadingDirection
    let background: UIColor
    var onNote: () -> Void

    func makeCoordinator() -> EPUBCoordinator { EPUBCoordinator(epub: epub, model: model) }

    func makeUIView(context: Context) -> ReaderWebView {
        context.coordinator.onNote = onNote
        return context.coordinator.makeWebView()
    }

    func updateUIView(_ web: ReaderWebView, context: Context) {
        context.coordinator.onNote = onNote
        context.coordinator.apply(css: css, direction: direction, background: background)
    }

    static func dismantleUIView(_ web: ReaderWebView, coordinator: EPUBCoordinator) {
        coordinator.teardown()
    }
}

final class EPUBCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler,
                             UIGestureRecognizerDelegate, ReaderEngine {
    enum Target {
        case fraction(Double)
        case fragment(String)
        case highlight(UUID)
        case end

        var json: [String: Any] {
            switch self {
            case .fraction(let f): return ["type": "fraction", "value": f]
            case .fragment(let s): return ["type": "fragment", "value": s]
            case .highlight(let id): return ["type": "highlight", "value": id.uuidString]
            case .end: return ["type": "end"]
            }
        }
    }

    let epub: EPUBBook
    weak var model: ReaderModel?
    weak var web: ReaderWebView?
    var onNote: (() -> Void)?

    private var css = ""
    private var direction: ReadingDirection = .paged
    private var started = false
    private var loadedChapter = -1
    private var pending: Target = .fraction(0)
    private var ready = false
    private var pinchStart: Double = 100
    private var lastPinchApplied: Double = 0

    init(epub: EPUBBook, model: ReaderModel) {
        self.epub = epub
        self.model = model
        super.init()
        model.engine = self
    }

    func makeWebView() -> ReaderWebView {
        let ucc = WKUserContentController()
        ucc.add(WeakScriptHandler(self), name: "folio")
        ucc.addUserScript(WKUserScript(source: ReaderScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = ucc
        config.dataDetectorTypes = []
        config.suppressesIncrementalRendering = true

        let web = ReaderWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.isOpaque = false
        web.alpha = 0
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.showsHorizontalScrollIndicator = false
        web.scrollView.isDirectionalLockEnabled = true
        web.onHighlight = { [weak self] in self?.highlightSelection(color: .yellow) }
        web.onNote = { [weak self] in self?.onNote?() }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        web.addGestureRecognizer(tap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        web.addGestureRecognizer(pinch)

        SelectionMenu.install()
        self.web = web
        return web
    }

    func apply(css: String, direction: ReadingDirection, background: UIColor) {
        guard let web = web else { return }
        if web.backgroundColor != background {
            web.backgroundColor = background
            web.scrollView.backgroundColor = background
        }
        let paged = direction == .paged
        if web.scrollView.isPagingEnabled != paged || !started {
            web.scrollView.isPagingEnabled = paged
            web.scrollView.alwaysBounceHorizontal = paged
            web.scrollView.alwaysBounceVertical = !paged
            web.scrollView.showsVerticalScrollIndicator = !paged
            web.scrollView.decelerationRate = paged ? .fast : .normal
        }
        let changed = css != self.css || direction != self.direction
        self.css = css
        self.direction = direction

        if !started {
            started = true
            start()
        } else if changed, ready {
            let cfg: [String: Any] = ["css": css, "mode": direction.rawValue]
            web.evaluateJavaScript("__folio.configure(\(json(cfg)));", completionHandler: nil)
        }
    }

    func teardown() {
        web?.stopLoading()
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "folio")
    }

    private func start() {
        let last = epub.chapters.count - 1
        if let target = model?.initialTarget {
            switch target {
            case .highlight(let h): load(min(max(h.chapter, 0), last), .highlight(h.id))
            case .location(let c, let f): load(min(max(c, 0), last), .fraction(f))
            }
        } else {
            let s = model?.savedState ?? ReadingState()
            load(min(max(s.chapter, 0), last), .fraction(s.fraction))
        }
    }

    private func load(_ chapter: Int, _ target: Target) {
        guard let web = web, epub.chapters.indices.contains(chapter) else { return }
        pending = target
        loadedChapter = chapter
        ready = false
        web.alpha = 0
        if model?.hasSelection == true { model?.hasSelection = false }
        web.loadFileURL(epub.chapters[chapter], allowingReadAccessTo: epub.root)
    }

    private func go(chapter: Int, target: Target) {
        if chapter == loadedChapter, ready {
            web?.evaluateJavaScript("__folio.go(\(json(target.json)));", completionHandler: nil)
        } else {
            load(chapter, target)
        }
    }

    private func json(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: ReaderEngine

    func jump(toProgress p: Double) {
        let loc = epub.locate(progress: p)
        go(chapter: loc.chapter, target: .fraction(loc.fraction))
    }

    func jump(chapter: Int, fragment: String?) {
        go(chapter: chapter, target: fragment.map { .fragment($0) } ?? .fraction(0))
    }

    func jump(chapter: Int, fraction: Double) {
        go(chapter: chapter, target: .fraction(fraction))
    }

    func jump(toHighlight h: Highlight) {
        go(chapter: h.chapter, target: .highlight(h.id))
    }

    func highlightSelection(color: HighlightColor) {
        guard let web = web, let model = model else { return }
        let id = UUID()
        let chapter = loadedChapter
        let js = "__folio.highlightSelection('\(id.uuidString)', '\(color.rawValue)');"
        web.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self, let r = result as? [String: Any],
                  let s = (r["s"] as? NSNumber)?.intValue,
                  let e = (r["e"] as? NSNumber)?.intValue,
                  let text = r["text"] as? String else { return }
            let progress = model.progress
            model.annotations.add(Highlight(id: id, bookID: model.book.id, bookTitle: model.displayTitle,
                                            text: text, color: color, chapter: chapter,
                                            progress: progress,
                                            locationLabel: "\(self.epub.chapterTitle(chapter)) · \(Format.percent(progress))",
                                            start: s, end: e, rects: nil))
            model.hasSelection = false
            Haptics.tap()
        }
    }

    func removeHighlight(_ h: Highlight) {
        guard h.chapter == loadedChapter else { return }
        web?.evaluateJavaScript("__folio.removeHighlight('\(h.id.uuidString)');", completionHandler: nil)
    }

    func selectedText(_ completion: @escaping (String?) -> Void) {
        guard let web = web else { completion(nil); return }
        web.evaluateJavaScript("__folio.selectedText();") { result, _ in
            let s = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            completion((s?.isEmpty ?? true) ? nil : s)
        }
    }

    func clearSelection() {
        web?.evaluateJavaScript("__folio.clearSelection();", completionHandler: nil)
    }

    func zoom(in zoomIn: Bool) {
        let s = ReaderSettings.shared
        let v = min(max(s.fontScale + (zoomIn ? 10 : -10), ReaderSettings.fontRange.lowerBound),
                    ReaderSettings.fontRange.upperBound)
        s.fontScale = v
        model?.showHUD("Text \(Int(v))%")
    }

    // MARK: Chapter navigation

    private func nextChapter() {
        if loadedChapter < epub.chapters.count - 1 {
            load(loadedChapter + 1, .fraction(0))
        } else {
            model?.showHUD("End of book")
        }
    }

    private func previousChapter() {
        if loadedChapter > 0 { load(loadedChapter - 1, .end) }
    }

    // MARK: Gestures

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard let web = web, g.state == .ended, ready else { return }
        let p = g.location(in: web)
        web.evaluateJavaScript("__folio.tapAt(\(Double(p.x)), \(Double(p.y)));") { [weak self] result, _ in
            guard let self = self, let r = result as? String else { return }
            switch r {
            case "center": self.model?.toggleChrome()
            case "page": self.model?.setChrome(false)
            default: break
            }
        }
    }

    /// Pinch = zoom the text in or out (re-flows the book, like Apple Books).
    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        let s = ReaderSettings.shared
        switch g.state {
        case .began:
            pinchStart = s.fontScale
            lastPinchApplied = s.fontScale
        case .changed:
            let raw = pinchStart * Double(g.scale)
            let v = min(max((raw / 5).rounded() * 5, ReaderSettings.fontRange.lowerBound), ReaderSettings.fontRange.upperBound)
            model?.showHUD("Text \(Int(v))%")
            if abs(v - lastPinchApplied) >= 15 {
                lastPinchApplied = v
                s.fontScale = v
            }
        case .ended, .cancelled:
            let raw = pinchStart * Double(g.scale)
            let v = min(max((raw / 5).rounded() * 5, ReaderSettings.fontRange.lowerBound), ReaderSettings.fontRange.upperBound)
            if v != s.fontScale { s.fontScale = v }
            model?.showHUD("Text \(Int(v))%")
        default:
            break
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: Script messages

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let t = body["t"] as? String else { return }
        switch t {
        case "ready":
            handlePosition(body)
            reveal()
        case "pos":
            handlePosition(body)
        case "next":
            nextChapter()
        case "prev":
            previousChapter()
        case "sel":
            let has = (body["has"] as? Bool) ?? false
            if model?.hasSelection != has { model?.hasSelection = has }
        case "hl":
            if let s = body["id"] as? String, let id = UUID(uuidString: s) { model?.requestRemoveHighlight(id) }
        default:
            break
        }
    }

    private func reveal() {
        ready = true
        guard let web = web, web.alpha < 1 else { return }
        UIView.animate(withDuration: 0.18) { web.alpha = 1 }
    }

    private func handlePosition(_ body: [String: Any]) {
        let f = (body["f"] as? NSNumber)?.doubleValue ?? 0
        let page = (body["page"] as? NSNumber)?.intValue ?? 0
        let pages = max((body["pages"] as? NSNumber)?.intValue ?? 1, 1)
        let detail: String
        if direction == .paged {
            let left = max(pages - page - 1, 0)
            detail = left == 0 ? "Last page in chapter" : (left == 1 ? "1 page left in chapter" : "\(left) pages left in chapter")
        } else {
            detail = "\(Int((f * 100).rounded()))% of chapter"
        }
        model?.report(chapter: loadedChapter,
                      fraction: f,
                      progress: epub.progress(chapter: loadedChapter, fraction: f),
                      position: epub.chapterTitle(loadedChapter),
                      detail: detail)
    }

    // MARK: Navigation delegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let hls: [[String: Any]] = (model?.annotations.highlights(forBook: model?.book.id ?? "", chapter: loadedChapter) ?? [])
            .compactMap { (h: Highlight) -> [String: Any]? in
                guard let s = h.start, let e = h.end else { return nil }
                return ["id": h.id.uuidString, "s": s, "e": e, "c": h.color.rawValue]
            }
        let cfg: [String: Any] = ["css": css, "mode": direction.rawValue, "hls": hls, "target": pending.json]
        let chapter = loadedChapter
        webView.evaluateJavaScript("__folio.setup(\(json(cfg)));") { [weak self] _, error in
            // If the page couldn't run our script, show it anyway
            if error != nil { self?.reveal() }
        }
        // Safety net: never leave a chapter invisible
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self, self.loadedChapter == chapter, !self.ready else { return }
            self.reveal()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            if action.navigationType == .linkActivated { UIApplication.shared.open(url) }
            decisionHandler(.cancel)
            return
        }
        if action.navigationType == .linkActivated, url.isFileURL {
            let path = url.standardizedFileURL.path
            if let idx = epub.chapters.firstIndex(where: { $0.path == path }) {
                let target: Target = url.fragment.map { .fragment($0) } ?? .fraction(0)
                go(chapter: idx, target: target)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// If iOS kills the web content process (memory pressure), reload where we were.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let f = model?.fraction ?? 0
        load(max(loadedChapter, 0), .fraction(f))
    }
}
