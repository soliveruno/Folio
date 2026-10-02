import Foundation
import AVFoundation
import MediaPlayer
import UIKit

struct Song: Identifiable, Hashable {
    let url: URL
    var id: String { url.lastPathComponent }
    var fileTitle: String { url.deletingPathExtension().lastPathComponent }
}

struct SongInfo {
    var title: String
    var artist: String?
    var album: String?
    var duration: TimeInterval
    var thumbnail: UIImage?
}

/// Reads ID3 / iTunes tags once per song, off the main thread, and keeps small thumbnails in memory.
final class SongInfoCache {
    static let shared = SongInfoCache()
    private final class Box { let info: SongInfo; init(_ i: SongInfo) { info = i } }
    private let cache = NSCache<NSString, Box>()

    private init() { cache.countLimit = 400 }

    func cached(_ song: Song) -> SongInfo? { cache.object(forKey: song.id as NSString)?.info }

    func info(for song: Song) async -> SongInfo {
        if let c = cached(song) { return c }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: self.load(song))
            }
        }
    }

    /// Synchronous – call off the main thread.
    func load(_ song: Song) -> SongInfo {
        if let c = cached(song) { return c }
        let asset = AVURLAsset(url: song.url)
        let md = asset.commonMetadata
        func string(_ key: AVMetadataKey) -> String? {
            let v = AVMetadataItem.metadataItems(from: md, withKey: key, keySpace: .common)
                .first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty ?? true) ? nil : v
        }
        var thumb: UIImage?
        if let data = artworkData(md) { thumb = ImageDownsampler.image(data: data, maxPixel: 132) }
        let seconds = CMTimeGetSeconds(asset.duration)
        let info = SongInfo(title: string(.commonKeyTitle) ?? song.fileTitle,
                            artist: string(.commonKeyArtist),
                            album: string(.commonKeyAlbumName),
                            duration: seconds.isFinite ? seconds : 0,
                            thumbnail: thumb)
        cache.setObject(Box(info), forKey: song.id as NSString)
        return info
    }

    /// Large artwork for the Now Playing screen / lock screen (not cached).
    func artwork(for song: Song, maxPixel: CGFloat) -> UIImage? {
        let asset = AVURLAsset(url: song.url)
        guard let data = artworkData(asset.commonMetadata) else { return nil }
        return ImageDownsampler.image(data: data, maxPixel: maxPixel)
    }

    private func artworkData(_ md: [AVMetadataItem]) -> Data? {
        AVMetadataItem.metadataItems(from: md, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common)
            .first?.dataValue
    }
}

/// Playback position lives in its own object so the once-per-second updates only redraw
/// the few views that show time, not the whole app.
final class PlaybackClock: ObservableObject {
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    var fraction: Double { duration > 0 ? min(max(currentTime / duration, 0), 1) : 0 }
}

enum RepeatMode: Int {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var symbol: String { self == .one ? "repeat.1" : "repeat" }
}

final class PlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var songs: [Song] = []
    @Published private(set) var current: Song?
    @Published private(set) var info: SongInfo?
    @Published private(set) var artwork: UIImage?
    @Published private(set) var isPlaying = false
    @Published var shuffle = false {
        didSet { UserDefaults.standard.set(shuffle, forKey: "player.shuffle") }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "player.repeat") }
    }

    let clock = PlaybackClock()

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var history: [Song] = []
    private var appActive = true
    private var sessionActive = false

    /// The full-screen player asks for smoother updates while it is visible.
    var wantsFastClock = false {
        didSet { if wantsFastClock != oldValue { updateTimer() } }
    }

    var title: String { info?.title ?? current?.fileTitle ?? "Not Playing" }
    var subtitle: String { info?.artist ?? info?.album ?? "Unknown artist" }

    override init() {
        super.init()
        shuffle = UserDefaults.standard.bool(forKey: "player.shuffle")
        repeatMode = RepeatMode(rawValue: UserDefaults.standard.integer(forKey: "player.repeat")) ?? .off
        // Category only – the session is activated on first play so opening the app to read
        // never interrupts audio from other apps.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        setupRemoteCommands()
        refresh()
    }

    // MARK: Library

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.documents, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let found = files
            .filter { FileKind(url: $0) == .audio }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(Song.init)
        if found != songs { songs = found }
        if let c = current, !found.contains(c) { stop() }
    }

    func delete(_ song: Song) {
        if song == current { stop() }
        try? FileManager.default.removeItem(at: song.url)
        refresh()
    }

    // MARK: Playback

    func play(_ song: Song, recordHistory: Bool = true) {
        do {
            let p = try AVAudioPlayer(contentsOf: song.url)
            p.delegate = self
            p.prepareToPlay()
            activateSession()
            player?.stop()
            player = p
            if recordHistory, let c = current, c != song {
                history.append(c)
                if history.count > 200 { history.removeFirst() }
            }
            let changed = current != song
            current = song
            p.play()
            isPlaying = true
            clock.duration = p.duration
            clock.currentTime = 0
            if changed {
                info = SongInfoCache.shared.cached(song)
                artwork = nil
                loadDetails(for: song)
            }
            updateNowPlaying()
            updateTimer()
        } catch {
            print("Playback failed:", error)
        }
    }

    func playAll(shuffled: Bool) {
        guard !songs.isEmpty else { return }
        shuffle = shuffled
        if let s = shuffled ? songs.randomElement() : songs.first { play(s) }
    }

    func togglePlay() { isPlaying ? pause() : resume() }

    func resume() {
        guard let p = player else {
            if let s = current ?? songs.first { play(s) }
            return
        }
        activateSession()
        p.play()
        isPlaying = true
        syncTime()
        updateNowPlaying()
        updateTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        syncTime()
        updateNowPlaying()
        updateTimer()
    }

    func next(auto: Bool = false) {
        guard !songs.isEmpty else { return }
        if auto, repeatMode == .one, current != nil {
            player?.currentTime = 0
            player?.play()
            isPlaying = true
            syncTime()
            updateNowPlaying()
            return
        }
        if shuffle, songs.count > 1 {
            var pick = songs.randomElement()!
            while pick == current { pick = songs.randomElement()! }
            play(pick)
            return
        }
        let idx = current.flatMap { songs.firstIndex(of: $0) } ?? -1
        if idx + 1 < songs.count {
            play(songs[idx + 1])
        } else if auto && repeatMode == .off {
            // End of the list: stop at the beginning of the last song
            player?.currentTime = 0
            isPlaying = false
            syncTime()
            updateNowPlaying()
            updateTimer()
        } else {
            play(songs[0])
        }
    }

    func previous() {
        guard !songs.isEmpty else { return }
        if (player?.currentTime ?? 0) > 3 { seek(to: 0); return }
        if shuffle, let last = history.popLast(), songs.contains(last) {
            play(last, recordHistory: false)
            return
        }
        let idx = current.flatMap { songs.firstIndex(of: $0) } ?? 0
        play(songs[(idx - 1 + songs.count) % songs.count], recordHistory: false)
    }

    func seek(to time: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = min(max(time, 0), p.duration)
        syncTime()
        updateNowPlaying()
    }

    func stop() {
        player?.stop()
        player = nil
        current = nil
        info = nil
        artwork = nil
        isPlaying = false
        clock.currentTime = 0
        clock.duration = 0
        updateTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }

    func setAppActive(_ active: Bool) {
        appActive = active
        if active { syncTime() }
        updateTimer()
    }

    // MARK: Internals

    private func activateSession() {
        guard !sessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        sessionActive = true
    }

    private func loadDetails(for song: Song) {
        DispatchQueue.global(qos: .userInitiated).async {
            let i = SongInfoCache.shared.load(song)
            let art = SongInfoCache.shared.artwork(for: song, maxPixel: 900)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.current == song else { return }
                self.info = i
                self.artwork = art
                self.updateNowPlaying()
            }
        }
    }

    private func syncTime() {
        let t = player?.currentTime ?? 0
        if abs(clock.currentTime - t) > 0.01 { clock.currentTime = t }
        let d = player?.duration ?? 0
        if clock.duration != d { clock.duration = d }
    }

    /// The UI clock only runs while music plays AND the app is on screen.
    /// In the background nothing ticks – the lock screen extrapolates time on its own.
    private func updateTimer() {
        let needed = isPlaying && appActive
        let interval: TimeInterval = wantsFastClock ? 0.25 : 1.0
        guard needed else {
            timer?.invalidate()
            timer = nil
            return
        }
        if let t = timer, t.isValid, t.timeInterval == interval { return }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, target: self, selector: #selector(tick),
                      userInfo: nil, repeats: true)
        t.tolerance = interval * 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func tick() { syncTime() }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.next(auto: true) }
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
        DispatchQueue.main.async {
            if type == .began {
                self.isPlaying = false
                self.syncTime()
                self.updateNowPlaying()
                self.updateTimer()
            } else if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume),
                      self.player != nil {
                self.resume()
            }
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        // Headphones unplugged → pause, like the system player
        DispatchQueue.main.async { if self.isPlaying { self.pause() } }
    }

    // MARK: Lock screen / Control Center

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlay(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent { self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let song = current, let p = player else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: info?.title ?? song.fileTitle,
            MPMediaItemPropertyPlaybackDuration: p.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: p.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let a = info?.artist { dict[MPMediaItemPropertyArtist] = a }
        if let a = info?.album { dict[MPMediaItemPropertyAlbumTitle] = a }
        if let art = artwork {
            dict[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = dict
    }
}
