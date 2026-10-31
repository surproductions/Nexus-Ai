import Foundation
import CoreGraphics
import llama

/// Configuration for a llama.cpp context, derived from the hardware profile and intelligence mode.
struct LlamaConfig: Hashable, Sendable {
    var contextLength: Int = 4096
    var batchSize: Int = 512
    var gpuLayers: Int32 = 999          // offload everything to Metal
    var flashAttention: Bool = true
    var quantizeKVCache: Bool = false   // q8_0 K/V cache halves KV memory (requires flash attention)
    var threads: Int32 = 2
}

final class LoadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Double) -> Void)?
    private var _cancelled = false
    init(_ handler: ((Double) -> Void)?) { self.handler = handler }
    func report(_ p: Float) { lock.lock(); let h = handler; lock.unlock(); h?(Double(p)) }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

/// Owns one llama.cpp model + context (+ optional multimodal projector).
/// All C calls happen on a private serial queue; the class is safe to share across tasks.
final class LlamaRuntime: @unchecked Sendable {
    let modelURL: URL
    let projectorURL: URL?
    let config: LlamaConfig

    private let queue = DispatchQueue(label: "ai.nexus.llama", qos: .userInitiated)
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var mtmdCtx: OpaquePointer?
    private var batch: llama_batch
    private var cachedTokens: [llama_token] = []

    private(set) var contextLength: Int = 0
    private(set) var trainedContextLength: Int = 0
    private(set) var modelDescription: String = ""
    private(set) var parameterCount: UInt64 = 0
    private(set) var modelSizeBytes: UInt64 = 0
    private(set) var imageMarker: String = "<__media__>"
    private(set) var loadTimeMs: Int = 0

    var supportsVision: Bool { mtmdCtx != nil }

    private static let backendInit: Void = {
        llama_backend_init()
        // Silence verbose native logging in release builds.
        llama_log_set({ _, _, _ in }, nil)
    }()

    private init(modelURL: URL, projectorURL: URL?, config: LlamaConfig) {
        self.modelURL = modelURL
        self.projectorURL = projectorURL
        self.config = config
        self.batch = llama_batch_init(Int32(config.batchSize), 0, 1)
    }

    deinit {
        if let mtmdCtx { mtmd_free(mtmdCtx) }
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        llama_batch_free(batch)
    }

    /// Loads a GGUF model. Runs on a background queue; throws if loading fails.
    static func load(modelURL: URL, projectorURL: URL?, config: LlamaConfig,
                     progress: LoadProgress? = nil) async throws -> LlamaRuntime {
        _ = backendInit
        let runtime = LlamaRuntime(modelURL: modelURL, projectorURL: projectorURL, config: config)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            runtime.queue.async {
                do {
                    try runtime.loadOnQueue(progress: progress)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        return runtime
    }

    private func loadOnQueue(progress: LoadProgress?) throws {
        let start = Date()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = config.gpuLayers
        if let progress {
            mp.progress_callback = { value, userData in
                guard let userData else { return true }
                let box = Unmanaged<LoadProgress>.fromOpaque(userData).takeUnretainedValue()
                box.report(value)
                return !box.cancelled
            }
            mp.progress_callback_user_data = Unmanaged.passUnretained(progress).toOpaque()
        }
        guard let model = modelURL.path.withCString({ llama_model_load_from_file($0, mp) }) else {
            throw NexusError.modelLoadFailed(modelURL.lastPathComponent)
        }
        self.model = model
        self.vocab = llama_model_get_vocab(model)
        trainedContextLength = Int(llama_model_n_ctx_train(model))
        parameterCount = llama_model_n_params(model)
        modelSizeBytes = llama_model_size(model)
        var desc = [CChar](repeating: 0, count: 256)
        let n = llama_model_desc(model, &desc, desc.count)
        modelDescription = n > 0 ? String(cString: desc) : modelURL.lastPathComponent

        var cp = llama_context_default_params()
        let nCtx = min(config.contextLength, trainedContextLength > 0 ? trainedContextLength : config.contextLength)
        cp.n_ctx = UInt32(nCtx)
        cp.n_batch = UInt32(config.batchSize)
        cp.n_ubatch = UInt32(config.batchSize)
        cp.n_threads = config.threads
        cp.n_threads_batch = config.threads
        cp.flash_attn_type = config.flashAttention ? LLAMA_FLASH_ATTN_TYPE_AUTO : LLAMA_FLASH_ATTN_TYPE_DISABLED
        if config.quantizeKVCache && config.flashAttention {
            cp.type_k = GGML_TYPE_Q8_0
            cp.type_v = GGML_TYPE_Q8_0
        }
        guard let ctx = llama_init_from_model(model, cp) else {
            throw NexusError.modelLoadFailed("Could not create a \(nCtx)-token context for \(modelURL.lastPathComponent)")
        }
        self.ctx = ctx
        contextLength = Int(llama_n_ctx(ctx))

        if let projectorURL, FileManager.default.fileExists(atPath: projectorURL.path) {
            var mp = mtmd_context_params_default()
            mp.use_gpu = true
            mp.n_threads = Int32(config.threads)
            mp.print_timings = false
            mp.warmup = false
            if let m = projectorURL.path.withCString({ mtmd_init_from_file($0, model, mp) }) {
                if mtmd_support_vision(m) {
                    mtmdCtx = m
                    if let marker = mtmd_default_marker() { imageMarker = String(cString: marker) }
                } else {
                    mtmd_free(m)
                }
            }
        }
        loadTimeMs = Int(Date().timeIntervalSince(start) * 1000)
    }

    // MARK: - Tokenizer

    func tokenCount(_ text: String) -> Int {
        queue.sync { tokenize(text, addSpecial: false).count }
    }

    private func tokenize(_ text: String, addSpecial: Bool) -> [llama_token] {
        guard let vocab else { return [] }
        let byteCount = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(byteCount) + 16)
        var n = llama_tokenize(vocab, text, byteCount, &tokens, Int32(tokens.count), addSpecial, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, byteCount, &tokens, Int32(tokens.count), addSpecial, true)
        }
        return n > 0 ? Array(tokens.prefix(Int(n))) : []
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        guard let vocab else { return [] }
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
        }
        guard n > 0 else { return [] }
        return buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }

    /// Applies the GGUF's embedded chat template (used for user-imported models).
    func applyEmbeddedTemplate(system: String, messages: [PromptMessage]) -> String {
        queue.sync {
            var all: [(String, String)] = []
            if !system.isEmpty { all.append(("system", system)) }
            for m in messages {
                let marker = m.images.map { _ in imageMarker }.joined(separator: "\n")
                let content = marker.isEmpty ? m.content : marker + "\n" + m.content
                all.append((m.role == .tool ? "user" : m.role.rawValue, content))
            }
            let roles = all.map { strdup($0.0) }
            let contents = all.map { strdup($0.1) }
            defer { roles.forEach { free($0) }; contents.forEach { free($0) } }
            var chat = (0..<all.count).map { llama_chat_message(role: roles[$0], content: contents[$0]) }
            let tmpl = model.flatMap { llama_model_chat_template($0, nil) }
            let total = all.reduce(0) { $0 + $1.1.utf8.count } * 2 + 1024
            var buf = [CChar](repeating: 0, count: total)
            var n = llama_chat_apply_template(tmpl, &chat, chat.count, true, &buf, Int32(buf.count))
            if n > Int32(buf.count) {
                buf = [CChar](repeating: 0, count: Int(n) + 1)
                n = llama_chat_apply_template(tmpl, &chat, chat.count, true, &buf, Int32(buf.count))
            }
            if n > 0 {
                return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            // Fallback: ChatML, understood by most instruction-tuned models.
            return PromptFormat.chatml.render(system: system, messages: messages, thinking: false, imageMarker: imageMarker) ?? ""
        }
    }

    // MARK: - Generation

    struct Sampling: Sendable {
        var maxTokens: Int
        var temperature: Float
        var topK: Int32
        var topP: Float
        var minP: Float
        var repeatPenalty: Float
        var seed: UInt32
    }

    /// Streams raw decoded text for a fully rendered prompt.
    func generate(prompt: String, images: [CGImage], sampling: Sampling,
                  onPiece: @escaping (String) -> Bool,
                  cancel: CancellationFlag) async throws -> GenerationStats {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GenerationStats, Error>) in
            queue.async {
                do {
                    let stats = try self.generateOnQueue(prompt: prompt, images: images, sampling: sampling,
                                                         onPiece: onPiece, cancel: cancel)
                    cont.resume(returning: stats)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func batchAdd(_ token: llama_token, _ pos: Int, logits: Bool) {
        let i = Int(batch.n_tokens)
        batch.token[i] = token
        batch.pos[i] = llama_pos(pos)
        batch.n_seq_id[i] = 1
        batch.seq_id[i]![0] = 0
        batch.logits[i] = logits ? 1 : 0
        batch.n_tokens += 1
    }

    private func generateOnQueue(prompt: String, images: [CGImage], sampling: Sampling,
                                 onPiece: (String) -> Bool, cancel: CancellationFlag) throws -> GenerationStats {
        guard let ctx, let vocab, let model else { throw NexusError.modelLoadFailed("Model not loaded") }
        let memory = llama_get_memory(ctx)
        var stats = GenerationStats()
        let t0 = Date()
        var nPast = 0
        var promptTokens: [llama_token] = []

        if !images.isEmpty, let mtmdCtx {
            // Multimodal path: re-evaluate the whole prompt with image embeddings.
            llama_memory_clear(memory, true)
            cachedTokens = []
            let bitmaps: [OpaquePointer?] = images.map { Self.makeBitmap($0) }
            defer { bitmaps.forEach { if let b = $0 { mtmd_bitmap_free(b) } } }
            guard let chunks = mtmd_input_chunks_init() else { throw NexusError.generic("mtmd init failed") }
            defer { mtmd_input_chunks_free(chunks) }
            let rc: Int32 = prompt.withCString { cstr in
                var input = mtmd_input_text(text: cstr, text_len: strlen(cstr), add_special: true, parse_special: true)
                return bitmaps.withUnsafeBufferPointer { bp in
                    mtmd_tokenize(mtmdCtx, chunks, &input, bp.baseAddress, bp.count)
                }
            }
            guard rc == 0 else { throw NexusError.generic("Image preprocessing failed (mtmd_tokenize=\(rc))") }
            let total = Int(mtmd_helper_get_n_tokens(chunks))
            guard total + 16 < contextLength else { throw NexusError.contextOverflow(promptTokens: total, contextSize: contextLength) }
            var newPast: llama_pos = 0
            let er = mtmd_helper_eval_chunks(mtmdCtx, ctx, chunks, 0, 0, Int32(config.batchSize), true, &newPast)
            guard er == 0 else { throw NexusError.decodeFailed(er) }
            nPast = Int(newPast)
            stats.promptTokens = total
        } else {
            promptTokens = tokenize(prompt, addSpecial: true)
            stats.promptTokens = promptTokens.count
            guard promptTokens.count + 8 < contextLength else {
                throw NexusError.contextOverflow(promptTokens: promptTokens.count, contextSize: contextLength)
            }
            // KV-cache prefix reuse across turns.
            var common = 0
            let limit = min(cachedTokens.count, promptTokens.count)
            while common < limit && cachedTokens[common] == promptTokens[common] { common += 1 }
            if common == promptTokens.count { common -= 1 } // need logits for the last prompt token
            if common < cachedTokens.count {
                if !llama_memory_seq_rm(memory, 0, llama_pos(common), -1) {
                    // Recurrent/hybrid architectures cannot drop a partial sequence.
                    llama_memory_clear(memory, true)
                    common = 0
                }
            }
            stats.reusedPrefixTokens = common
            var i = common
            while i < promptTokens.count {
                if cancel.isCancelled { throw NexusError.cancelled }
                batch.n_tokens = 0
                let n = min(config.batchSize, promptTokens.count - i)
                for j in 0..<n {
                    batchAdd(promptTokens[i + j], i + j, logits: i + j == promptTokens.count - 1)
                }
                let rc = llama_decode(ctx, batch)
                if rc != 0 {
                    llama_memory_clear(memory, true)
                    cachedTokens = []
                    throw NexusError.decodeFailed(rc)
                }
                i += n
            }
            nPast = promptTokens.count
            cachedTokens = promptTokens
        }
        stats.promptEvalMs = Int(Date().timeIntervalSince(t0) * 1000)

        // Sampler chain: penalties → top-k → top-p → min-p → temperature → distribution.
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(chain) }
        if sampling.repeatPenalty > 1.0 {
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, sampling.repeatPenalty, 0, 0))
        }
        if sampling.temperature <= 0.01 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(sampling.topK))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(sampling.topP, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(sampling.minP, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_temp(sampling.temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(sampling.seed))
        }

        var utf8 = UTF8Accumulator()
        let decodeStart = Date()
        var firstTokenAt: Date?
        var generated = 0
        let maxTokens = min(sampling.maxTokens, contextLength - nPast - 1)
        var pos = nPast
        _ = model

        while generated < maxTokens {
            if cancel.isCancelled { break }
            let token = llama_sampler_sample(chain, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            generated += 1
            if firstTokenAt == nil { firstTokenAt = Date() }
            let text = utf8.append(piece(token))
            if !text.isEmpty && !onPiece(text) { break }
            if !promptTokens.isEmpty { cachedTokens.append(token) }

            batch.n_tokens = 0
            batchAdd(token, pos, logits: true)
            let rc = llama_decode(ctx, batch)
            if rc != 0 {
                llama_memory_clear(memory, true)
                cachedTokens = []
                throw NexusError.decodeFailed(rc)
            }
            pos += 1
        }
        let tail = utf8.flush()
        if !tail.isEmpty { _ = onPiece(tail) }
        if promptTokens.isEmpty { cachedTokens = [] }

        let end = Date()
        stats.generatedTokens = generated
        stats.timeToFirstTokenMs = Int(((firstTokenAt ?? end).timeIntervalSince(t0)) * 1000)
        stats.decodeMs = Int(end.timeIntervalSince(firstTokenAt ?? decodeStart) * 1000)
        stats.totalMs = Int(end.timeIntervalSince(t0) * 1000)
        if cancel.isCancelled && generated == 0 { throw NexusError.cancelled }
        return stats
    }

    func resetCache() {
        queue.async {
            if let ctx = self.ctx { llama_memory_clear(llama_get_memory(ctx), true) }
            self.cachedTokens = []
        }
    }

    /// Converts an image into the packed RGB bitmap mtmd expects, downscaling very large photos.
    private static func makeBitmap(_ image: CGImage, maxSide: Int = 1280) -> OpaquePointer? {
        let scale = min(1.0, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let ok: Bool = rgba.withUnsafeMutableBytes { raw in
            guard let cg = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                     bytesPerRow: w * 4, space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            cg.interpolationQuality = .high
            cg.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for p in 0..<(w * h) {
            rgb[p * 3] = rgba[p * 4]
            rgb[p * 3 + 1] = rgba[p * 4 + 1]
            rgb[p * 3 + 2] = rgba[p * 4 + 2]
        }
        return rgb.withUnsafeBufferPointer { mtmd_bitmap_init(UInt32(w), UInt32(h), $0.baseAddress) }
    }
}

/// `InferenceBackend` over a loaded `LlamaRuntime`.
final class LlamaBackend: InferenceBackend, @unchecked Sendable {
    let runtime: LlamaRuntime
    let descriptor: BackendDescriptor
    let format: PromptFormat

    init(runtime: LlamaRuntime, entry: ModelEntry) {
        self.runtime = runtime
        self.format = entry.promptFormat
        self.descriptor = BackendDescriptor(kind: .local(entry.id), displayName: entry.name,
                                            contextLength: runtime.contextLength,
                                            supportsVision: runtime.supportsVision,
                                            supportsThinking: entry.supportsThinking,
                                            isOnDevice: true)
    }

    func countTokens(_ text: String) -> Int { runtime.tokenCount(text) }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let runtime = self.runtime
        let format = self.format
        let thinking = request.enableThinking && descriptor.supportsThinking
        let messages = runtime.supportsVision ? request.messages : request.messages.map {
            PromptMessage(role: $0.role, content: $0.content, images: [])
        }
        let prompt = format.render(system: request.system, messages: messages, thinking: thinking,
                                   imageMarker: runtime.imageMarker)
            ?? runtime.applyEmbeddedTemplate(system: request.system, messages: messages)
        let images = messages.flatMap(\.images)
        let sampling = LlamaRuntime.Sampling(maxTokens: request.maxTokens, temperature: request.temperature,
                                             topK: request.topK, topP: request.topP, minP: request.minP,
                                             repeatPenalty: request.repeatPenalty, seed: request.seed)
        let stops = request.stopSequences

        return AsyncThrowingStream { continuation in
            let cancel = CancellationFlag()
            continuation.onTermination = { _ in cancel.cancel() }
            Task.detached(priority: .userInitiated) {
                var parser = OutputStreamParser(format: format, thinkingEnabled: thinking, extraStops: stops)
                do {
                    let stats = try await runtime.generate(prompt: prompt, images: images, sampling: sampling, onPiece: { piece in
                        for e in parser.feed(piece) { continuation.yield(e) }
                        return !parser.stopped && !cancel.isCancelled
                    }, cancel: cancel)
                    for e in parser.finish() { continuation.yield(e) }
                    continuation.yield(.stats(stats))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
