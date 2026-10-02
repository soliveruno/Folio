import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design tokens

enum Palette {
    static let accent = Color(hex: "#FF9F43")
    static let accentUI = UIColor(hex: "#FF9F43")
    static let background = Color(hex: "#0E0E11")
    static let surface = Color(hex: "#1A1A1F")
    static let surfaceHigh = Color(hex: "#26262D")
    static let hairline = Color.white.opacity(0.08)
}

extension UIColor {
    convenience init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Color {
    init(hex: String) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

// MARK: - Files

enum AppPaths {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Folio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

enum FileKind: Equatable {
    case pdf, epub, audio, other

    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "m4b"]

    init(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { self = .pdf }
        else if ext == "epub" { self = .epub }
        else if FileKind.audioExtensions.contains(ext) { self = .audio }
        else { self = .other }
    }

    var isBook: Bool { self == .pdf || self == .epub }
}

extension UTType {
    static let epubBook = UTType(filenameExtension: "epub") ?? UTType(importedAs: "org.idpf.epub-container")
}

/// Copies files picked in Files / shared from other apps into the app's Documents folder.
enum Importer {
    static func importFiles(_ urls: [URL], completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            for url in urls {
                guard FileKind(url: url) != .other else { continue }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let dest = AppPaths.documents.appendingPathComponent(url.lastPathComponent)
                if dest.standardizedFileURL == url.standardizedFileURL { continue }
                if fm.fileExists(atPath: dest.path) {
                    try? fm.removeItem(at: dest)
                    EPUBBook.clearCache(for: dest)
                    CoverCache.shared.remove(id: dest.lastPathComponent)
                }
                try? fm.copyItem(at: url, to: dest)
                // Files handed over via "Open in…" land in Documents/Inbox – tidy them up
                if url.path.contains("/Documents/Inbox/") { try? fm.removeItem(at: url) }
            }
            DispatchQueue.main.async(execute: completion)
        }
    }
}

/// Small JSON file store with debounced, off-main-thread writes (cheap on battery).
final class DiskBox<T: Codable> {
    let url: URL
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "folio.disk", qos: .utility)

    init(_ name: String) { url = AppPaths.support.appendingPathComponent(name) }

    func load() -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save(_ value: T, delay: TimeInterval = 0.8) {
        pending?.cancel()
        let url = self.url
        let item = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
        }
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func flush(_ value: T) {
        pending?.cancel()
        pending = nil
        let url = self.url
        queue.async {
            if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
        }
    }
}

// MARK: - Images

enum ImageDownsampler {
    static func image(url: URL, maxPixel: CGFloat) -> UIImage? {
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else { return nil }
        return thumbnail(src, maxPixel)
    }

    static func image(data: Data, maxPixel: CGFloat) -> UIImage? {
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary) else { return nil }
        return thumbnail(src, maxPixel)
    }

    private static func thumbnail(_ src: CGImageSource, _ maxPixel: CGFloat) -> UIImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Formatting helpers

enum Format {
    static func time(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func percent(_ p: Double) -> String {
        let v = min(max(p, 0), 1)
        return "\(Int((v * 100).rounded(.down)))%"
    }

    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

extension String {
    var collapsedWhitespace: String {
        components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Lightweight haptics, created lazily.
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
