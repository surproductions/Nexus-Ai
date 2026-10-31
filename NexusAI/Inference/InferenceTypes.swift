import Foundation
import CoreGraphics

/// A message passed to an inference backend.
struct PromptMessage: Sendable {
    var role: ChatRole
    var content: String
    var images: [CGImage] = []
}

struct GenerationRequest: Sendable {
    var system: String
    var messages: [PromptMessage]
    var maxTokens: Int = 1024
    var temperature: Float = 0.7
    var topP: Float = 0.9
    var topK: Int32 = 40
    var minP: Float = 0.05
    var repeatPenalty: Float = 1.05
    var enableThinking: Bool = false
    var stopSequences: [String] = []
    var seed: UInt32 = UInt32.random(in: 1...UInt32.max - 1)

    var hasImages: Bool { messages.contains { !$0.images.isEmpty } }
}

struct GenerationStats: Codable, Hashable, Sendable {
    var promptTokens: Int = 0
    var generatedTokens: Int = 0
    var timeToFirstTokenMs: Int = 0
    var promptEvalMs: Int = 0
    var decodeMs: Int = 0
    var totalMs: Int = 0
    var reusedPrefixTokens: Int = 0

    var tokensPerSecond: Double {
        decodeMs > 0 ? Double(generatedTokens) / (Double(decodeMs) / 1000) : 0
    }
    var promptTokensPerSecond: Double {
        promptEvalMs > 0 ? Double(promptTokens - reusedPrefixTokens) / (Double(promptEvalMs) / 1000) : 0
    }
}

enum GenerationEvent: Sendable {
    case text(String)
    case thinking(String)
    case stats(GenerationStats)
}

enum BackendKind: Hashable, Sendable {
    case local(String)        // registry model id
    case appleIntelligence
    case cloud(UUID)          // provider id
}

struct BackendDescriptor: Hashable, Sendable {
    var kind: BackendKind
    var displayName: String
    var contextLength: Int
    var supportsVision: Bool
    var supportsThinking: Bool
    var isOnDevice: Bool
}

/// Unified interface over llama.cpp models, Apple's on-device foundation model and cloud providers.
protocol InferenceBackend: AnyObject, Sendable {
    var descriptor: BackendDescriptor { get }
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
    /// Exact token count where the backend has a tokenizer; otherwise an estimate.
    func countTokens(_ text: String) -> Int
}

extension InferenceBackend {
    /// Runs a request to completion and returns the visible text (thinking excluded).
    func complete(_ request: GenerationRequest, cancel: CancellationFlag? = nil) async throws -> (text: String, thinking: String, stats: GenerationStats?) {
        var text = ""
        var thinking = ""
        var stats: GenerationStats?
        for try await event in generate(request) {
            if cancel?.isCancelled == true { throw NexusError.cancelled }
            switch event {
            case .text(let t): text += t
            case .thinking(let t): thinking += t
            case .stats(let s): stats = s
            }
        }
        return (text, thinking, stats)
    }
}

// MARK: - Chat prompt formats

enum PromptFormat: String, Codable, Sendable {
    case qwen35     // ChatML with <think> blocks (Qwen3 / Qwen3.5)
    case chatml     // plain ChatML (Qwen2.5)
    case gemma4     // <|turn>role ... <turn|>, thinking via <|channel>thought
    case phi4       // <|system|> ... <|end|>
    case llama3     // <|start_header_id|> ... <|eot_id|>
    case auto       // llama_chat_apply_template with the GGUF's embedded template

    var stopStrings: [String] {
        switch self {
        case .qwen35, .chatml: return ["<|im_end|>", "<|im_start|>", "<|endoftext|>"]
        case .gemma4: return ["<turn|>", "<|turn>", "<end_of_turn>"]
        case .phi4: return ["<|end|>", "<|user|>", "<|endoftext|>"]
        case .llama3: return ["<|eot_id|>", "<|start_header_id|>", "<|end_of_text|>"]
        case .auto: return []
        }
    }

    var thinkingMarkers: (open: String, close: String)? {
        switch self {
        case .qwen35: return ("<think>", "</think>")
        case .gemma4: return ("<|channel>thought", "<channel|>")
        default: return nil
        }
    }

    /// Builds the raw prompt. `imageMarker` is inserted once per image (mtmd media marker).
    func render(system: String, messages: [PromptMessage], thinking: Bool, imageMarker: String) -> String? {
        func body(_ m: PromptMessage) -> String {
            let markers = m.images.map { _ in imageMarker }.joined(separator: "\n")
            return markers.isEmpty ? m.content : markers + "\n" + m.content
        }
        var out = ""
        switch self {
        case .qwen35, .chatml:
            if !system.isEmpty { out += "<|im_start|>system\n\(system)<|im_end|>\n" }
            for m in messages {
                let role = m.role == .tool ? "user" : m.role.rawValue
                out += "<|im_start|>\(role)\n\(body(m))<|im_end|>\n"
            }
            out += "<|im_start|>assistant\n"
            if self == .qwen35 { out += thinking ? "<think>\n" : "<think>\n\n</think>\n\n" }
        case .gemma4:
            if !system.isEmpty || thinking {
                out += "<|turn>system\n" + (thinking ? "<|think|>\n" : "") + system + "<turn|>\n"
            }
            for m in messages {
                let role = m.role == .assistant ? "model" : "user"
                out += "<|turn>\(role)\n\(body(m))<turn|>\n"
            }
            out += "<|turn>model\n"
            if !thinking { out += "<|channel>thought\n<channel|>" }
        case .phi4:
            if !system.isEmpty { out += "<|system|>\(system)<|end|>" }
            for m in messages {
                let role = m.role == .assistant ? "assistant" : "user"
                out += "<|\(role)|>\(body(m))<|end|>"
            }
            out += "<|assistant|>"
        case .llama3:
            if !system.isEmpty { out += "<|start_header_id|>system<|end_header_id|>\n\n\(system)<|eot_id|>" }
            for m in messages {
                let role = m.role == .assistant ? "assistant" : "user"
                out += "<|start_header_id|>\(role)<|end_header_id|>\n\n\(body(m))<|eot_id|>"
            }
            out += "<|start_header_id|>assistant<|end_header_id|>\n\n"
        case .auto:
            return nil
        }
        return out
    }
}

// MARK: - Streaming output parser

/// Splits a raw token stream into visible text and thinking text, and stops on stop strings.
/// Holds back partial markers so they never flash in the UI.
struct OutputStreamParser {
    private(set) var inThinking: Bool
    private let open: String?
    private let close: String?
    private let stops: [String]
    private var buffer = ""
    private(set) var stopped = false

    init(format: PromptFormat, thinkingEnabled: Bool, extraStops: [String]) {
        open = format.thinkingMarkers?.open ?? "<think>"
        close = format.thinkingMarkers?.close ?? "</think>"
        // Qwen3.5 prompts are pre-filled with "<think>\n" so output starts inside the thinking block.
        inThinking = thinkingEnabled && format == .qwen35
        stops = format.stopStrings + extraStops
    }

    /// Feed newly decoded text, receive events to emit.
    mutating func feed(_ piece: String) -> [GenerationEvent] {
        guard !stopped else { return [] }
        buffer += piece
        var events: [GenerationEvent] = []
        while true {
            let marker = inThinking ? close : open
            let markerRange = marker.flatMap { buffer.range(of: $0) }
            // Stop strings apply to visible text, and only if they come before the next marker.
            if !inThinking, let stop = firstStop(in: buffer),
               markerRange == nil || stop.lowerBound <= markerRange!.lowerBound {
                events.append(contentsOf: emit(String(buffer[..<stop.lowerBound])))
                buffer = ""
                stopped = true
                return events
            }
            guard let r = markerRange else { break }
            events.append(contentsOf: emit(String(buffer[..<r.lowerBound])))
            buffer = String(buffer[r.upperBound...])
            inThinking.toggle()
            if !inThinking { buffer = String(buffer.drop(while: { $0 == "\n" })) }
        }
        // Hold back the longest suffix that could begin a marker or stop string.
        let candidates = [open, close].compactMap { $0 } + (inThinking ? [] : stops)
        let hold = candidates.map { Self.partialSuffixLength(buffer, $0) }.max() ?? 0
        let emitCount = buffer.count - hold
        if emitCount > 0 {
            let head = String(buffer.prefix(emitCount))
            buffer = String(buffer.dropFirst(emitCount))
            events.append(contentsOf: emit(head))
        }
        return events
    }

    mutating func finish() -> [GenerationEvent] {
        guard !stopped else { return [] }
        stopped = true
        var rest = buffer
        buffer = ""
        if !inThinking, let stop = firstStop(in: rest) { rest = String(rest[..<stop.lowerBound]) }
        return emit(rest)
    }

    private func firstStop(in text: String) -> Range<String.Index>? {
        stops.filter { !$0.isEmpty }.compactMap { text.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
    }

    private func emit(_ s: String) -> [GenerationEvent] {
        guard !s.isEmpty else { return [] }
        return [inThinking ? .thinking(s) : .text(s)]
    }

    static func partialSuffixLength(_ text: String, _ marker: String) -> Int {
        let maxLen = min(text.count, marker.count - 1)
        guard maxLen > 0 else { return 0 }
        for len in stride(from: maxLen, through: 1, by: -1) where marker.hasPrefix(String(text.suffix(len))) {
            return len
        }
        return 0
    }
}

/// Incrementally decodes UTF-8 bytes that may be split across tokens.
struct UTF8Accumulator {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) -> String {
        pending.append(contentsOf: bytes)
        // Find the longest prefix that ends on a complete UTF-8 sequence.
        var end = pending.count
        var i = pending.count - 1
        var back = 0
        while i >= 0 && back < 4 {
            let b = pending[i]
            if b & 0b1100_0000 == 0b1000_0000 { i -= 1; back += 1; continue }
            let need: Int
            if b & 0b1000_0000 == 0 { need = 1 }
            else if b & 0b1110_0000 == 0b1100_0000 { need = 2 }
            else if b & 0b1111_0000 == 0b1110_0000 { need = 3 }
            else if b & 0b1111_1000 == 0b1111_0000 { need = 4 }
            else { need = 1 }
            if pending.count - i < need { end = i }
            break
        }
        guard end > 0 else { return "" }
        let chunk = Array(pending[0..<end])
        pending.removeFirst(end)
        return String(decoding: chunk, as: UTF8.self)
    }

    mutating func flush() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}
