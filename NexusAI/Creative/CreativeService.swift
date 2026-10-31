import Foundation
import CoreGraphics
import UIKit
import Vision

struct CreativeJob: Identifiable, Sendable {
    enum Kind: String, Sendable { case image, video, edit }
    enum State: Sendable, Equatable { case running, succeeded, failed(String), cancelled }
    var id = UUID()
    var kind: Kind
    var prompt: String
    var providerName: String
    var isLocal: Bool
    var state: State = .running
    var progress: Double?
    var message: String = "Starting…"
    var resultIDs: [UUID] = []
    var started = Date()
    let cancel = CancellationFlag()
}

/// Coordinates generation providers, editing, safety and the media library.
@MainActor
final class CreativeService: ObservableObject {
    @Published private(set) var jobs: [CreativeJob] = []
    @Published var falEndpoints: [FalEndpoint] { didSet { saveEndpoints() } }
    @Published var openAIImageModel: String { didSet { UserDefaults.standard.set(openAIImageModel, forKey: "creative.openai.imageModel") } }
    @Published var openAIVideoModel: String { didSet { UserDefaults.standard.set(openAIVideoModel, forKey: "creative.openai.videoModel") } }

    let library: MediaLibrary
    let models: ModelManager
    let settings: SettingsStore
    weak var orchestrator: Orchestrator?
    private var sdProvider: StableDiffusionProvider?

    init(library: MediaLibrary, models: ModelManager, settings: SettingsStore) {
        self.library = library
        self.models = models
        self.settings = settings
        if let d = UserDefaults.standard.data(forKey: "creative.fal.endpoints"), let list = try? JSONDecoder().decode([FalEndpoint].self, from: d) {
            falEndpoints = list
        } else {
            falEndpoints = FalEndpoint.presets
        }
        openAIImageModel = UserDefaults.standard.string(forKey: "creative.openai.imageModel") ?? "gpt-image-1"
        openAIVideoModel = UserDefaults.standard.string(forKey: "creative.openai.videoModel") ?? "sora-2"
    }

    private func saveEndpoints() {
        if let d = try? JSONEncoder().encode(falEndpoints) { UserDefaults.standard.set(d, forKey: "creative.fal.endpoints") }
    }

    // MARK: Providers

    var sdEntry: ModelEntry? { ModelRegistry.catalog.first { $0.modelKind == .imageDiffusion } }

    var imageProviders: [ImageGenerationProvider] {
        var list: [ImageGenerationProvider] = [ApplePlaygroundProvider()]
        if let e = sdEntry, models.isInstalled(e.id) {
            let url = ModelManager.localURL(e)
            if sdProvider?.resourcesURL != url { sdProvider = StableDiffusionProvider(resourcesURL: url) }
            if let sd = sdProvider { list.append(sd) }
        }
        list.append(OpenAIImageProvider(model: openAIImageModel))
        list += falEndpoints.filter { $0.kind == .image || $0.kind == .imageEdit }.map { FalImageProvider(endpoint: $0) }
        return list
    }

    var videoProviders: [VideoGenerationProvider] {
        [OpenAIVideoProvider(model: openAIVideoModel)] +
            falEndpoints.filter { $0.kind == .textToVideo || $0.kind == .imageToVideo }.map { FalVideoProvider(endpoint: $0) }
    }

    func imageProvider(_ id: String) -> ImageGenerationProvider? { imageProviders.first { $0.id == id } }
    func videoProvider(_ id: String) -> VideoGenerationProvider? { videoProviders.first { $0.id == id } }

    /// Picks the best available provider for the request and mode. Local first in Instant/Thinking; Max may use
    /// cloud providers when the user has enabled cloud generation.
    func autoImageProvider(for request: ImageGenRequest, mode: IntelligenceMode) async throws -> ImageGenerationProvider {
        var needs: Set<ImageCapability> = [.textToImage]
        if request.editSource != nil { needs = [.instructionEdit] }
        else if !request.referenceImages.isEmpty { needs.insert(.reference) }
        if request.mask != nil { needs.insert(.maskedEdit) }
        if request.transparentBackground { needs.insert(.transparentBackground) }
        let wantsPhoto = ["photo", "cinematic", "product", "architecture"].contains(request.style.id)

        var available: [ImageGenerationProvider] = []
        for p in imageProviders where needs.isSubset(of: p.capabilities) {
            if await p.status().available { available.append(p) }
        }
        guard !available.isEmpty else {
            throw CreativeError.unavailable(unavailableExplanation(needs: needs))
        }
        func rank(_ p: ImageGenerationProvider) -> Int {
            var score = 0
            if wantsPhoto && p.capabilities.contains(.photorealism) { score += 4 }
            if wantsPhoto && p.id == "apple.playground" { score -= 5 }
            switch mode {
            case .instant: score += p.isLocal ? 6 : 0; score += p.id == "apple.playground" ? 2 : 0
            case .thinking: score += p.isLocal ? 5 : 0; score += p.id == "local.sd21" ? 1 : 0
            case .max: score += p.isLocal ? 0 : 6; score += p.id == "openai.image" ? 1 : 0
            }
            return score
        }
        return available.max { rank($0) < rank($1) }!
    }

    private func unavailableExplanation(needs: Set<ImageCapability>) -> String {
        var s = "No image provider that supports \(needs.map(\.rawValue).sorted().joined(separator: " + ").lowercased()) is available right now."
        if !AppleIntelligence.isAvailable { s += " Apple Image Playground needs Apple Intelligence (iOS 18.4+)." }
        if let e = sdEntry, !models.isInstalled(e.id) { s += " You can download “\(e.name)” in Models for local generation." }
        if settings.offlineOnly { s += " Cloud providers are blocked by Offline-Only mode." }
        else if !settings.allowCloudGeneration { s += " Cloud providers can be enabled in Settings → Privacy & network → Cloud image & video generation." }
        return s
    }

    func autoVideoProvider(for request: VideoGenRequest) async throws -> VideoGenerationProvider {
        let need: VideoCapability = request.remixOf != nil ? .remix : (request.referenceImage != nil ? .imageToVideo : .textToVideo)
        for p in videoProviders where p.capabilities.contains(need) {
            if await p.status().available { return p }
        }
        var s = "Video generation isn't available: generating video is not practical on iPhone hardware, so NEXUS uses connected providers (OpenAI Sora or fal.ai models)."
        if settings.offlineOnly { s += " Offline-Only mode is on, so no video can be generated right now." }
        else if !settings.allowCloudGeneration { s += " Enable Cloud image & video generation in Settings → Privacy & network and add an API key in Studio → Providers." }
        else { s += " Add an OpenAI or fal.ai API key in Studio → Providers." }
        throw CreativeError.unavailable(s)
    }

    // MARK: Jobs

    private func update(_ id: UUID, _ change: (inout CreativeJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    func cancel(_ job: CreativeJob) {
        job.cancel.cancel()
        update(job.id) { $0.state = .cancelled }
    }

    func clearFinished() { jobs.removeAll { $0.state != .running } }

    private func makeProgressHandler(_ id: UUID) -> @Sendable (GenerationProgress) -> Void {
        { p in Task { @MainActor [weak self] in self?.update(id) { $0.progress = p.fraction; $0.message = p.message } } }
    }

    private func checkSafety(_ prompt: String, source: CGImage?) throws {
        let hasPeople = source.map { img -> Bool in
            let req = VNDetectHumanRectanglesRequestWrapper.count(img)
            return req > 0
        } ?? false
        let v = CreativeSafety.check(prompt: prompt, editingUploadedPhoto: source != nil, uploadedHasPeople: hasPeople)
        if !v.allowed { throw CreativeError.blocked(v.reason) }
    }

    /// Generates images and stores them in the library. Returns the new library items.
    @discardableResult
    func generateImages(_ request: ImageGenRequest, providerID: String? = nil, mode: IntelligenceMode = .thinking,
                        operation: String = "generate", parent: UUID? = nil) async throws -> [MediaItem] {
        try checkSafety(request.prompt, source: request.editSource ?? request.referenceImages.first)
        let provider: ImageGenerationProvider
        if let providerID, let p = imageProvider(providerID) {
            let st = await p.status()
            guard st.available else { throw CreativeError.unavailable("\(p.name): \(st.reason)") }
            provider = p
        } else {
            provider = try await autoImageProvider(for: request, mode: mode)
        }
        if provider.id == "local.sd21" && !models.isGenerating { models.unload() }   // free memory for diffusion
        var job = CreativeJob(kind: request.editSource == nil ? .image : .edit, prompt: request.prompt,
                              providerName: provider.name, isLocal: provider.isLocal)
        job.message = provider.isLocal ? "Preparing on-device generation…" : "Contacting \(provider.name)…"
        jobs.insert(job, at: 0)
        do {
            let media = try await provider.generate(request, progress: makeProgressHandler(job.id), cancel: job.cancel)
            var items: [MediaItem] = []
            for (i, m) in media.enumerated() {
                let item = MediaItem(kind: .image, name: Self.title(request.prompt) + (media.count > 1 ? " \(i + 1)" : ""),
                                     fileName: m.fileURL.lastPathComponent, prompt: request.prompt, negativePrompt: request.negativePrompt,
                                     modelName: provider.modelName, provider: provider.name, isLocal: provider.isLocal, operation: operation,
                                     settings: ["style": request.style.name, "aspect": request.aspect.rawValue, "quality": request.quality.rawValue,
                                                "count": "\(request.count)", "seed": m.seed.map { "\($0)" } ?? "-",
                                                "referenceStrength": request.referenceImages.isEmpty ? "-" : String(format: "%.2f", request.referenceStrength)],
                                     parentID: parent, width: m.width, height: m.height)
                items.append(library.add(item))
            }
            update(job.id) { $0.state = .succeeded; $0.progress = 1; $0.message = "Done"; $0.resultIDs = items.map(\.id) }
            return items
        } catch {
            let cancelled = (error as? NexusError).map { if case .cancelled = $0 { return true }; return false } ?? false
            update(job.id) { $0.state = cancelled ? .cancelled : .failed(error.localizedDescription) }
            throw error
        }
    }

    @discardableResult
    func generateVideo(_ request: VideoGenRequest, providerID: String? = nil, operation: String = "generate",
                       parent: UUID? = nil) async throws -> MediaItem {
        try checkSafety(request.prompt, source: request.referenceImage)
        let provider: VideoGenerationProvider
        if let providerID, let p = videoProvider(providerID) {
            let st = await p.status()
            guard st.available else { throw CreativeError.unavailable("\(p.name): \(st.reason)") }
            provider = p
        } else {
            provider = try await autoVideoProvider(for: request)
        }
        let job = CreativeJob(kind: .video, prompt: request.prompt, providerName: provider.name, isLocal: provider.isLocal)
        jobs.insert(job, at: 0)
        do {
            let media = try await provider.generate(request, progress: makeProgressHandler(job.id), cancel: job.cancel)
            let tagged = await Provenance.tagVideo(at: media.fileURL, model: provider.modelName, provider: provider.name, prompt: request.prompt)
            let item = library.add(MediaItem(kind: .video, name: Self.title(request.prompt), fileName: tagged.lastPathComponent,
                                             prompt: request.prompt, modelName: provider.modelName, provider: provider.name,
                                             isLocal: provider.isLocal, operation: operation,
                                             settings: ["duration": "\(request.durationSeconds)s", "aspect": request.aspect.rawValue,
                                                        "resolution": request.resolution, "camera": request.camera, "motion": request.motion,
                                                        "lighting": request.lighting, "mood": request.mood, "audio": request.audio ? "on" : "off",
                                                        "style": request.style.name],
                                             parentID: parent, remoteID: media.remoteID, width: media.width, height: media.height))
            update(job.id) { $0.state = .succeeded; $0.progress = 1; $0.message = "Done"; $0.resultIDs = [item.id] }
            return item
        } catch {
            update(job.id) { $0.state = .failed(error.localizedDescription) }
            throw error
        }
    }

    // MARK: Natural-language editing

    enum EditPlan: Equatable {
        case removeBackground, replaceBackground(String), enhance, warmer, upscale, variations(Int), generative
    }

    static func plan(for instruction: String) -> EditPlan {
        let t = instruction.lowercased()
        if t.contains("remove the background") || t.contains("remove background") || t.contains("transparent background") { return .removeBackground }
        if let r = t.range(of: #"(change|replace|swap) the background (to|with) "#, options: .regularExpression) {
            return .replaceBackground(String(instruction[r.upperBound...]).trimmed)
        }
        if t.contains("upscale") || t.contains("higher resolution") { return .upscale }
        if t.hasPrefix("enhance") || t.contains("auto enhance") || t.contains("auto-enhance") { return .enhance }
        if t.contains("warmer") && t.split(separator: " ").count <= 7 { return .warmer }
        let numbers = ["two": 2, "three": 3, "four": 4, "2": 2, "3": 3, "4": 4]
        if t.contains("version") || t.contains("variation") {
            for (k, v) in numbers where t.contains("\(k) ") { return .variations(v) }
        }
        return .generative
    }

    /// Edits an image with a natural-language instruction, preserving the source's original prompt as context.
    func editImage(_ item: MediaItem?, source: CGImage, instruction: String, mode: IntelligenceMode,
                   providerID: String? = nil) async throws -> [MediaItem] {
        let original = item?.prompt ?? ""
        switch Self.plan(for: instruction) {
        case .removeBackground:
            let out = try LocalMediaOps.removeBackground(source)
            return [try saveLocal(out, ext: "png", name: "Background removed", prompt: instruction, op: "background", parent: item, model: "Apple Vision subject lifting")]
        case .replaceBackground(let scene):
            if let p = providerID.flatMap(imageProvider), !p.isLocal {
                return try await generateImages(ImageGenRequest(prompt: "Replace the background with \(scene). Keep the subject unchanged.", operation: .edit, editSource: source),
                                                providerID: p.id, mode: mode, operation: "edit", parent: item?.id)
            }
            let subject = try LocalMediaOps.removeBackground(source)
            let bgItems = try await generateImages(ImageGenRequest(prompt: "\(scene), background scene, no people", aspect: source.width >= source.height ? .landscape : .portrait),
                                                   mode: mode, operation: "background-source", parent: item?.id)
            guard let bg = bgItems.first.flatMap({ UIImage(contentsOfFile: $0.url.path)?.cgImage }),
                  let composite = LocalMediaOps.composite(subject: subject, over: bg) else { throw CreativeError.noOutput }
            return [try saveLocal(composite, ext: "png", name: "New background", prompt: instruction, op: "background", parent: item,
                                  model: "Vision subject lift + \(bgItems.first?.modelName ?? "generator")", edited: true)]
        case .enhance:
            guard let out = LocalMediaOps.autoEnhance(source) else { throw CreativeError.noOutput }
            return [try saveLocal(out, ext: "jpg", name: "Enhanced", prompt: instruction, op: "enhance", parent: item, model: "Core Image auto-adjust (classic)")]
        case .warmer:
            guard let out = LocalMediaOps.warmer(source) else { throw CreativeError.noOutput }
            return [try saveLocal(out, ext: "jpg", name: "Warmer", prompt: instruction, op: "enhance", parent: item, model: "Core Image white balance (classic)")]
        case .upscale:
            guard let out = LocalMediaOps.upscale(source) else { throw CreativeError.noOutput }
            return [try saveLocal(out, ext: "png", name: "Upscaled 2×", prompt: instruction, op: "upscale", parent: item, model: "Lanczos resampling (not AI super-resolution)")]
        case .variations(let n):
            var req = ImageGenRequest(prompt: original.isEmpty ? instruction : original, count: n, referenceImages: [source], referenceStrength: 0.55)
            req.operation = .variation
            return try await generateImages(req, providerID: providerID, mode: mode, operation: "variation", parent: item?.id)
        case .generative:
            let prompt = original.isEmpty ? instruction : "\(original). Edit: \(instruction)"
            var req = ImageGenRequest(prompt: prompt, operation: .edit, editSource: source)
            req.referenceStrength = 0.5
            return try await generateImages(req, providerID: providerID, mode: mode, operation: "edit", parent: item?.id)
        }
    }

    private func saveLocal(_ image: CGImage, ext: String, name: String, prompt: String, op: String, parent: MediaItem?,
                           model: String, edited: Bool = false) throws -> MediaItem {
        let url = MediaFiles.newURL(ext: ext)
        try Provenance.write(image, to: url, model: model, provider: "On device", prompt: prompt, edited: edited || op != "background")
        return library.add(MediaItem(kind: .image, name: name, fileName: url.lastPathComponent, prompt: prompt, modelName: model,
                                     provider: "On device", isLocal: true, operation: op, parentID: parent?.id,
                                     width: image.width, height: image.height))
    }

    /// Video edits: vertical crop and extension are local/hybrid; other instructions use remix or re-generation that
    /// keeps the original prompt (creative intent) and applies the change.
    func editVideo(_ item: MediaItem, instruction: String) async throws -> MediaItem {
        let t = instruction.lowercased()
        if t.contains("vertical") || t.contains("9:16") || t.contains("portrait version") {
            let url = try await LocalMediaOps.verticalCrop(item.url)
            return library.add(MediaItem(kind: .video, name: item.name + " (vertical)", fileName: url.lastPathComponent, prompt: item.prompt,
                                         modelName: item.modelName, provider: "On device (crop)", isLocal: true, operation: "vertical",
                                         settings: ["aspect": "9:16"], parentID: item.id))
        }
        if t.contains("extend") || t.contains("continue") || t.contains("longer") {
            let last = try await LocalMediaOps.lastFrame(of: item.url)
            var req = VideoGenRequest(prompt: "Continue seamlessly from this frame: \(item.prompt). \(instruction)")
            req.referenceImage = last
            req.aspect = item.height > item.width ? .portrait : .landscape
            let ext = try await generateVideo(req, operation: "extension-clip", parent: item.id)
            let joined = try await LocalMediaOps.concatenate([item.url, ext.url])
            return library.add(MediaItem(kind: .video, name: item.name + " (extended)", fileName: joined.lastPathComponent,
                                         prompt: item.prompt + " — extended: " + instruction, modelName: ext.modelName,
                                         provider: ext.provider + " + local join", isLocal: false, operation: "extend", parentID: item.id))
        }
        var req = VideoGenRequest(prompt: item.prompt.isEmpty ? instruction : "\(item.prompt). Change: \(instruction)")
        req.aspect = item.height > item.width ? .portrait : .landscape
        if let remote = item.remoteID, item.provider.contains("OpenAI") {
            req.remixOf = remote
            req.prompt = instruction
        }
        return try await generateVideo(req, operation: req.remixOf != nil ? "remix" : "regenerate", parent: item.id)
    }

    // MARK: Prompt development

    /// Expands a short idea into a detailed generation prompt using the local language model.
    func refinePrompt(_ prompt: String, video: Bool, mode: IntelligenceMode = .thinking) async -> String {
        guard let orchestrator else { return prompt }
        let profile = TaskClassifier.classify("write a description")
        guard let decision = try? orchestrator.router.route(profile, mode: mode == .max ? .thinking : mode, override: nil),
              let backend = try? await orchestrator.backend(for: decision, session: nil) else { return prompt }
        let instruction = video
            ? "Rewrite this idea as one vivid paragraph for a text-to-video model: subject, action, setting, camera movement, lighting, mood, style. Keep the user's intent; no lists, no preamble."
            : "Rewrite this idea as one vivid prompt for an image generator: subject, composition, setting, lighting, style, details. Keep the user's intent; no preamble."
        let req = GenerationRequest(system: instruction, messages: [PromptMessage(role: .user, content: prompt)],
                                    maxTokens: 220, temperature: 0.7, enableThinking: false)
        let text = (try? await backend.complete(req).text)?.trimmed ?? ""
        return text.isEmpty ? prompt : text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
    }

    static func title(_ prompt: String) -> String {
        prompt.split(whereSeparator: { $0.isWhitespace }).prefix(6).joined(separator: " ").truncated(to: 40)
    }
}

/// Small helper so safety checks can tell whether an uploaded image contains people.
enum VNDetectHumanRectanglesRequestWrapper {
    static func count(_ image: CGImage) -> Int {
        let req = VNDetectHumanRectanglesRequest()
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req, faces])
        return (req.results?.count ?? 0) + (faces.results?.count ?? 0)
    }
}
