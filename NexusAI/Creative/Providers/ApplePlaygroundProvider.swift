import Foundation
import CoreGraphics
#if canImport(ImagePlayground)
import ImagePlayground
#endif

/// Apple Image Playground (`ImageCreator`, iOS 18.4+): on-device generation using Apple's built-in model.
/// No download; styles are limited to Animation, Illustration and Sketch on the iOS 26 SDK this app is built with.
struct ApplePlaygroundProvider: ImageGenerationProvider {
    let id = "apple.playground"
    let name = "Apple Image Playground"
    let modelName = "Apple Image Playground (on-device)"
    let isLocal = true
    let capabilities: Set<ImageCapability> = [.textToImage, .reference, .variations]
    let maxCount = 4
    let styleNote = "Animation, Illustration or Sketch styles only. Photorealistic output is not available on this SDK."

    static func playgroundStyleName(for preset: StylePreset) -> String {
        switch preset.id {
        case "illustration", "anime", "logo", "watercolor", "social", "wallpaper": return "illustration"
        case "sketch": return "sketch"
        default: return "animation"
        }
    }

    func status() async -> ProviderStatus {
        #if canImport(ImagePlayground)
        if #available(iOS 18.4, *) {
            do {
                let creator = try await ImageCreator()
                return creator.availableStyles.isEmpty
                    ? ProviderStatus(available: false, reason: "Image Playground has no styles available on this device.")
                    : ProviderStatus(available: true, reason: "Ready · on device")
            } catch {
                return ProviderStatus(available: false, reason: "Image Playground unavailable: \(error.localizedDescription). Requires Apple Intelligence.")
            }
        }
        return ProviderStatus(available: false, reason: "Requires iOS 18.4 or later with Apple Intelligence.")
        #else
        return ProviderStatus(available: false, reason: "Not supported by this build.")
        #endif
    }

    func generate(_ request: ImageGenRequest, progress: @escaping @Sendable (GenerationProgress) -> Void,
                  cancel: CancellationFlag) async throws -> [GeneratedMedia] {
        #if canImport(ImagePlayground)
        guard #available(iOS 18.4, *) else { throw CreativeError.unavailable("Image Playground requires iOS 18.4.") }
        let creator: ImageCreator
        do { creator = try await ImageCreator() } catch {
            throw CreativeError.unavailable("Image Playground is unavailable on this device: \(error.localizedDescription)")
        }
        let wanted = Self.playgroundStyleName(for: request.style)
        let style: ImagePlaygroundStyle = creator.availableStyles.first { "\($0)".lowercased().contains(wanted) }
            ?? creator.availableStyles.first ?? .animation
        var concepts: [ImagePlaygroundConcept] = [.text(request.prompt)]
        if let source = request.editSource ?? request.referenceImages.first { concepts.append(.image(source)) }
        progress(GenerationProgress(fraction: nil, message: "Generating on device with Image Playground…"))
        var out: [GeneratedMedia] = []
        let limit = max(1, min(request.count, maxCount))
        do {
            for try await created in creator.images(for: concepts, style: style, limit: limit) {
                if cancel.isCancelled { break }
                let url = MediaFiles.newURL(ext: "png")
                try Provenance.write(created.cgImage, to: url, model: modelName, provider: name, prompt: request.prompt,
                                     edited: request.editSource != nil)
                out.append(GeneratedMedia(fileURL: url, isVideo: false, remoteID: nil,
                                          width: created.cgImage.width, height: created.cgImage.height, seed: nil))
                progress(GenerationProgress(fraction: Double(out.count) / Double(limit), message: "Created \(out.count) of \(limit)"))
            }
        } catch {
            throw CreativeError.provider("Image Playground: \(error.localizedDescription)")
        }
        guard !out.isEmpty else { throw CreativeError.noOutput }
        return out
        #else
        throw CreativeError.unavailable("Image Playground is not supported by this build.")
        #endif
    }
}
