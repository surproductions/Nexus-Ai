import Foundation
import UIKit

struct CloudProviderConfig: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case openAICompatible = "OpenAI-compatible"
        case anthropic = "Anthropic"
    }
    var id = UUID()
    var name: String
    var kind: Kind
    var baseURL: String
    var model: String
    var supportsVision: Bool = true
    var contextLength: Int = 128_000

    var keychainKey: String { "provider.\(id.uuidString)" }
    var apiKey: String? { Keychain.get(keychainKey) }

    static let presets: [CloudProviderConfig] = [
        CloudProviderConfig(name: "Anthropic Claude", kind: .anthropic, baseURL: "https://api.anthropic.com",
                            model: "claude-sonnet-5-5", contextLength: 200_000),
        CloudProviderConfig(name: "OpenAI", kind: .openAICompatible, baseURL: "https://api.openai.com/v1",
                            model: "gpt-5", contextLength: 128_000),
        CloudProviderConfig(name: "OpenRouter", kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1",
                            model: "anthropic/claude-sonnet-5-5", contextLength: 128_000),
        CloudProviderConfig(name: "Self-hosted (Ollama / LM Studio)", kind: .openAICompatible,
                            baseURL: "http://192.168.1.10:11434/v1", model: "qwen3.5:9b",
                            supportsVision: false, contextLength: 32_000),
    ]
}

/// Provider abstraction for optional remote inference. Requests go through `NetworkGate`, which enforces
/// Offline-Only mode, consent and logging.
final class CloudBackend: InferenceBackend, @unchecked Sendable {
    let config: CloudProviderConfig
    let descriptor: BackendDescriptor

    init(config: CloudProviderConfig) {
        self.config = config
        descriptor = BackendDescriptor(kind: .cloud(config.id), displayName: "\(config.name) · \(config.model)",
                                       contextLength: config.contextLength, supportsVision: config.supportsVision,
                                       supportsThinking: false, isOnDevice: false)
    }

    func countTokens(_ text: String) -> Int { text.approxTokens }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let config = self.config
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let key = config.apiKey ?? ""
                    guard !key.isEmpty || config.baseURL.hasPrefix("http://") else {
                        throw NexusError.providerNotConfigured
                    }
                    let urlRequest = try Self.makeRequest(config: config, apiKey: key, request: request)
                    let start = Date()
                    var first: Date?
                    var produced = ""
                    let (bytes, http) = try await NetworkGate.shared.bytes(
                        for: urlRequest, feature: .cloudInference,
                        summary: "\(config.name) \(config.model): \(request.messages.last?.content.truncated(to: 60) ?? "")")
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 2000 { break } }
                        throw NexusError.provider("\(config.name) returned HTTP \(http.statusCode): \(body.truncated(to: 300))")
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        for event in Self.parse(json, kind: config.kind) {
                            if case .text(let t) = event {
                                if first == nil { first = Date() }
                                produced += t
                            }
                            continuation.yield(event)
                        }
                    }
                    let end = Date()
                    var stats = GenerationStats()
                    stats.generatedTokens = produced.approxTokens
                    stats.timeToFirstTokenMs = Int(((first ?? end).timeIntervalSince(start)) * 1000)
                    stats.decodeMs = Int(end.timeIntervalSince(first ?? start) * 1000)
                    stats.totalMs = Int(end.timeIntervalSince(start) * 1000)
                    continuation.yield(.stats(stats))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func jpegBase64(_ image: CGImage) -> String? {
        let ui = UIImage(cgImage: image)
        let maxSide: CGFloat = 1568
        let scale = min(1, maxSide / max(ui.size.width, ui.size.height))
        let size = CGSize(width: ui.size.width * scale, height: ui.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in ui.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.8)?.base64EncodedString()
    }

    static func makeRequest(config: CloudProviderConfig, apiKey: String, request: GenerationRequest) throws -> URLRequest {
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        var body: [String: Any] = ["model": config.model, "stream": true, "max_tokens": request.maxTokens]
        var urlString: String
        var headers: [String: String] = ["Content-Type": "application/json"]

        switch config.kind {
        case .openAICompatible:
            urlString = base + "/chat/completions"
            if !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
            var msgs: [[String: Any]] = []
            if !request.system.isEmpty { msgs.append(["role": "system", "content": request.system]) }
            for m in request.messages {
                let role = m.role == .assistant ? "assistant" : "user"
                if m.images.isEmpty || !config.supportsVision {
                    msgs.append(["role": role, "content": m.content])
                } else {
                    var parts: [[String: Any]] = [["type": "text", "text": m.content]]
                    for img in m.images {
                        if let b64 = jpegBase64(img) {
                            parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]])
                        }
                    }
                    msgs.append(["role": role, "content": parts])
                }
            }
            body["messages"] = msgs
            body["temperature"] = request.temperature
        case .anthropic:
            urlString = base + "/v1/messages"
            headers["x-api-key"] = apiKey
            headers["anthropic-version"] = "2023-06-01"
            if !request.system.isEmpty { body["system"] = request.system }
            // Anthropic requires alternating roles; merge consecutive messages of the same role.
            var msgs: [[String: Any]] = []
            var lastRole = ""
            for m in request.messages {
                let role = m.role == .assistant ? "assistant" : "user"
                var parts: [[String: Any]] = []
                if config.supportsVision {
                    for img in m.images {
                        if let b64 = jpegBase64(img) {
                            parts.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]])
                        }
                    }
                }
                parts.append(["type": "text", "text": m.content.isEmpty ? "(empty)" : m.content])
                if role == lastRole, var prev = msgs.popLast(), var content = prev["content"] as? [[String: Any]] {
                    content.append(contentsOf: parts)
                    prev["content"] = content
                    msgs.append(prev)
                } else {
                    msgs.append(["role": role, "content": parts])
                }
                lastRole = role
            }
            if msgs.first?["role"] as? String == "assistant" {
                msgs.insert(["role": "user", "content": [["type": "text", "text": "(continue)"]]], at: 0)
            }
            body["messages"] = msgs
        }
        guard let url = URL(string: urlString) else { throw NexusError.provider("Invalid provider URL") }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 180
        headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    static func parse(_ json: [String: Any], kind: CloudProviderConfig.Kind) -> [GenerationEvent] {
        switch kind {
        case .openAICompatible:
            guard let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { return [] }
            var events: [GenerationEvent] = []
            if let r = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !r.isEmpty { events.append(.thinking(r)) }
            if let c = delta["content"] as? String, !c.isEmpty { events.append(.text(c)) }
            return events
        case .anthropic:
            guard (json["type"] as? String) == "content_block_delta",
                  let delta = json["delta"] as? [String: Any] else { return [] }
            if let t = delta["text"] as? String { return [.text(t)] }
            if let t = delta["thinking"] as? String { return [.thinking(t)] }
            return []
        }
    }
}
