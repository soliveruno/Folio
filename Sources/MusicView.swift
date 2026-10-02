import SwiftUI
import MediaPlayer

struct MusicView: View {
    var body: some View {
        NavigationView {
            SongListView(showsNowPlayingRow: false)
                .navigationTitle("Music")
                .withMiniPlayer()
        }
        .navigationViewStyle(.stack)
    }
}

/// Song list used by the Music tab and by the music sheet inside the reader.
struct SongListView: View {
    @EnvironmentObject private var player: PlayerModel
    var showsNowPlayingRow: Bool
    @State private var search = ""
    @State private var showImporter = false
    @State private var showNowPlaying = false
    @State private var showDownloads = false
    @EnvironmentObject private var downloads: DownloadManager

    private var filtered: [Song] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return player.songs }
        return player.songs.filter { song in
            let info = SongInfoCache.shared.cached(song)
            return song.fileTitle.localizedCaseInsensitiveContains(q)
                || (info?.title.localizedCaseInsensitiveContains(q) ?? false)
                || (info?.artist?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        Group {
            if player.songs.isEmpty {
                emptyState
            } else {
                List {
                    if showsNowPlayingRow, player.current != nil {
                        Section {
                            Button { showNowPlaying = true } label: { NowPlayingRow() }
                                .listRowBackground(Palette.surfaceHigh)
                        }
                    }
                    if search.isEmpty {
                        Section {
                            HStack(spacing: 12) {
                                PillButton(title: "Play", symbol: "play.fill") { player.playAll(shuffled: false) }
                                PillButton(title: "Shuffle", symbol: "shuffle") { player.playAll(shuffled: true) }
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                        }
                    }
                    Section(header: Text("\(player.songs.count) songs")) {
                        ForEach(filtered) { song in
                            Button { player.play(song) } label: {
                                SongRow(song: song, isCurrent: player.current == song, isPlaying: player.isPlaying)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { player.delete(song) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .searchable(text: $search, prompt: "Songs, artists")
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { showDownloads = true } label: {
                    Image(systemName: downloads.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
                .accessibilityLabel("Download from a link")
                Button { showImporter = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showDownloads) { DownloadView().environmentObject(downloads) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Importer.importFiles(urls) { player.refresh() }
            }
        }
        .sheet(isPresented: $showNowPlaying) { NowPlayingView().environmentObject(player) }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Palette.accent)
            Text("No music yet").font(.title3.weight(.semibold))
            Text("Import MP3, M4A, FLAC or WAV files,\nor download songs from a link with yt-dlp.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button { showImporter = true } label: {
                Label("Import Music", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Palette.accent, in: Capsule())
                    .foregroundColor(.black)
            }
            .padding(.top, 6)
            Button { showDownloads = true } label: {
                Label("Download from a link", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accent)
            }
            .padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct PillButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Palette.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(Palette.accent)
        }
        .buttonStyle(.plain)
    }
}

struct SongRow: View {
    let song: Song
    let isCurrent: Bool
    let isPlaying: Bool
    @State private var info: SongInfo?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                ArtworkView(image: info?.thumbnail, size: 44, corner: 7)
                if isCurrent {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.45))
                        .frame(width: 44, height: 44)
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Palette.accent)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(info?.title ?? song.fileTitle)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Palette.accent : Color.primary)
                    .lineLimit(1)
                Text(info?.artist ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let d = info?.duration, d > 0 {
                Text(Format.time(d))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .task(id: song.id) {
            if info == nil { info = SongInfoCache.shared.cached(song) }
            if info == nil { info = await SongInfoCache.shared.info(for: song) }
        }
    }
}

struct NowPlayingRow: View {
    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(image: player.artwork ?? player.info?.thumbnail, size: 52, corner: 9)
            VStack(alignment: .leading, spacing: 4) {
                Text("NOW PLAYING").font(.caption2.weight(.bold)).foregroundStyle(Palette.accent)
                Text(player.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                ClockProgressLine(clock: player.clock)
            }
            Button(action: player.togglePlay) {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Full screen player

struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 64, geo.size.height * 0.42)
            ZStack {
                background
                VStack(spacing: 0) {
                    Capsule().fill(Color.white.opacity(0.3)).frame(width: 38, height: 5).padding(.top, 10)
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down").font(.headline).frame(width: 44, height: 44)
                        }
                        Spacer()
                        Text("Now Playing").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Color.clear.frame(width: 44, height: 44)
                    }
                    .padding(.horizontal, 12)

                    Spacer(minLength: 12)
                    ArtworkView(image: player.artwork ?? player.info?.thumbnail, size: side, corner: 18)
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                        .scaleEffect(player.isPlaying ? 1 : 0.88)
                        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: player.isPlaying)
                    Spacer(minLength: 20)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.title)
                            .font(.title2.weight(.bold))
                            .lineLimit(1)
                        Text(player.subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)

                    PlayerScrubber(clock: player.clock)
                        .padding(.horizontal, 32)
                        .padding(.top, 18)

                    PlayerControls()
                        .padding(.horizontal, 28)
                        .padding(.top, 14)

                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                        SystemVolumeSlider().frame(height: 34)
                        Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
            }
        }
        .onAppear { player.wantsFastClock = true }
        .onDisappear { player.wantsFastClock = false }
    }

    private var background: some View {
        ZStack {
            Palette.background
            if let art = player.artwork ?? player.info?.thumbnail {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 70)
                    .opacity(0.55)
                    .clipped()
            }
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

struct PlayerScrubber: View {
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject var clock: PlaybackClock
    @State private var scrub: Double?

    var body: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { scrub ?? clock.currentTime }, set: { scrub = $0 }),
                   in: 0...max(clock.duration, 1)) { editing in
                if !editing, let s = scrub { player.seek(to: s); scrub = nil }
            }
            .disabled(player.current == nil)
            HStack {
                Text(Format.time(scrub ?? clock.currentTime))
                Spacer()
                Text("-" + Format.time(max(clock.duration - (scrub ?? clock.currentTime), 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

struct PlayerControls: View {
    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        HStack {
            Button { player.shuffle.toggle() } label: {
                Image(systemName: "shuffle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(player.shuffle ? Palette.accent : Color.secondary)
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Button(action: player.previous) {
                Image(systemName: "backward.fill").font(.title).frame(width: 56, height: 56)
            }
            Spacer()
            Button(action: player.togglePlay) {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(Palette.accent)
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title).frame(width: 56, height: 56)
            }
            Spacer()
            Button { player.repeatMode = player.repeatMode.next } label: {
                Image(systemName: player.repeatMode.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(player.repeatMode == .off ? Color.secondary : Palette.accent)
                    .frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
    }
}

/// The system volume slider (also controls AirPlay / Bluetooth volume).
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: .zero)
        v.tintColor = Palette.accentUI
        return v
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// Music browser presented from inside the reader.
struct MusicSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            SongListView(showsNowPlayingRow: true)
                .navigationTitle("Music")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}
