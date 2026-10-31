import Foundation
import Photos
import UIKit
import AVFoundation

struct MediaItem: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case image, video }
    var id = UUID()
    var kind: Kind
    var name: String
    var folder: String = ""
    /// File name inside MediaFiles.directory.
    var fileName: String
    var created = Date()
    var prompt: String
    var negativePrompt: String = ""
    var modelName: String
    var modelVersion: String = ""
    var provider: String
    var isLocal: Bool
    var operation: String = "generate"   // generate, edit, variation, remix, extend, vertical, background, enhance
    var settings: [String: String] = [:]
    var parentID: UUID?
    var remoteID: String?
    var width: Int = 0
    var height: Int = 0
    var favorite = false

    var url: URL { MediaFiles.directory.appendingPathComponent(fileName) }
}

/// Local library of generated and edited media, with generation metadata. Stored in the encrypted database.
@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    private let db = Database.shared

    init() {
        db.exec("CREATE TABLE IF NOT EXISTS media(id TEXT PRIMARY KEY, created REAL, body BLOB);")
        reload()
    }

    var folders: [String] { Array(Set(items.map(\.folder).filter { !$0.isEmpty })).sorted() }

    func reload() {
        items = db.query("SELECT body FROM media ORDER BY created DESC").compactMap {
            $0.blob("body").flatMap(Vault.open).flatMap { try? JSONDecoder().decode(MediaItem.self, from: $0) }
        }.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    @discardableResult
    func add(_ item: MediaItem) -> MediaItem {
        save(item)
        return item
    }

    func save(_ item: MediaItem) {
        guard let data = try? JSONEncoder().encode(item) else { return }
        db.run("INSERT OR REPLACE INTO media(id, created, body) VALUES(?,?,?)",
               [.text(item.id.uuidString), .real(item.created.timeIntervalSince1970), .blob(Vault.seal(data))])
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.insert(item, at: 0) }
    }

    func rename(_ item: MediaItem, to name: String) { var i = item; i.name = name; save(i) }
    func move(_ item: MediaItem, to folder: String) { var i = item; i.folder = folder; save(i) }
    func toggleFavorite(_ item: MediaItem) { var i = item; i.favorite.toggle(); save(i) }

    func delete(_ item: MediaItem) {
        try? FileManager.default.removeItem(at: item.url)
        db.run("DELETE FROM media WHERE id = ?", [.text(item.id.uuidString)])
        items.removeAll { $0.id == item.id }
    }

    func item(_ id: UUID?) -> MediaItem? { id.flatMap { i in items.first { $0.id == i } } }

    func usage() -> Int64 {
        items.reduce(0) { $0 + Int64((try? $1.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: Export

    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? { "Photos access was not granted. Allow “Add Photos Only” for NEXUS in Settings." }
    }

    func saveToPhotos(_ item: MediaItem) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: item.kind == .video ? .video : .photo, fileURL: item.url, options: nil)
        }
    }

    // MARK: Uploaded media retention

    /// Deletes uploaded attachments older than `days` (0 = keep forever). Generated media in the library is not affected.
    static func purgeUploads(olderThan days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var removed = 0
        for sub in ["images", "videos"] {
            let dir = Paths.attachments.appendingPathComponent(sub)
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { continue }
            for f in files {
                let created = (try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                if created < cutoff, (try? FileManager.default.removeItem(at: f)) != nil { removed += 1 }
            }
        }
        return removed
    }

    static func uploadsUsage() -> Int64 {
        var total: Int64 = 0
        for sub in ["images", "videos", "docs"] {
            let dir = Paths.attachments.appendingPathComponent(sub)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            total += files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return total
    }

    static func clearUploads() {
        for sub in ["images", "videos"] { try? FileManager.default.removeItem(at: Paths.attachments.appendingPathComponent(sub)) }
    }

    nonisolated static func thumbnail(for item: MediaItem, maxSide: CGFloat = 400) -> UIImage? {
        if item.kind == .image { return UIImage(contentsOfFile: item.url.path)?.preparingThumbnail(of: CGSize(width: maxSide, height: maxSide)) }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSide, height: maxSide)
        return (try? gen.copyCGImage(at: .zero, actualTime: nil)).map(UIImage.init(cgImage:))
    }
}
