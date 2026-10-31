// Minimal stand-ins for app types so pure-logic sources compile as a macOS command-line test binary.
import Foundation

enum ChatRole: String, Codable, Sendable { case system, user, assistant, tool }

enum NexusError: Error { case cancelled }

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension String {
    func truncated(to max: Int) -> String { count <= max ? self : String(prefix(max)) + "…" }
    var approxTokens: Int { max(1, Int(Double(utf8.count) / 3.6)) }
}

enum IntelligenceMode: String, Codable, CaseIterable, Sendable { case instant, thinking, max }

enum AppleFoundationBackend { static let modelID = "apple.foundation" }
