import SwiftUI

enum ReaderSheet: Identifiable {
    case contents, appearance, music, nowPlaying
    case note(Note)

    var id: String {
        switch self {
        case .contents: return "contents"
        case .appearance: return "appearance"
        case .music: return "music"
        case .nowPlaying: return "nowPlaying"
        case .note(let n): return "note-\(n.id.uuidString)"
        }
    }
}

struct ReaderScreen: View {
    @StateObject private var model: ReaderModel
    @ObservedObject private var settings = ReaderSettings.shared
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var annotations: AnnotationStore
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var epub: EPUBBook?
    @State private var sheet: ReaderSheet?
    @State private var scrub: Double?

    init(request: ReaderRequest, library: LibraryStore, annotations: AnnotationStore) {
        _model = StateObject(wrappedValue: ReaderModel(book: request.book, target: request.target,
                                                       library: library, annotations: annotations))
    }

    private var theme: ReaderTheme { settings.theme }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            content
            if !model.chromeVisible && model.errorText == nil {
                quietProgress
            }
            if let hud = model.hud {
                HUDView(text: hud)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if model.chromeVisible {
                topBar.transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) { bottomArea }
        .statusBar(hidden: !model.chromeVisible)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .animation(.easeInOut(duration: 0.22), value: model.chromeVisible)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.hasSelection)
        .animation(.easeOut(duration: 0.15), value: model.hud)
        .sheet(item: $sheet) { s in sheetContent(s) }
        .confirmationDialog("Highlight", isPresented: Binding(
            get: { model.highlightToRemove != nil },
            set: { if !$0 { model.highlightToRemove = nil } }),
                            titleVisibility: .hidden, presenting: model.highlightToRemove) { h in
            Button("Add Note") { sheet = .note(model.makeNote(quote: h.text)) }
            Button("Copy Text") { UIPasteboard.general.string = h.text }
            Button("Remove Highlight", role: .destructive) { model.removeHighlight(h) }
        }
        .task { await loadIfNeeded() }
        .onDisappear { model.close() }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let error = model.errorText {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Palette.accent)
                Text(error).foregroundStyle(theme.foreground)
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
            }
        } else {
            switch model.book.kind {
            case .pdf:
                PDFReaderView(model: model,
                              direction: settings.direction,
                              background: theme.pdfBackground,
                              onNote: newNote)
                    .ignoresSafeArea()
            case .epub:
                if let epub = epub {
                    EPUBReaderView(epub: epub,
                                   model: model,
                                   css: settings.css,
                                   direction: settings.direction,
                                   background: theme.uiBackground,
                                   onNote: newNote)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(theme.foreground)
                }
            }
        }
    }

    /// Always-visible reading position while the controls are hidden.
    private var quietProgress: some View {
        VStack {
            Spacer()
            Text(Format.percent(model.progress))
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(theme.foreground.opacity(0.45))
                .padding(.bottom, 8)
        }
        .allowsHitTesting(false)
    }

    // MARK: Top bar

    private var topBar: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(model.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !model.positionText.isEmpty {
                    Text(model.positionText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 104)

            HStack(spacing: 0) {
                ChromeIcon(symbol: "chevron.down") { dismiss() }
                ChromeIcon(symbol: "list.bullet") { sheet = .contents }
                Spacer()
                ChromeIcon(symbol: player.isPlaying ? "music.note" : "music.note.list",
                           tint: player.isPlaying ? Palette.accent : nil) { sheet = .music }
                ChromeIcon(symbol: "textformat.size") { sheet = .appearance }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial, ignoresSafeAreaEdges: .top)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    // MARK: Bottom area

    private var bottomArea: some View {
        VStack(spacing: 10) {
            if model.hasSelection {
                selectionBar.transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack {
                Spacer()
                noteButton
            }
            .padding(.horizontal, 14)
            if model.chromeVisible {
                bottomBar.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// The small note button that lives in the corner.
    private var noteButton: some View {
        Button(action: newNote) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 42, height: 42)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        }
        .buttonStyle(PressableStyle())
        .opacity(model.chromeVisible ? 1 : 0.7)
        .accessibilityLabel("Write a note")
    }

    private var selectionBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "highlighter")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(HighlightColor.allCases) { c in
                Button { model.engine?.highlightSelection(color: c) } label: {
                    Circle()
                        .fill(c.color)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1.5))
                }
                .accessibilityLabel("Highlight \(c.rawValue)")
            }
            Divider().frame(height: 24)
            Button(action: newNote) {
                Image(systemName: "note.text.badge.plus")
                    .font(.system(size: 18, weight: .medium))
            }
            Button {
                model.engine?.selectedText { t in
                    guard let t = t else { return }
                    UIPasteboard.general.string = t
                    model.showHUD("Copied")
                }
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 16, weight: .medium))
            }
        }
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if player.current != nil {
                ReaderNowPlayingStrip { sheet = .nowPlaying }
            }
            HStack(spacing: 4) {
                Text(scrub.map { model.label(forProgress: $0) } ?? model.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                ChromeIcon(symbol: "minus.magnifyingglass", size: 34) { model.engine?.zoom(in: false) }
                ChromeIcon(symbol: "plus.magnifyingglass", size: 34) { model.engine?.zoom(in: true) }
            }
            HStack(spacing: 12) {
                Slider(value: Binding(get: { scrub ?? model.progress }, set: { scrub = $0 }), in: 0...1) { editing in
                    if !editing, let s = scrub {
                        model.jump(toProgress: s)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { scrub = nil }
                    }
                }
                .tint(Palette.accent)
                Text(Format.percent(scrub ?? model.progress))
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    // MARK: Actions

    private func newNote() {
        guard let engine = model.engine else {
            sheet = .note(model.makeNote(quote: nil))
            return
        }
        engine.selectedText { quote in
            sheet = .note(model.makeNote(quote: quote))
        }
    }

    @ViewBuilder private func sheetContent(_ s: ReaderSheet) -> some View {
        switch s {
        case .contents:
            ContentsSheet(model: model, onEditNote: { n in
                sheet = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { sheet = .note(n) }
            })
            .environmentObject(annotations)
        case .appearance:
            AppearanceSheet(model: model)
        case .music:
            MusicSheet()
                .environmentObject(player)
                .environmentObject(downloads)
        case .nowPlaying:
            NowPlayingView().environmentObject(player)
        case .note(let n):
            NoteEditorView(note: n,
                           onSave: { annotations.upsert($0) },
                           onDelete: annotations.contains(note: n) ? { annotations.remove(n) } as (() -> Void)? : nil)
        }
    }

    private func loadIfNeeded() async {
        guard model.book.kind == .epub, epub == nil else { return }
        let url = model.book.url
        do {
            let opened = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<EPUBBook, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { cont.resume(returning: try EPUBBook.open(url)) } catch { cont.resume(throwing: error) }
                }
            }
            model.attach(epub: opened)
            epub = opened
        } catch {
            model.errorText = error.localizedDescription
        }
    }
}

// MARK: - Small pieces

struct ChromeIcon: View {
    let symbol: String
    var tint: Color?
    var size: CGFloat = 44
    let action: () -> Void

    init(symbol: String, tint: Color? = nil, size: CGFloat = 44, action: @escaping () -> Void) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint ?? Color.primary)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct HUDView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
    }
}

struct ReaderNowPlayingStrip: View {
    @EnvironmentObject private var player: PlayerModel
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    ArtworkView(image: player.info?.thumbnail ?? player.artwork, size: 34, corner: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(player.title).font(.footnote.weight(.semibold)).lineLimit(1)
                        Text(player.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            Button(action: player.previous) {
                Image(systemName: "backward.fill").frame(width: 34, height: 34)
            }
            Button(action: player.togglePlay) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 38, height: 34)
            }
            Button { player.next() } label: {
                Image(systemName: "forward.fill").frame(width: 34, height: 34)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.leading, 7)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottom) {
            ClockProgressLine(clock: player.clock).padding(.horizontal, 12)
        }
    }
}

// MARK: - Contents / highlights / notes for the open book

struct ContentsSheet: View {
    @ObservedObject var model: ReaderModel
    var onEditNote: (Note) -> Void
    @EnvironmentObject private var annotations: AnnotationStore
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    private var currentEntryID: Int? {
        model.toc.last(where: { $0.chapter <= model.chapter })?.id
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("Section", selection: $tab) {
                    Text("Contents").tag(0)
                    Text("Highlights").tag(1)
                    Text("Notes").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                switch tab {
                case 0: contents
                case 1: highlights
                default: notes
                }
            }
            .navigationTitle(model.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.font(.body.weight(.semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
        .tint(Palette.accent)
    }

    private var contents: some View {
        ScrollViewReader { proxy in
            List {
                if model.toc.isEmpty {
                    empty(symbol: "list.bullet", text: model.book.kind == .pdf
                          ? "This PDF has no table of contents.\nUse the progress bar to jump anywhere."
                          : "This book has no table of contents.")
                }
                ForEach(model.toc) { entry in
                    Button {
                        model.jump(to: entry)
                        dismiss()
                    } label: {
                        HStack {
                            Text(entry.title)
                                .font(entry.level == 1 ? .body : .subheadline)
                                .fontWeight(entry.id == currentEntryID ? .semibold : .regular)
                                .foregroundStyle(entry.id == currentEntryID ? Palette.accent : Color.primary)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Text(trailing(for: entry))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, CGFloat(min(entry.level - 1, 4)) * 16)
                    }
                    .id(entry.id)
                }
            }
            .listStyle(.plain)
            .onAppear {
                if let id = currentEntryID {
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func trailing(for entry: TOCEntry) -> String {
        if model.book.kind == .pdf { return "\(entry.chapter + 1)" }
        guard let e = model.epub, e.starts.indices.contains(entry.chapter) else { return "" }
        return Format.percent(e.starts[entry.chapter])
    }

    private var highlights: some View {
        let items = annotations.highlights(forBook: model.book.id)
        return List {
            if items.isEmpty {
                empty(symbol: "highlighter", text: "Select text and tap a color to highlight it.")
            }
            ForEach(items) { h in
                Button {
                    model.jump(to: h)
                    dismiss()
                } label: { HighlightRow(highlight: h) }
                .swipeActions {
                    Button(role: .destructive) { model.removeHighlight(h) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var notes: some View {
        let items = annotations.notes(forBook: model.book.id)
        return List {
            if items.isEmpty {
                empty(symbol: "square.and.pencil", text: "Tap the pencil button in the corner of the page to write a note.")
            }
            ForEach(items) { n in
                Button {
                    if n.chapter != nil {
                        model.jump(to: n)
                        dismiss()
                    } else {
                        onEditNote(n)
                    }
                } label: { NoteRow(note: n) }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { annotations.remove(n) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button { onEditNote(n) } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.plain)
    }

    private func empty(symbol: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.accent)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowSeparator(.hidden)
    }
}

// MARK: - Appearance (direction, theme, zoom, font)

struct AppearanceSheet: View {
    let model: ReaderModel
    @ObservedObject private var settings = ReaderSettings.shared
    @Environment(\.dismiss) private var dismiss

    private var isEPUB: Bool { model.book.kind == .epub }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    section("Reading direction") {
                        HStack(spacing: 12) {
                            ForEach(ReadingDirection.allCases) { d in
                                DirectionCard(direction: d, selected: settings.direction == d) {
                                    settings.direction = d
                                    Haptics.tap()
                                }
                            }
                        }
                    }

                    section("Theme") {
                        HStack(spacing: 12) {
                            ForEach(ReaderTheme.allCases) { t in
                                Button { settings.theme = t } label: {
                                    VStack(spacing: 6) {
                                        Text("Aa")
                                            .font(.system(size: 20, weight: .semibold, design: .serif))
                                            .foregroundColor(t.foreground)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 56)
                                            .background(t.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(settings.theme == t ? Palette.accent : Color.primary.opacity(0.15),
                                                        lineWidth: settings.theme == t ? 2.5 : 1))
                                        Text(t.name)
                                            .font(.caption)
                                            .foregroundStyle(settings.theme == t ? Palette.accent : Color.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    section(isEPUB ? "Text size" : "Zoom") {
                        HStack {
                            stepButton(symbol: isEPUB ? "textformat.size.smaller" : "minus.magnifyingglass") {
                                model.engine?.zoom(in: false)
                            }
                            Spacer()
                            Text(isEPUB ? "\(Int(settings.fontScale))%" : "Pinch or tap")
                                .font(.headline.monospacedDigit())
                            Spacer()
                            stepButton(symbol: isEPUB ? "textformat.size.larger" : "plus.magnifyingglass") {
                                model.engine?.zoom(in: true)
                            }
                        }
                        Text("Tip: pinch with two fingers on the page to zoom in and out.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if isEPUB {
                        section("Font") {
                            Picker("Font", selection: $settings.font) {
                                ForEach(ReaderFont.allCases) { Text($0.name).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        section("Line spacing") {
                            HStack(spacing: 12) {
                                Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                                Slider(value: $settings.lineSpacing, in: 1.2...2.2, step: 0.1)
                                    .tint(Palette.accent)
                                Image(systemName: "text.justify").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.font(.body.weight(.semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
        .tint(Palette.accent)
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func stepButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 64, height: 44)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct DirectionCard: View {
    let direction: ReadingDirection
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: direction.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(selected ? Palette.accent : Color.secondary)
                Text(direction.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(direction.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.primary.opacity(selected ? 0.10 : 0.05),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? Palette.accent : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}
