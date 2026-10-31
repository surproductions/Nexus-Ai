import Foundation
import CryptoKit
import UIKit
import ZIPFoundation

/// Background, resumable model downloads with SHA-256 verification.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    enum Kind: String, Sendable { case model, vision }

    enum Status: Equatable, Sendable {
        case downloading, paused, verifying, failed(String), completed
    }

    struct Item: Identifiable, Equatable, Sendable {
        var id: String { "\(entryID)|\(kind.rawValue)" }
        var entryID: String
        var kind: Kind
        var name: String
        var written: Int64 = 0
        var total: Int64
        var status: Status = .downloading
        var bytesPerSecond: Double = 0
        var progress: Double { total > 0 ? Double(written) / Double(total) : 0 }
    }

    static let sessionID = "ai.nexus.model-downloads"
    static var backgroundCompletion: (() -> Void)?

    @Published private(set) var items: [String: Item] = [:]
    var allowCellular = false

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsExpensiveNetworkAccess = true
        config.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var speedSamples: [String: (Date, Int64)] = [:]
    weak var models: ModelManager?

    override init() {
        super.init()
        session.getAllTasks { [weak self] list in
            Task { @MainActor in
                guard let self else { return }
                for case let t as URLSessionDownloadTask in list {
                    guard let key = t.taskDescription, let decoded = self.decode(key) else { continue }
                    let (entry, kind) = decoded
                    self.tasks[key] = t
                    guard let file = kind == .vision ? entry.visionProjector : entry.file else { continue }
                    self.items[key] = Item(entryID: entry.id, kind: kind, name: entry.name, written: t.countOfBytesReceived,
                                           total: file.sizeBytes, status: t.state == .suspended ? .paused : .downloading)
                }
                // Surface paused downloads that have resume data on disk.
                for entry in ModelRegistry.catalog {
                    for kind in [Kind.model, .vision] {
                        let key = "\(entry.id)|\(kind.rawValue)"
                        if self.items[key] == nil, FileManager.default.fileExists(atPath: self.resumeURL(key).path) {
                            let file = kind == .vision ? entry.visionProjector : entry.file
                            self.items[key] = Item(entryID: entry.id, kind: kind, name: entry.name,
                                                   total: file?.sizeBytes ?? 0, status: .paused)
                        }
                    }
                }
            }
        }
    }

    private func decode(_ key: String) -> (ModelEntry, Kind)? {
        let parts = key.split(separator: "|").map(String.init)
        guard parts.count == 2, let entry = ModelRegistry.entry(parts[0]), let kind = Kind(rawValue: parts[1]) else { return nil }
        return (entry, kind)
    }

    private func resumeURL(_ key: String) -> URL {
        Paths.downloads.appendingPathComponent(key.replacingOccurrences(of: "|", with: "__") + ".resume")
    }

    func item(_ entryID: String, _ kind: Kind) -> Item? { items["\(entryID)|\(kind.rawValue)"] }

    var activeCount: Int { items.values.filter { $0.status == .downloading || $0.status == .verifying }.count }

    /// Starts or resumes a download after network-policy and storage checks.
    func start(_ entry: ModelEntry, kind: Kind) throws {
        guard let file = kind == .vision ? entry.visionProjector : entry.file else { return }
        try NetworkGate.shared.authorize(.modelDownload)
        if NetworkGate.shared.isExpensive && !allowCellular {
            throw NexusError.networkBlocked("You're on cellular or a hotspot. Enable “Allow cellular downloads” in Settings or connect to Wi-Fi.")
        }
        HardwareMonitor.shared.refresh()
        let free = HardwareMonitor.shared.freeStorage
        let needed = file.sizeBytes * (entry.modelKind == .imageDiffusion ? 2 : 1) + 512 * 1_048_576  // archives unpack in place
        guard free == 0 || free > needed else { throw NexusError.insufficientStorage(required: needed, available: free) }

        let key = "\(entry.id)|\(kind.rawValue)"
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeURL(key)) {
            task = session.downloadTask(withResumeData: data)
            try? FileManager.default.removeItem(at: resumeURL(key))
        } else {
            var request = URLRequest(url: file.url)
            request.allowsCellularAccess = allowCellular
            request.allowsExpensiveNetworkAccess = allowCellular
            task = session.downloadTask(with: request)
        }
        task.taskDescription = key
        task.countOfBytesClientExpectsToReceive = file.sizeBytes
        tasks[key] = task
        var item = items[key] ?? Item(entryID: entry.id, kind: kind, name: entry.name, total: file.sizeBytes)
        item.status = .downloading
        items[key] = item
        NetworkGate.shared.record(.modelDownload, url: file.url, summary: "\(entry.name) · \(file.filename)", bytesSent: 0)
        task.resume()
    }

    func pause(_ entryID: String, _ kind: Kind) {
        let key = "\(entryID)|\(kind.rawValue)"
        guard let task = tasks[key] else { return }
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if let data { try? data.write(to: self.resumeURL(key)) }
                self.tasks[key] = nil
                self.items[key]?.status = .paused
                self.items[key]?.bytesPerSecond = 0
            }
        })
    }

    func cancel(_ entryID: String, _ kind: Kind) {
        let key = "\(entryID)|\(kind.rawValue)"
        tasks[key]?.cancel()
        tasks[key] = nil
        try? FileManager.default.removeItem(at: resumeURL(key))
        items[key] = nil
    }

    func clearFinished() {
        items = items.filter { if case .completed = $0.value.status { return false }; return true }
    }

    fileprivate func updateProgress(key: String, written: Int64, total: Int64) {
        guard var item = items[key] else { return }
        let now = Date()
        if let sample = speedSamples[key], now.timeIntervalSince(sample.0) > 1 {
            item.bytesPerSecond = Double(written - sample.1) / now.timeIntervalSince(sample.0)
            speedSamples[key] = (now, written)
        } else if speedSamples[key] == nil {
            speedSamples[key] = (now, written)
        }
        item.written = written
        if total > 0 { item.total = total }
        item.status = .downloading
        items[key] = item
    }

    fileprivate func finished(key: String, staged: URL) {
        guard let decoded = decode(key) else { return }
        let (entry, kind) = decoded
        guard let file = kind == .vision ? entry.visionProjector : entry.file else { return }
        items[key]?.status = .verifying
        let destination = kind == .vision ? ModelManager.projectorURL(entry)! : ModelManager.localURL(entry)
        let isArchive = entry.modelKind == .imageDiffusion
        Task.detached(priority: .utility) {
            var result = Self.verify(staged, expectedSize: file.sizeBytes, sha256: file.sha256)
            if case .success = result, isArchive {
                result = Self.unpackDiffusion(zip: staged, to: destination)
            }
            await MainActor.run {
                if isArchive, case .success = result {
                    self.items[key]?.status = .completed
                    self.items[key]?.written = file.sizeBytes
                    self.tasks[key] = nil
                    self.models?.rescan()
                    return
                }
                switch result {
                case .success:
                    try? FileManager.default.removeItem(at: destination)
                    do {
                        try FileManager.default.moveItem(at: staged, to: destination)
                        var values = URLResourceValues()
                        values.isExcludedFromBackup = true
                        var dest = destination
                        try? dest.setResourceValues(values)
                        self.items[key]?.status = .completed
                        self.items[key]?.written = file.sizeBytes
                    } catch {
                        self.items[key]?.status = .failed(error.localizedDescription)
                    }
                    self.models?.rescan()
                case .failure(let error):
                    try? FileManager.default.removeItem(at: staged)
                    self.items[key]?.status = .failed(error.localizedDescription)
                }
                self.tasks[key] = nil
            }
        }
    }

    fileprivate func failed(key: String, error: Error, resumeData: Data?) {
        if let resumeData { try? resumeData.write(to: resumeURL(key)) }
        tasks[key] = nil
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
            if items[key]?.status != .paused, resumeData == nil { items[key] = nil }
            return
        }
        items[key]?.status = resumeData != nil ? .paused : .failed(error.localizedDescription)
    }

    /// Unzips Core ML resources, locates the folder holding the .mlmodelc bundles and installs it at `destination`.
    nonisolated static func unpackDiffusion(zip: URL, to destination: URL) -> Result<Void, Error> {
        let fm = FileManager.default
        let work = zip.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? fm.removeItem(at: work)
            try? fm.removeItem(at: zip)
        }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try fm.unzipItem(at: zip, to: work)
            guard let en = fm.enumerator(at: work, includingPropertiesForKeys: nil) else { throw NexusError.generic("Empty archive") }
            var root: URL?
            for case let url as URL in en where url.lastPathComponent == "TextEncoder.mlmodelc" {
                root = url.deletingLastPathComponent()
                break
            }
            guard let root else { throw NexusError.generic("The archive doesn't contain Core ML Stable Diffusion resources.") }
            try? fm.removeItem(at: destination)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: root, to: destination)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var dest = destination
            try? dest.setResourceValues(values)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func verify(_ url: URL, expectedSize: Int64, sha256: String?) -> Result<Void, Error> {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        guard size == expectedSize else {
            return .failure(NexusError.generic("Downloaded size \(size) does not match expected \(expectedSize) bytes."))
        }
        guard let sha256 else { return .success(()) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .failure(NexusError.generic("Cannot read download")) }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { handle.readData(ofLength: 8 * 1_048_576) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == sha256.lowercased() ? .success(()) : .failure(NexusError.checksumMismatch(url.lastPathComponent))
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        Task { @MainActor in self.updateProgress(key: key, written: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let code = http.statusCode
            Task { @MainActor in self.failed(key: key, error: NexusError.generic("Server returned HTTP \(code)"), resumeData: nil) }
            return
        }
        // The temporary file is deleted when this method returns, so move it synchronously.
        let staged = Paths.downloads.appendingPathComponent(UUID().uuidString + ".staged")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            Task { @MainActor in self.finished(key: key, staged: staged) }
        } catch {
            Task { @MainActor in self.failed(key: key, error: error, resumeData: nil) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let key = task.taskDescription else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in self.failed(key: key, error: error, resumeData: resume) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            DownloadManager.backgroundCompletion?()
            DownloadManager.backgroundCompletion = nil
        }
    }
}
