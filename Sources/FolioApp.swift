import SwiftUI

@main
struct FolioApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PlayerModel()
    @StateObject private var annotations = AnnotationStore()
    @StateObject private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

    init() { FolioApp.configureAppearance() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(annotations)
                .environmentObject(router)
                .preferredColorScheme(.dark)
                // Books and songs shared from other apps ("Open in Folio")
                .onOpenURL { url in
                    Importer.importFiles([url]) {
                        library.refresh()
                        player.refresh()
                        if FileKind(url: url).isBook,
                           let book = library.books.first(where: { $0.id == url.lastPathComponent }) {
                            router.open(book)
                        }
                    }
                }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                // Pick up files copied in through Finder / the Files app
                library.refresh()
                player.refresh()
                player.setAppActive(true)
            case .background:
                library.flush()
                annotations.flush()
                player.setAppActive(false)
            default:
                break
            }
        }
    }

    private static func configureAppearance() {
        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.backgroundEffect = UIBlurEffect(style: .systemChromeMaterialDark)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        nav.backgroundEffect = UIBlurEffect(style: .systemChromeMaterialDark)
        if let serif = UIFont.systemFont(ofSize: 34, weight: .bold).fontDescriptor.withDesign(.serif) {
            nav.largeTitleTextAttributes = [.font: UIFont(descriptor: serif, size: 34)]
        }
        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        edge.largeTitleTextAttributes = nav.largeTitleTextAttributes
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = edge
        UINavigationBar.appearance().compactAppearance = nav

        // Lets SwiftUI's TextEditor sit on our own card background (iOS 15)
        UITextView.appearance().backgroundColor = .clear
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var annotations: AnnotationStore
    @EnvironmentObject private var router: AppRouter
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                .tag(0)
            MusicView()
                .tabItem { Label("Music", systemImage: "music.note") }
                .tag(1)
            MarksView()
                .tabItem { Label("Highlights", systemImage: "highlighter") }
                .tag(2)
        }
        .tint(Palette.accent)
        .fullScreenCover(item: $router.reader) { request in
            ReaderScreen(request: request, library: library, annotations: annotations)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(annotations)
                .environmentObject(router)
        }
    }
}

// MARK: - Mini player (shown above the tab bar on every tab)

struct MiniPlayerBar: View {
    @EnvironmentObject private var player: PlayerModel
    @State private var showFull = false

    var body: some View {
        if player.current != nil {
            HStack(spacing: 12) {
                ArtworkView(image: player.info?.thumbnail ?? player.artwork, size: 42, corner: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(player.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: player.togglePlay) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .frame(width: 36, height: 40)
                }
            }
            .foregroundStyle(.primary)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottom) {
                ClockProgressLine(clock: player.clock)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 1)
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.hairline))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .contentShape(Rectangle())
            .onTapGesture { showFull = true }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .sheet(isPresented: $showFull) {
                NowPlayingView().environmentObject(player)
            }
        }
    }
}

extension View {
    func withMiniPlayer() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
    }
}

/// Thin progress line that redraws once per second (and only while music plays).
struct ClockProgressLine: View {
    @ObservedObject var clock: PlaybackClock
    var height: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(Palette.accent)
                    .frame(width: geo.size.width * clock.fraction)
                    .animation(.linear(duration: 1), value: clock.currentTime)
            }
        }
        .frame(height: height)
    }
}

struct ArtworkView: View {
    let image: UIImage?
    var size: CGFloat
    var corner: CGFloat = 8

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Palette.surfaceHigh, Palette.surface],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(Palette.accent.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}
