import Foundation
import Network

/// Every outbound request in the app goes through this gate. It enforces Offline-Only mode and per-feature
/// consent, and records a local, user-visible log of what left the device. Nothing is sent anywhere else.
final class NetworkGate: @unchecked Sendable {
    static let shared = NetworkGate()

    enum Feature: String, Codable, CaseIterable, Sendable {
        case modelDownload = "Model download"
        case webResearch = "Web research"
        case cloudInference = "Cloud inference"

        var explanation: String {
            switch self {
            case .modelDownload: return "Downloads model weights from Hugging Face. Only the file request is sent; no personal data."
            case .webResearch: return "Sends your search query to the search provider and fetches the resulting pages."
            case .cloudInference: return "Sends the prompt, relevant context and attachments for that request to your configured provider."
            }
        }
    }

    struct LogEntry: Codable, Identifiable, Hashable, Sendable {
        var id = UUID()
        var date = Date()
        var feature: Feature
        var host: String
        var summary: String
        var bytesSent: Int
    }

    struct Policy: Sendable {
        var offlineOnly = false
        var allowWebResearch = false
        var allowCloud = false
    }

    private let lock = NSLock()
    private var _policy = Policy()
    private var _log: [LogEntry] = []
    private let monitor = NWPathMonitor()
    private var _online = true
    private var _expensive = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self._online = path.status == .satisfied
            self._expensive = path.isExpensive
            self.lock.unlock()
            NotificationCenter.default.post(name: .nexusNetworkChanged, object: nil)
        }
        monitor.start(queue: DispatchQueue(label: "ai.nexus.netmonitor"))
        if let data = UserDefaults.standard.data(forKey: "network.log"),
           let entries = try? JSONDecoder().decode([LogEntry].self, from: data) {
            _log = entries
        }
    }

    var policy: Policy {
        get { lock.lock(); defer { lock.unlock() }; return _policy }
        set { lock.lock(); _policy = newValue; lock.unlock() }
    }

    var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return _online }
    var isExpensive: Bool { lock.lock(); defer { lock.unlock() }; return _expensive }
    var log: [LogEntry] { lock.lock(); defer { lock.unlock() }; return _log }

    func isAllowed(_ feature: Feature) -> Bool {
        let p = policy
        if p.offlineOnly { return false }
        switch feature {
        case .modelDownload: return true
        case .webResearch: return p.allowWebResearch
        case .cloudInference: return p.allowCloud
        }
    }

    /// Throws unless the feature is permitted and the device is online.
    func authorize(_ feature: Feature) throws {
        let p = policy
        if p.offlineOnly {
            throw NexusError.networkBlocked("Offline-Only mode is on. \(feature.rawValue) is disabled.")
        }
        guard isAllowed(feature) else {
            throw NexusError.networkBlocked("\(feature.rawValue) is turned off. Enable it in Settings → Privacy & Network.")
        }
        guard isOnline else { throw NexusError.networkBlocked("No internet connection.") }
    }

    func record(_ feature: Feature, url: URL?, summary: String, bytesSent: Int) {
        let entry = LogEntry(feature: feature, host: url?.host ?? "unknown", summary: summary.truncated(to: 140), bytesSent: bytesSent)
        lock.lock()
        _log.insert(entry, at: 0)
        if _log.count > 300 { _log.removeLast(_log.count - 300) }
        let snapshot = _log
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: "network.log")
        }
        NotificationCenter.default.post(name: .nexusNetworkLogChanged, object: nil)
    }

    func clearLog() {
        lock.lock(); _log.removeAll(); lock.unlock()
        UserDefaults.standard.removeObject(forKey: "network.log")
        NotificationCenter.default.post(name: .nexusNetworkLogChanged, object: nil)
    }

    /// Authorized data request with logging.
    func data(for request: URLRequest, feature: Feature, summary: String) async throws -> (Data, HTTPURLResponse) {
        try authorize(feature)
        record(feature, url: request.url, summary: summary, bytesSent: request.httpBody?.count ?? 0)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NexusError.provider("Invalid response") }
        return (data, http)
    }

    /// Authorized streaming request with logging.
    func bytes(for request: URLRequest, feature: Feature, summary: String) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        try authorize(feature)
        record(feature, url: request.url, summary: summary, bytesSent: request.httpBody?.count ?? 0)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw NexusError.provider("Invalid response") }
        return (bytes, http)
    }
}

extension Notification.Name {
    static let nexusNetworkChanged = Notification.Name("nexus.network.changed")
    static let nexusNetworkLogChanged = Notification.Name("nexus.network.log.changed")
}
