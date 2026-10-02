import SwiftUI

/// "Highlights" tab: every marked passage and every note, grouped by book.
struct MarksView: View {
    @EnvironmentObject private var annotations: AnnotationStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var router: AppRouter
    @State private var segment = 0
    @State private var search = ""
    @State private var editing: Note?

    private struct BookGroup<T>: Identifiable {
        let id: String
        let title: String
        let items: [T]
    }

    private var highlightGroups: [BookGroup<Highlight>] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let items = annotations.highlights.filter {
            q.isEmpty || $0.text.localizedCaseInsensitiveContains(q) || $0.bookTitle.localizedCaseInsensitiveContains(q)
        }
        let grouped = Dictionary(grouping: items, by: { $0.bookID })
        return grouped.map { key, value in
            BookGroup(id: key, title: value.first?.bookTitle ?? key, items: value.sorted { $0.progress < $1.progress })
        }
        .sorted { ($0.items.map(\.created).max() ?? .distantPast) > ($1.items.map(\.created).max() ?? .distantPast) }
    }

    private var noteGroups: [BookGroup<Note>] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let items = annotations.notes.filter {
            q.isEmpty || $0.text.localizedCaseInsensitiveContains(q) || ($0.quote?.localizedCaseInsensitiveContains(q) ?? false)
        }
        let grouped = Dictionary(grouping: items, by: { $0.bookID ?? "" })
        return grouped.map { key, value in
            BookGroup(id: key, title: key.isEmpty ? "General" : (value.first?.bookTitle ?? key),
                  items: value.sorted { $0.updated > $1.updated })
        }
        .sorted { ($0.items.map(\.updated).max() ?? .distantPast) > ($1.items.map(\.updated).max() ?? .distantPast) }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("Show", selection: $segment) {
                        Text("Highlights (\(annotations.highlights.count))").tag(0)
                        Text("Notes (\(annotations.notes.count))").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if segment == 0 {
                    if highlightGroups.isEmpty {
                        placeholder(symbol: "highlighter",
                                    title: search.isEmpty ? "No highlights yet" : "No matches",
                                    text: "While reading, select text and tap a color to mark it. Everything you mark shows up here.")
                    }
                    ForEach(highlightGroups) { group in
                        Section(header: Text(group.title)) {
                            ForEach(group.items) { h in
                                Button { open(h) } label: { HighlightRow(highlight: h) }
                                    .contextMenu {
                                        Button { UIPasteboard.general.string = h.text } label: {
                                            Label("Copy", systemImage: "doc.on.doc")
                                        }
                                        Button(role: .destructive) { annotations.remove(h) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                    .swipeActions {
                                        Button(role: .destructive) { annotations.remove(h) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                } else {
                    if noteGroups.isEmpty {
                        placeholder(symbol: "square.and.pencil",
                                    title: search.isEmpty ? "No notes yet" : "No matches",
                                    text: "Tap the pencil button in the corner while reading, or the button above, to write a note.")
                    }
                    ForEach(noteGroups) { group in
                        Section(header: Text(group.title)) {
                            ForEach(group.items) { n in
                                Button { editing = n } label: { NoteRow(note: n) }
                                    .swipeActions {
                                        Button(role: .destructive) { annotations.remove(n) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: segment == 0 ? "Search highlights" : "Search notes")
            .navigationTitle(segment == 0 ? "Highlights" : "Notes")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { editing = Note(text: "") } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .sheet(item: $editing) { note in
                NoteEditorView(note: note,
                               onSave: { annotations.upsert($0) },
                               onDelete: deleteAction(for: note),
                               onOpen: openAction(for: note))
            }
            .withMiniPlayer()
        }
        .navigationViewStyle(.stack)
    }

    private func placeholder(symbol: String, title: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.accent)
            Text(title).font(.headline)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }

    private func open(_ h: Highlight) {
        guard let book = library.books.first(where: { $0.id == h.bookID }) else { return }
        router.open(book, at: .highlight(h))
    }

    private func deleteAction(for note: Note) -> (() -> Void)? {
        guard annotations.contains(note: note) else { return nil }
        let store = annotations
        return { store.remove(note) }
    }

    private func openAction(for note: Note) -> (() -> Void)? {
        guard let id = note.bookID, let chapter = note.chapter,
              let book = library.books.first(where: { $0.id == id }) else { return nil }
        let r = router
        let fraction = note.fraction ?? 0
        return { r.open(book, at: .location(chapter: chapter, fraction: fraction)) }
    }
}

struct HighlightRow: View {
    let highlight: Highlight

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(highlight.color.color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(highlight.text)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(.primary)
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
                Text("\(highlight.locationLabel) · \(Format.shortDate.string(from: highlight.created))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let q = note.quote {
                Text("“\(q)”")
                    .font(.system(.footnote, design: .serif))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !note.body.isEmpty {
                Text(note.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text([note.locationLabel, Format.shortDate.string(from: note.updated)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Note editor

struct NoteEditorView: View {
    let note: Note
    var onSave: (Note) -> Void
    var onDelete: (() -> Void)?
    var onOpen: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(note: Note, onSave: @escaping (Note) -> Void, onDelete: (() -> Void)? = nil, onOpen: (() -> Void)? = nil) {
        self.note = note
        self.onSave = onSave
        self.onDelete = onDelete
        self.onOpen = onOpen
        _text = State(initialValue: note.text)
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 14) {
                if note.bookTitle != nil || note.locationLabel != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "book.closed.fill").foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            if let t = note.bookTitle { Text(t).font(.subheadline.weight(.semibold)).lineLimit(1) }
                            if let l = note.locationLabel { Text(l).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                        if let open = onOpen {
                            Button {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { open() }
                            } label: {
                                Text("Go to page").font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
                if let q = note.quote {
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle().fill(Palette.accent).frame(width: 3)
                        Text(q)
                            .font(.system(.callout, design: .serif))
                            .italic()
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Write your note…")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                    }
                    TextEditor(text: $text)
                        .focused($focused)
                        .font(.body)
                }
                .padding(10)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(16)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle(onDelete == nil ? "New Note" : "Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if let del = onDelete {
                        Button(role: .destructive) {
                            del()
                            dismiss()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .foregroundColor(.red)
                    }
                    Button("Save") { save() }
                        .font(.body.weight(.semibold))
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && note.quote == nil)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { focused = true }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .tint(Palette.accent)
    }

    private func save() {
        var n = note
        n.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.text.isEmpty, let q = n.quote { n.text = q }
        onSave(n)
        Haptics.success()
        dismiss()
    }
}
