import Foundation
import CoreGraphics
import CoreML
import StableDiffusion

/// Local Stable Diffusion 2.1 (Apple Core ML conversion, split-einsum for the Neural Engine).
/// 512×512 output; image-to-image when the VAE encoder is included in the resources.
final class StableDiffusionProvider: ImageGenerationProvider, @unchecked Sendable {
    let id = "local.sd21"
    let name = "Stable Diffusion (on device)"
    let modelName = "Stable Diffusion 2.1 base · Core ML 6-bit"
    let isLocal = true
    let maxCount = 4
    let styleNote = "512×512 square output. Aspect ratio controls are applied by center-cropping."
    let resourcesURL: URL

    private let lock = NSLock()
    private var pipeline: StableDiffusionPipeline?

    init(resourcesURL: URL) { self.resourcesURL = resourcesURL }

    var hasEncoder: Bool { FileManager.default.fileExists(atPath: resourcesURL.appendingPathComponent("VAEEncoder.mlmodelc").path) }
    var hasSafetyChecker: Bool { FileManager.default.fileExists(atPath: resourcesURL.appendingPathComponent("SafetyChecker.mlmodelc").path) }

    var capabilities: Set<ImageCapability> {
        var c: Set<ImageCapability> = [.textToImage, .variations, .customStyle, .photorealism]
        if hasEncoder { c.insert(.reference); c.insert(.instructionEdit) }
        return c
    }

    func status() async -> ProviderStatus {
        FileManager.default.fileExists(atPath: resourcesURL.appendingPathComponent("TextEncoder.mlmodelc").path)
            ? ProviderStatus(available: true, reason: "Ready · on device" + (hasEncoder ? "" : " (text-to-image only)"))
            : ProviderStatus(available: false, reason: "Download “Stable Diffusion 2.1 (Core ML)” in the Models tab (1.1 GB).")
    }

    func unload() {
        lock.lock(); defer { lock.unlock() }
        pipeline?.unloadResources()
        pipeline = nil
    }

    private func loadedPipeline() throws -> StableDiffusionPipeline {
        lock.lock(); defer { lock.unlock() }
        if let pipeline { return pipeline }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let p = try StableDiffusionPipeline(resourcesAt: resourcesURL, controlNet: [], configuration: config,
                                            disableSafety: false, reduceMemory: true)
        try p.loadResources()
        pipeline = p
        return p
    }

    func generate(_ request: ImageGenRequest, progress: @escaping @Sendable (GenerationProgress) -> Void,
                  cancel: CancellationFlag) async throws -> [GeneratedMedia] {
        let steps = request.quality == .draft ? 15 : (request.quality == .standard ? 25 : 40)
        let count = max(1, min(request.count, maxCount))
        let start = request.editSource ?? request.referenceImages.first
        if start != nil && !hasEncoder {
            throw CreativeError.unsupported("These Stable Diffusion resources don't include the image encoder, so reference/edit generation isn't available locally.")
        }
        let prompt = request.style.apply(to: request.prompt)
        let negative = [request.negativePrompt, request.style.negative].filter { !$0.isEmpty }.joined(separator: ", ")
        let aspect = request.aspect
        let baseSeed = request.seed ?? UInt32.random(in: 1...UInt32.max - 10)
        let strength = Float(min(0.95, max(0.2, request.referenceStrength)))
        progress(GenerationProgress(fraction: 0, message: "Loading Stable Diffusion on the Neural Engine…"))

        return try await Task.detached(priority: .userInitiated) { [self] () -> [GeneratedMedia] in
            let pipe = try self.loadedPipeline()
            var cfg = StableDiffusionPipeline.Configuration(prompt: prompt)
            cfg.negativePrompt = negative
            cfg.imageCount = count
            cfg.stepCount = steps
            cfg.seed = baseSeed
            cfg.guidanceScale = 7.5
            cfg.schedulerType = .dpmSolverMultistepScheduler
            cfg.disableSafety = false
            if let start, let square = LocalMediaOps.squareResize(start, side: 512) {
                cfg.startingImage = square
                cfg.strength = strength
            }
            let images = try pipe.generateImages(configuration: cfg) { p in
                progress(GenerationProgress(fraction: Double(p.step) / Double(max(1, p.stepCount)),
                                            message: "Denoising step \(p.step) of \(p.stepCount)"))
                return !cancel.isCancelled
            }
            if cancel.isCancelled { throw NexusError.cancelled }
            var out: [GeneratedMedia] = []
            var blocked = 0
            for (i, img) in images.enumerated() {
                guard let img else { blocked += 1; continue }   // nil = rejected by the safety checker
                let final = aspect == .square ? img : (LocalMediaOps.centerCrop(img, aspect: aspect.ratio) ?? img)
                let url = MediaFiles.newURL(ext: "png")
                try Provenance.write(final, to: url, model: self.modelName, provider: self.name, prompt: prompt, edited: start != nil)
                out.append(GeneratedMedia(fileURL: url, isVideo: false, remoteID: nil, width: final.width, height: final.height,
                                          seed: baseSeed &+ UInt32(i)))
            }
            if out.isEmpty && blocked > 0 { throw CreativeError.blocked("The on-device safety checker rejected the output.") }
            guard !out.isEmpty else { throw CreativeError.noOutput }
            return out
        }.value
    }
}
