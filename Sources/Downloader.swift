import SwiftUI
import AVFoundation
import UIKit

/// Queue of yt-dlp downloads. Runs one at a time on the embedded Python thread,
/// then tags the audio (title, artist, artwork) and drops it into the music library.
final class DownloadManager: ObservableObject {
    enum Status: Equatable {
        case queued, running, processing, done, failed(String), cancelled

        var isActive: Bool { self == .queued || self == .running || self == .processing }
    }

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let url: String
        var title: String
        var status: Status = .queued
        /// 0…1, or negative when the size isn't known yet
        var progress: Double = -1
        var message = "Waiting…"
        var savedFiles: [String] = []
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var engineVersion: String?
    @Published private(set) var engineError: String?
    @Published private(set) var isUpdating = false
    @Published var updateMessage: String?

    /// Called after new songs land in Documents so the player picks them up.
    var onNewSongs: (() -> Void)?

    private var runningID: UUID?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let python = FolioPython.shared

    var activeCount: Int { jobs.filter { $0.status.isActive }.count }

    private var stagingDir: URL {
        let url = AppPaths.caches.appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Engine

    func prepareEngine() {
        guard engineVersion == nil else { return }
        python.prepare { [weak self] json in
            let r = Self.parse(json)
            if r["ok"] as? Bool == true {
                self?.engineVersion = r["version"] as? String
                self?.engineError = nil
            } else {
                self?.engineError = r["error"] as? String ?? "yt-dlp couldn't start."
            }
        }
    }

    func updateEngine() {
        guard !isUpdating else { return }
        isUpdating = true
        updateMessage = "Checking for updates…"
        python.update(progress: { [weak self] _, message in
            if !message.isEmpty { self?.updateMessage = message }
        }, completion: { [weak self] json in
            guard let self = self else { return }
            self.isUpdating = false
            let r = Self.parse(json)
            if r["ok"] as? Bool == true {
                let v = r["version"] as? String ?? ""
                if r["updated"] as? Bool == true {
                    self.updateMessage = "yt-dlp \(v) downloaded. Close and reopen Folio to use it."
                } else {
                    self.updateMessage = "You already have the latest yt-dlp (\(v))."
                }
            } else {
                self.updateMessage = "Update failed: \(r["error"] as? String ?? "unknown error")"
            }
        })
    }

    func resetEngine() {
        python.resetUpdates { [weak self] _ in
            self?.updateMessage = "Reset. Folio will use its built-in yt-dlp after a restart."
        }
    }

    // MARK: Queue

    func enqueue(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let url = text.contains("://") ? text : "https://" + text
        let host = URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
        jobs.insert(Job(url: url, title: host), at: 0)
        Haptics.tap()
        runNext()
    }

    func cancel(_ job: Job) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        if job.id == runningID {
            jobs[i].message = "Cancelling…"
            python.cancel()
        } else if jobs[i].status == .queued {
            jobs[i].status = .cancelled
            jobs[i].message = "Cancelled"
        }
    }

    func retry(_ job: Job) {
        remove(job)
        enqueue(job.url)
    }

    func remove(_ job: Job) {
        guard job.id != runningID else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { !$0.status.isActive }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    private func runNext() {
        guard runningID == nil,
              let job = jobs.last(where: { $0.status == .queued }) else {
            endBackgroundTask()
            return
        }
        runningID = job.id
        beginBackgroundTask()
        update(job.id) {
            $0.status = .running
            $0.message = "Starting yt-dlp…"
            $0.progress = -1
        }
        let id = job.id
        let staging = stagingDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        python.download(url: job.url, to: staging.path, progress: { [weak self] fraction, message in
            self?.update(id) { j in
                if fraction >= 0 { j.progress = fraction }
                if !message.isEmpty { j.message = message }
                if fraction == -2, message.hasPrefix("Solving") { j.progress = -1 }
            }
        }, completion: { [weak self] json in
            self?.finish(id: id, json: json, staging: staging)
        })
    }

    private func finish(id: UUID, json: String, staging: URL) {
        let r = Self.parse(json)
        let items = (r["items"] as? [[String: Any]]) ?? []
        if engineVersion == nil { prepareEngine() }

        if items.isEmpty {
            let cancelled = r["cancelled"] as? Bool == true
            update(id) {
                $0.status = cancelled ? .cancelled : .failed(Self.friendly(r["error"] as? String))
                $0.message = cancelled ? "Cancelled" : Self.friendly(r["error"] as? String)
            }
            try? FileManager.default.removeItem(at: staging)
            runningID = nil
            runNext()
            return
        }

        update(id) {
            $0.status = .processing
            $0.progress = -1
            $0.message = "Adding to your library…"
            if items.count == 1, let t = items[0]["title"] as? String { $0.title = t }
        }

        Task {
            var saved: [String] = []
            var unsupported = 0
            for item in items {
                if let name = await AudioFinisher.finish(item) { saved.append(name) } else { unsupported += 1 }
            }
            await MainActor.run {
                try? FileManager.default.removeItem(at: staging)
                self.update(id) { j in
                    j.savedFiles = saved
                    if saved.isEmpty {
                        j.status = .failed("Only formats iOS can't play were available (WebM/Opus).")
                        j.message = "Only formats iOS can't play were available (WebM/Opus)."
                    } else {
                        j.status = .done
                        j.progress = 1
                        if items.count > 1 { j.title = "\(saved.count) songs" }
                        var msg = saved.count == 1 ? "Added to Music" : "\(saved.count) songs added to Music"
                        if unsupported > 0 { msg += " · \(unsupported) skipped (unsupported format)" }
                        if r["cancelled"] as? Bool == true { msg += " · stopped early" }
                        j.message = msg
                    }
                }
                if !saved.isEmpty { Haptics.success() }
                self.onNewSongs?()
                self.runningID = nil
                self.runNext()
            }
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Folio download") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    static func parse(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["ok": false, "error": json]
        }
        return obj
    }

    static func friendly(_ error: String?) -> String {
        guard var e = error, !e.isEmpty else { return "Download failed." }
        if e.contains("Unsupported URL") { return "This link isn't supported by yt-dlp." }
        if e.contains("Sign in to confirm") { return "YouTube asked to sign in (bot check). Try again later or update yt-dlp." }
        if e.contains("Private video") { return "This video is private." }
        if e.contains("timed out") || e.contains("Network is unreachable") { return "Network problem. Check your connection." }
        if e.count > 220 { e = String(e.prefix(220)) + "…" }
        return e
    }
}

// MARK: - Tagging and moving into the library

enum AudioFinisher {
    private static let directlyPlayable: Set<String> = ["mp3", "flac", "wav", "aiff", "aif", "caf"]
    private static let convertible: Set<String> = ["m4a", "mp4", "m4v", "mov", "aac", "3gp"]

    /// Returns the saved file name, or nil if the format can't be played on iOS.
    static func finish(_ item: [String: Any]) async -> String? {
        guard let path = item["path"] as? String else { return nil }
        let src = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let ext = src.pathExtension.lowercased()
        let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (item["artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = item["album"] as? String
        let baseName = sanitize(title?.isEmpty == false ? title! : src.deletingPathExtension().lastPathComponent)

        if convertible.contains(ext) {
            let artwork = await fetchArtwork(item["thumbnail"] as? String)
            let dest = uniqueDestination(baseName, ext: "m4a")
            if await export(src, to: dest, title: title, artist: artist, album: album, artwork: artwork) {
                return dest.lastPathComponent
            }
            // Couldn't re-wrap it; keep the original if iOS can play it as is
            if ext == "m4a" || ext == "aac" {
                let fallback = uniqueDestination(baseName, ext: ext)
                if (try? FileManager.default.moveItem(at: src, to: fallback)) != nil { return fallback.lastPathComponent }
            }
            return nil
        }

        if directlyPlayable.contains(ext) {
            let dest = uniqueDestination(baseName, ext: ext)
            if (try? FileManager.default.moveItem(at: src, to: dest)) != nil { return dest.lastPathComponent }
        }
        return nil
    }

    private static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: bad).joined(separator: " ")
            .collapsedWhitespace
        let short = cleaned.count > 120 ? String(cleaned.prefix(120)) : cleaned
        return short.isEmpty ? "Download" : short
    }

    private static func uniqueDestination(_ base: String, ext: String) -> URL {
        let fm = FileManager.default
        var url = AppPaths.documents.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = AppPaths.documents.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    private static func fetchArtwork(_ urlString: String?) async -> Data? {
        guard let s = urlString, let url = URL(string: s) else { return nil }
        guard let response = try? await URLSession.shared.data(from: url),
              let image = ImageDownsampler.image(data: response.0, maxPixel: 800) else { return nil }
        return squareCrop(image).jpegData(compressionQuality: 0.85)
    }

    /// Video thumbnails are 16:9 – crop the centre square so it looks like album art.
    private static func squareCrop(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let side = min(cg.width, cg.height)
        let rect = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
        guard let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped)
    }

    private static func metadataItem(_ key: AVMetadataKey, _ value: NSCopying & NSObjectProtocol,
                                     dataType: String? = nil) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .common
        item.key = key.rawValue as NSString
        item.value = value
        if let t = dataType { item.dataType = t }
        return item
    }

    /// Re-wraps the audio as .m4a (no re-encoding for audio-only files) with tags + artwork.
    private static func export(_ src: URL, to dest: URL, title: String?, artist: String?,
                               album: String?, artwork: Data?) async -> Bool {
        let asset = AVURLAsset(url: src)
        let hasVideo = !asset.tracks(withMediaType: .video).isEmpty
        let preset = hasVideo ? AVAssetExportPresetAppleM4A : AVAssetExportPresetPassthrough
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return false }
        session.outputURL = dest
        session.outputFileType = .m4a
        var items: [AVMetadataItem] = []
        if let t = title, !t.isEmpty { items.append(metadataItem(.commonKeyTitle, t as NSString)) }
        if let a = artist, !a.isEmpty { items.append(metadataItem(.commonKeyArtist, a as NSString)) }
        if let a = album, !a.isEmpty { items.append(metadataItem(.commonKeyAlbumName, a as NSString)) }
        if let art = artwork {
            items.append(metadataItem(.commonKeyArtwork, art as NSData,
                                      dataType: kCMMetadataBaseDataType_JPEG as String))
        }
        session.metadata = items

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        if session.status == .completed {
            try? FileManager.default.removeItem(at: src)
            return true
        }
        try? FileManager.default.removeItem(at: dest)
        print("Export failed:", session.error?.localizedDescription ?? "unknown")
        return false
    }
}
