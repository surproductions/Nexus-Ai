import Foundation
import CoreGraphics
import UIKit

/// A fal.ai model endpoint. Endpoints are data, so new models can be added in Settings without code changes.
struct FalEndpoint: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case image = "Text to image", imageEdit = "Image edit", textToVideo = "Text to video", imageToVideo = "Image to video"
    }
    enum SizeParam: String, Codable, Sendable { case imageSize, aspectRatio }
    var id: String            // e.g. "fal-ai/flux/dev"
    var name: String
    var kind: Kind
    var sizeParam: SizeParam = .aspectRatio
    var durations: [Int] = []
    var durationSuffix = ""   // "s" for endpoints expecting "8s"
    var supportsAudio = false
    var aspects: [AspectRatio] = [.landscape, .portrait, .square]

    static let presets: [FalEndpoint] = [
        FalEndpoint(id: "fal-ai/flux/dev", name: "FLUX.1 [dev]", kind: .image, sizeParam: .imageSize),
        FalEndpoint(id: "fal-ai/flux-pro/v1.1-ultra", name: "FLUX1.1 [pro] ultra", kind: .image, sizeParam: .aspectRatio),
        FalEndpoint(id: "fal-ai/flux-pro/kontext", name: "FLUX.1 Kontext [pro] (editing)", kind: .imageEdit, sizeParam: .aspectRatio),
        FalEndpoint(id: "fal-ai/veo3", name: "Google Veo 3", kind: .textToVideo, durations: [8], durationSuffix: "s",
                    supportsAudio: true, aspects: [.landscape, .portrait]),
        FalEndpoint(id: "fal-ai/kling-video/v2.1/master/text-to-video", name: "Kling 2.1 Master (text)", kind: .textToVideo,
                    durations: [5, 10], aspects: [.landscape, .portrait, .square]),
        FalEndpoint(id: "fal-ai/kling-video/v2.1/master/image-to-video", name: "Kling 2.1 Master (image)", kind: .imageToVideo,
                    durations: [5, 10], aspects: [.landscape, .portrait, .square]),
    ]
}

enum FalClient {
    static func imageSizeName(_ a: AspectRatio) -> String {
        switch a {
        case .square: return "square_hd"
        case .portrait: return "portrait_16_9"
        case .landscape: return "landscape_16_9"
        case .photoPortrait, .tall: return "portrait_4_3"
        case .photoLandscape, .wide: return "landscape_4_3"
        }
    }

    static func dataURI(_ image: CGImage) -> String? {
        let ui = UIImage(cgImage: image)
        let scale = min(1, 1536 / max(ui.size.width, ui.size.height))
        let size = CGSize(width: ui.size.width * scale, height: ui.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in ui.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.9).map { "data:image/jpeg;base64,\($0.base64EncodedString())" }
    }

    private static func request(_ url: URL, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard let key = Keychain.get(CreativeKeys.fal), !key.isEmpty else {
            throw CreativeError.unavailable("Add a fal.ai API key in Studio → Providers to use fal models.")
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 120
        r.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    /// Submits to the fal queue, polls status and returns the result JSON.
    static func run(endpoint: String, input: [String: Any], summary: String,
                    progress: @escaping @Sendable (GenerationProgress) -> Void, cancel: CancellationFlag) async throws -> [String: Any] {
        guard let submitURL = URL(string: "https://queue.fal.run/\(endpoint)") else { throw CreativeError.provider("Invalid fal endpoint") }
        let (data, http) = try await NetworkGate.shared.data(for: try request(submitURL, method: "POST", body: input),
                                                             feature: .cloudGeneration, summary: "fal.ai \(endpoint): \(summary)")
        guard (200..<300).contains(http.statusCode), let job = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CreativeError.provider("fal.ai returned HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.truncated(to: 300) ?? "")")
        }
        guard let statusURL = (job["status_url"] as? String).flatMap(URL.init(string:)),
              let responseURL = (job["response_url"] as? String).flatMap(URL.init(string:)) else {
            throw CreativeError.provider("fal.ai did not return queue URLs.")
        }
        var polls = 0
        while true {
            if cancel.isCancelled { throw NexusError.cancelled }
            try await Task.sleep(nanoseconds: 3_000_000_000)
            polls += 1
            guard polls < 400 else { throw CreativeError.provider("Timed out waiting for fal.ai.") }
            let (sd, sh) = try await NetworkGate.shared.data(for: try request(statusURL), feature: .cloudGeneration, summary: "fal.ai status")
            guard (200..<300).contains(sh.statusCode), let s = try JSONSerialization.jsonObject(with: sd) as? [String: Any] else { continue }
            let status = s["status"] as? String ?? ""
            if status == "COMPLETED" { break }
            if status == "FAILED" || status == "ERROR" { throw CreativeError.provider("fal.ai job failed.") }
            let pos = (s["queue_position"] as? NSNumber).map { " (position \($0))" } ?? ""
            progress(GenerationProgress(fraction: nil, message: status == "IN_QUEUE" ? "Queued at fal.ai\(pos)" : "Generating at fal.ai…"))
        }
        let (rd, rh) = try await NetworkGate.shared.data(for: try request(responseURL), feature: .cloudGeneration, summary: "fal.ai result")
        guard (200..<300).contains(rh.statusCode), let result = try JSONSerialization.jsonObject(with: rd) as? [String: Any] else {
            throw CreativeError.provider("fal.ai result error (HTTP \(rh.statusCode)): \(String(data: rd, encoding: .utf8)?.truncated(to: 300) ?? "")")
        }
        if let detail = result["detail"] { throw CreativeError.provider("fal.ai: \(detail)") }
        return result
    }

    static func download(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw CreativeError.noOutput }
        if urlString.hasPrefix("data:"), let comma = urlString.firstIndex(of: ",") {
            return Data(base64Encoded: String(urlString[urlString.index(after: comma)...])) ?? Data()
        }
        let (d, h) = try await NetworkGate.shared.data(for: URLRequest(url: url), feature: .cloudGeneration, summary: "Download fal.ai output")
        guard (200..<300).contains(h.statusCode) else { throw CreativeError.provider("Download failed (HTTP \(h.statusCode))") }
        return d
    }
}

struct FalImageProvider: ImageGenerationProvider {
    let endpoint: FalEndpoint
    var id: String { "fal.\(endpoint.id)" }
    var name: String { "fal.ai · \(endpoint.name)" }
    var modelName: String { endpoint.id }
    let isLocal = false
    var capabilities: Set<ImageCapability> {
        endpoint.kind == .imageEdit ? [.instructionEdit, .reference, .photorealism, .customStyle]
                                    : [.textToImage, .variations, .photorealism, .customStyle]
    }
    var maxCount: Int { 4 }
    let styleNote = "Runs on fal.ai servers. Prompts and attached images are uploaded for that request."

    func status() async -> ProviderStatus {
        if Keychain.get(CreativeKeys.fal)?.isEmpty ?? true { return ProviderStatus(available: false, reason: "No fal.ai API key configured.") }
        if !NetworkGate.shared.isAllowed(.cloudGeneration) { return ProviderStatus(available: false, reason: "Cloud generation is turned off.") }
        return ProviderStatus(available: true, reason: "Ready · remote (fal.ai)")
    }

    func generate(_ request: ImageGenRequest, progress: @escaping @Sendable (GenerationProgress) -> Void,
                  cancel: CancellationFlag) async throws -> [GeneratedMedia] {
        var input: [String: Any] = ["prompt": request.style.apply(to: request.prompt), "num_images": max(1, min(request.count, maxCount))]
        switch endpoint.sizeParam {
        case .imageSize: input["image_size"] = FalClient.imageSizeName(request.aspect)
        case .aspectRatio: input["aspect_ratio"] = request.aspect.rawValue
        }
        if let seed = request.seed { input["seed"] = seed }
        if endpoint.kind == .imageEdit {
            guard let src = request.editSource ?? request.referenceImages.first, let uri = FalClient.dataURI(src) else {
                throw CreativeError.unsupported("\(endpoint.name) needs a source image to edit.")
            }
            input["image_url"] = uri
        }
        let result = try await FalClient.run(endpoint: endpoint.id, input: input, summary: request.prompt, progress: progress, cancel: cancel)
        var urls: [String] = []
        if let images = result["images"] as? [[String: Any]] { urls = images.compactMap { $0["url"] as? String } }
        if let image = result["image"] as? [String: Any], let u = image["url"] as? String { urls.append(u) }
        var out: [GeneratedMedia] = []
        for u in urls {
            let bytes = try await FalClient.download(u)
            let ext = u.lowercased().contains(".png") ? "png" : "jpg"
            let url = try Provenance.save(data: bytes, ext: ext, model: endpoint.id, provider: "fal.ai", prompt: request.prompt,
                                          edited: endpoint.kind == .imageEdit)
            let img = UIImage(data: bytes)
            out.append(GeneratedMedia(fileURL: url, isVideo: false, remoteID: nil, width: Int(img?.size.width ?? 0),
                                      height: Int(img?.size.height ?? 0), seed: nil))
        }
        guard !out.isEmpty else { throw CreativeError.noOutput }
        return out
    }
}

struct FalVideoProvider: VideoGenerationProvider {
    let endpoint: FalEndpoint
    var id: String { "fal.\(endpoint.id)" }
    var name: String { "fal.ai · \(endpoint.name)" }
    var modelName: String { endpoint.id }
    let isLocal = false
    var capabilities: Set<VideoCapability> {
        var c: Set<VideoCapability> = [endpoint.kind == .imageToVideo ? .imageToVideo : .textToVideo]
        if endpoint.supportsAudio { c.insert(.audio) }
        return c
    }
    var durations: [Int] { endpoint.durations.isEmpty ? [5] : endpoint.durations }
    var aspects: [AspectRatio] { endpoint.aspects }

    func status() async -> ProviderStatus {
        if Keychain.get(CreativeKeys.fal)?.isEmpty ?? true { return ProviderStatus(available: false, reason: "No fal.ai API key configured.") }
        if !NetworkGate.shared.isAllowed(.cloudGeneration) { return ProviderStatus(available: false, reason: "Cloud generation is turned off.") }
        return ProviderStatus(available: true, reason: "Ready · remote (fal.ai)")
    }

    func generate(_ request: VideoGenRequest, progress: @escaping @Sendable (GenerationProgress) -> Void,
                  cancel: CancellationFlag) async throws -> GeneratedMedia {
        let d = durations.min(by: { abs($0 - request.durationSeconds) < abs($1 - request.durationSeconds) }) ?? durations[0]
        var input: [String: Any] = ["prompt": request.composedPrompt, "duration": "\(d)\(endpoint.durationSuffix)",
                                    "aspect_ratio": request.aspect.rawValue]
        if endpoint.supportsAudio { input["generate_audio"] = request.audio }
        if endpoint.kind == .imageToVideo {
            guard let ref = request.referenceImage, let uri = FalClient.dataURI(ref) else {
                throw CreativeError.unsupported("\(endpoint.name) needs a reference image.")
            }
            input["image_url"] = uri
        }
        let result = try await FalClient.run(endpoint: endpoint.id, input: input, summary: request.prompt, progress: progress, cancel: cancel)
        guard let video = result["video"] as? [String: Any], let u = video["url"] as? String else { throw CreativeError.noOutput }
        progress(GenerationProgress(fraction: 1, message: "Downloading video…"))
        let bytes = try await FalClient.download(u)
        let url = MediaFiles.newURL(ext: "mp4")
        try bytes.write(to: url)
        let (w, h) = request.aspect.isPortrait ? (720, 1280) : (request.aspect == .square ? (960, 960) : (1280, 720))
        return GeneratedMedia(fileURL: url, isVideo: true, remoteID: nil, width: w, height: h, seed: nil)
    }
}
