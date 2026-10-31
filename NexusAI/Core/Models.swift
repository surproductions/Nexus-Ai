import Foundation
import SwiftUI

// MARK: - Intelligence modes

enum IntelligenceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case instant, thinking, max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instant: return "Instant"
        case .thinking: return "Thinking"
        case .max: return "Max Intelligence"
        }
    }

    var shortTitle: String {
        switch self {
        case .instant: return "Instant"
        case .thinking: return "Thinking"
        case .max: return "Max"
        }
    }

    var subtitle: String {
        switch self {
        case .instant: return "Fastest response"
        case .thinking: return "Balanced reasoning"
        case .max: return "Highest available answer quality"
        }
    }

    var symbol: String {
        switch self {
        case .instant: return "bolt"
        case .thinking: return "brain"
        case .max: return "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .instant: return .orange
        case .thinking: return .blue
        case .max: return .purple
        }
    }
}

// MARK: - Chat

enum ChatRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

struct Attachment: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case image, document }
    var id: UUID = UUID()
    var kind: Kind
    var filename: String
    /// Path relative to the app's Attachments directory.
    var relativePath: String
    /// Locally extracted text (OCR / PDF text / Vision analysis). Never leaves the device unless a cloud provider is used.
    var extractedText: String?
    var documentID: UUID?
}

struct TraceStep: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case running, done, failed, skipped }
    var id: UUID = UUID()
    var agent: String
    var title: String
    var detail: String = ""
    var status: Status = .running
    var durationMs: Int = 0
}

struct MessageMeta: Codable, Hashable, Sendable {
    var modelID: String = ""
    var modelName: String = ""
    var mode: IntelligenceMode = .instant
    var routeReason: String = ""
    var ttftMs: Int?
    var tokensPerSecond: Double?
    var generatedTokens: Int?
    var totalMs: Int?
    var usedCloud: Bool = false
    var usedWeb: Bool = false
    var toolsUsed: [String] = []
    var trace: [TraceStep] = []
    var thinking: String?
    var sources: [SourceRef] = []
    var verified: String?
    var warnings: [String] = []
}

struct SourceRef: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var title: String
    var location: String   // URL or "Document p.3" or "Memory"
    var snippet: String = ""
}

struct ChatMessage: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var role: ChatRole
    var content: String
    var createdAt: Date = Date()
    var attachments: [Attachment] = []
    var meta: MessageMeta?
}

struct Conversation: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var title: String = "New conversation"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var mode: IntelligenceMode = .thinking
    var projectID: UUID?
    var modelOverride: String?
    var messages: [ChatMessage] = []
}

struct ConversationSummary: Hashable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var preview: String
    var projectID: UUID?
}

// MARK: - Errors

enum NexusError: LocalizedError {
    case modelNotInstalled(String)
    case insufficientMemory(required: UInt64, available: UInt64, model: String)
    case modelLoadFailed(String)
    case contextOverflow(promptTokens: Int, contextSize: Int)
    case decodeFailed(Int32)
    case networkBlocked(String)
    case providerNotConfigured
    case provider(String)
    case cancelled
    case unavailable(String)
    case checksumMismatch(String)
    case insufficientStorage(required: Int64, available: Int64)
    case generic(String)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let m): return "\(m) is not installed. Download it from the Models tab."
        case let .insufficientMemory(req, avail, model):
            return "Not enough free memory to load \(model) safely (needs ≈\(ByteCountFormatter.memory(Int64(req))), \(ByteCountFormatter.memory(Int64(avail))) available). Choose a smaller model or close other apps."
        case .modelLoadFailed(let m): return "Failed to load model: \(m)"
        case let .contextOverflow(p, c): return "The prompt (\(p) tokens) does not fit the \(c)-token context window."
        case .decodeFailed(let code): return "Inference failed (llama_decode returned \(code))."
        case .networkBlocked(let why): return why
        case .providerNotConfigured: return "No cloud provider is configured. Add one in Settings → Cloud Providers."
        case .provider(let m): return m
        case .cancelled: return "Cancelled."
        case .unavailable(let m): return m
        case .checksumMismatch(let f): return "Checksum verification failed for \(f). The file was deleted."
        case let .insufficientStorage(req, avail):
            return "Not enough storage: needs \(ByteCountFormatter.file(req)), \(ByteCountFormatter.file(avail)) free."
        case .generic(let m): return m
        }
    }
}

extension ByteCountFormatter {
    static func memory(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
    static func file(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Thread-safe cancellation flag shared between async callers and inference threads.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    func truncated(to max: Int) -> String {
        count <= max ? self : String(prefix(max)) + "…"
    }

    /// Rough token estimate used only for budgeting (exact counts come from the tokenizer when available).
    var approxTokens: Int { max(1, Int(Double(utf8.count) / 3.6)) }
}

enum Paths {
    static var appSupport: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nexus", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var models: URL { dir("Models", excludeFromBackup: true) }
    static var attachments: URL { dir("Attachments") }
    static var downloads: URL { dir("Downloads", excludeFromBackup: true) }
    static var documentsInbox: URL {
        // Files dropped into the app's Documents folder via the Files app (UIFileSharingEnabled).
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func dir(_ name: String, excludeFromBackup: Bool = false) -> URL {
        var url = appSupport.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                     attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            if excludeFromBackup {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? url.setResourceValues(values)
            }
        }
        return url
    }
}
