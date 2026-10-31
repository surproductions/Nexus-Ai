import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device ~3B foundation model (iOS 26+, Apple Intelligence–capable devices).
/// Runs in a system process, so it does not count against the app's memory limit and needs no download.
enum AppleIntelligence {
    struct Status {
        var available: Bool
        var reason: String
    }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return Status(available: true, reason: "Available on this device")
            case .unavailable(let why):
                switch why {
                case .deviceNotEligible: return Status(available: false, reason: "This device does not support Apple Intelligence")
                case .appleIntelligenceNotEnabled: return Status(available: false, reason: "Apple Intelligence is turned off in Settings")
                case .modelNotReady: return Status(available: false, reason: "Apple's model is still downloading")
                @unknown default: return Status(available: false, reason: "Unavailable")
                }
            }
        }
        return Status(available: false, reason: "Requires iOS 26")
        #else
        return Status(available: false, reason: "Not supported by this build")
        #endif
    }

    static var isAvailable: Bool { status.available }
}

final class AppleFoundationBackend: InferenceBackend, @unchecked Sendable {
    static let modelID = "apple.foundation"
    let descriptor = BackendDescriptor(kind: .appleIntelligence, displayName: "Apple Intelligence (on-device)",
                                       contextLength: 4096, supportsVision: false, supportsThinking: false,
                                       isOnDevice: true)

    func countTokens(_ text: String) -> Int { text.approxTokens }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            guard #available(iOS 26.0, *) else {
                continuation.finish(throwing: NexusError.unavailable("Apple Intelligence requires iOS 26."))
                return
            }
            let task = Task {
                do {
                    // The framework keeps its own transcript; we pass prior turns inside the prompt so that
                    // memory/context management stays identical across backends.
                    var history = ""
                    for m in request.messages.dropLast() {
                        let who = m.role == .assistant ? "Assistant" : "User"
                        history += "\(who): \(m.content)\n\n"
                    }
                    let last = request.messages.last?.content ?? ""
                    let prompt = history.isEmpty ? last : "Conversation so far:\n\(history)User: \(last)"
                    let session = LanguageModelSession(instructions: request.system)
                    let options = GenerationOptions(temperature: Double(request.temperature),
                                                    maximumResponseTokens: request.maxTokens)
                    let start = Date()
                    var first: Date?
                    var emitted = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        if Task.isCancelled { break }
                        let full = snapshot.content
                        if full.count > emitted.count, full.hasPrefix(emitted) {
                            if first == nil { first = Date() }
                            continuation.yield(.text(String(full.dropFirst(emitted.count))))
                            emitted = full
                        } else if full != emitted {
                            emitted = full
                        }
                    }
                    let end = Date()
                    var stats = GenerationStats()
                    stats.promptTokens = prompt.approxTokens + request.system.approxTokens
                    stats.generatedTokens = emitted.approxTokens
                    stats.timeToFirstTokenMs = Int(((first ?? end).timeIntervalSince(start)) * 1000)
                    stats.decodeMs = Int(end.timeIntervalSince(first ?? start) * 1000)
                    stats.totalMs = Int(end.timeIntervalSince(start) * 1000)
                    continuation.yield(.stats(stats))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: NexusError.provider("Apple Intelligence: \(error.localizedDescription)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
            #else
            continuation.finish(throwing: NexusError.unavailable("Apple Intelligence is not available in this build."))
            #endif
        }
    }
}
