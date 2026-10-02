import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var annotations: AnnotationStore
    @EnvironmentObject private var router: AppRouter
    @State private var showImporter = false
    @State private var sort: Sort = .recent
    @State private var pendingDelete: Book?

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Recent", title = "Title", progress = "Progress"
        var id: String { rawValue }
    }

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 18, alignment: .top)]

    private var sortedBooks: [Book] {
        switch sort {
        case .title:
            return library.books.sorted {
                library.title(of: $0).localizedStandardCompare(library.title(of: $1)) == .orderedAscending
            }
        case .progress:
            return library.books.sorted { library.state(for: $0).progress > library.state(for: $1).progress }
        case .recent:
            return library.books.sorted {
                (library.state(for: $0).lastOpened ?? .distantPast) > (library.state(for: $1).lastOpened ?? .distantPast)
            }
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                if library.books.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 26) {
                        if let recent = library.recentBook {
                            ContinueReadingCard(book: recent) { router.open(recent) }
                        }
                        HStack {
                            Text("All Books")
                                .font(.title3.weight(.semibold))
                            Text("\(library.books.count)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                            ForEach(sortedBooks) { book in
                                Button { router.open(book) } label: { BookCell(book: book) }
                                    .buttonStyle(PressableStyle())
                                    .contextMenu {
                                        Button { router.open(book) } label: { Label("Open", systemImage: "book") }
                                        Button { library.resetProgress(book) } label: {
                                            Label("Reset Progress", systemImage: "arrow.counterclockwise")
                                        }
                                        Button(role: .destructive) { pendingDelete = book } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Library")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.pdf, .epubBook],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Importer.importFiles(urls) { library.refresh() }
                }
            }
            .confirmationDialog("Delete this book?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { book in
                Button("Delete Book", role: .destructive) {
                    annotations.removeHighlights(forBook: book.id)
                    library.delete(book)
                }
            } message: { book in
                Text("“\(library.title(of: book))” and its highlights will be removed. Your notes are kept.")
            }
            .withMiniPlayer()
        }
        .navigationViewStyle(.stack)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Palette.accent)
            Text("Your library is empty")
                .font(.title3.weight(.semibold))
            Text("Add EPUB or PDF books from Files, or share them\nto Folio from another app.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button { showImporter = true } label: {
                Label("Add Books", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Palette.accent, in: Capsule())
                    .foregroundColor(.black)
            }
            .padding(.top, 6)
        }
        .padding(.top, 130)
        .frame(maxWidth: .infinity)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Covers

struct BookCoverView: View {
    let book: Book
    var title: String
    var author: String?
    @EnvironmentObject private var library: LibraryStore
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                GeneratedCover(title: title, author: author, isPDF: book.kind == .pdf)
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.07)))
        .shadow(color: .black.opacity(0.45), radius: 6, x: 0, y: 4)
        .task(id: book.id) {
            if image == nil { image = CoverCache.shared.cached(book) }
            guard image == nil else { return }
            let (img, meta) = await CoverCache.shared.cover(for: book)
            if let m = meta { library.setMeta(m, for: book) }
            image = img
        }
    }
}

/// Typographic cover for books without artwork.
struct GeneratedCover: View {
    let title: String
    let author: String?
    let isPDF: Bool

    private var hue: Double {
        var h: UInt64 = 5381
        for b in title.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Double(h % 360) / 360
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.42),
                                    Color(hue: hue, saturation: 0.55, brightness: 0.22)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(Color.white.opacity(0.5)).frame(width: 22, height: 2)
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundColor(.white)
                    .lineLimit(5)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                HStack {
                    if let a = author {
                        Text(a).font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.75)).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Text(isPDF ? "PDF" : "EPUB")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.4)))
                }
            }
            .padding(11)
        }
    }
}

struct BookProgressBar: View {
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(Palette.accent).frame(width: max(geo.size.width * min(max(progress, 0), 1), progress > 0 ? 3 : 0))
            }
        }
        .frame(height: 3)
    }
}

struct BookCell: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        let state = library.state(for: book)
        VStack(alignment: .leading, spacing: 8) {
            BookCoverView(book: book, title: library.title(of: book), author: library.author(of: book))
            Text(library.title(of: book))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if state.lastOpened == nil {
                Text("NEW")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.accent, in: Capsule())
            } else if state.progress >= 0.995 {
                Label("Finished", systemImage: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.accent)
            } else {
                HStack(spacing: 6) {
                    BookProgressBar(progress: state.progress)
                    Text(Format.percent(state.progress))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
    }
}

struct ContinueReadingCard: View {
    let book: Book
    let action: () -> Void
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        let state = library.state(for: book)
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                BookCoverView(book: book, title: library.title(of: book), author: library.author(of: book))
                    .frame(width: 78)
                VStack(alignment: .leading, spacing: 6) {
                    Text("CONTINUE READING")
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(Palette.accent)
                    Text(library.title(of: book))
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let a = library.author(of: book) {
                        Text(a).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    HStack(spacing: 8) {
                        BookProgressBar(progress: state.progress)
                        Text(Format.percent(state.progress))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize()
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Palette.hairline))
        }
        .buttonStyle(PressableStyle())
    }
}
