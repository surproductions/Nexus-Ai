import Foundation
import CoreGraphics
import UIKit

/// Minimal multipart/form-data builder.
struct Multipart {
    let boundary = "nexus-\(UUID().uuidString)"
    private(set) var body = Data()

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func file(_ name: String, filename: String, mime: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finalized() -> Data { body + Data("--\(boundary)--\r\n".utf8) }
    var contentType: String { "multipart/form-data; boundary=\(boundary)" }
}

enum CreativeKeys {
    static let openAI = "creative.openai.key"
    static let fal = "creative.fal.key"
}

private func openAIRequest(_ path: String, method: String = "POST") throws -> URLRequest {
    guard let key = Keychain.get(CreativeKeys.openAI), !key.isEmpty else {
        throw CreativeError.unavailable("Add an OpenAI API key in Studio → Providers to use OpenAI generation.")
    }
    var r = URLRequest(url: URL(string: "https://api.openai.com/v1\(path)")!)
    r.httpMethod = method
    r.timeoutInterval = 300
    r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    return r
}

private func openAIError(_ data: Data, _ status: Int) -> CreativeError {
    if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let e = j["error"] as? [String: Any], let m = e["message"] as? String {
        return .provider("OpenAI (\(status)): \(m)")
    }
    return .provider("OpenAI returned HTTP \(status).")
}

/// OpenAI image generation and natural-language editing (gpt-image family). Remote: prompts and any images you
/// attach are uploaded to OpenAI for that request.
struct OpenAIImageProvider: ImageGenerationProvider {
    var model = "gpt-image-1"
    let id = "openai.image"
    let name = "OpenAI Images"
    var modelName: String { model }
    let isLocal = false
    let capabilities: Set<ImageCapability> = [.textToImage, .reference, .instructionEdit, .maskedEdit, .variations,
                                              .transparentBackground, .photorealism, .customStyle]
    let maxCount = 4
    let styleNote = "Square, 3:2 landscape or 2:3 portrait sizes. Output includes OpenAI's C2PA content credentials."

    func status() async -> ProviderStatus {
        if Keychain.get(CreativeKeys.openAI)?.isEmpty ?? true { return ProviderStatus(available: false, reason: "No OpenAI API key configured.") }
        if !NetworkGate.shared.isAllowed(.cloudGeneration) { return ProviderStatus(available: false, reason: "Cloud generation is turned off (Settings → Privacy & network).") }
        return ProviderStatus(available: true, reason: "Ready · remote (OpenAI)")
    }

    static func size(for a: AspectRatio) -> String {
        if a == .square { return "1024x1024" }
        return a.isPortrait ? "1024x1536" : "1536x1024"
    }

    func generate(_ request: ImageGenRequest, progress: @escaping @Sendable (GenerationProgress) -> Void,
                  cancel: CancellationFlag) async throws -> [GeneratedMedia] {
        let quality = request.quality == .draft ? "low" : (request.quality == .standard ? "medium" : "high")
        let prompt = request.style.apply(to: request.prompt) + (request.negativePrompt.isEmpty ? "" : ". Avoid: \(request.negativePrompt)")
        let n = max(1, min(request.count, maxCount))
        let sources = ([request.editSource].compactMap { $0 }) + request.referenceImages
        var r: URLRequest
        if sources.isEmpty {
            r = try openAIRequest("/images/generations")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["model": model, "prompt": prompt, "n": n, "size": Self.size(for: request.aspect), "quality": quality]
            if request.transparentBackground { body["background"] = "transparent" }
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else {
            r = try openAIRequest("/images/edits")
            var m = Multipart()
            m.field("model", model)
            m.field("prompt", prompt)
            m.field("n", "\(n)")
            m.field("size", Self.size(for: request.aspect))
            m.field("quality", quality)
            if request.transparentBackground { m.field("background", "transparent") }
            for (i, img) in sources.prefix(8).enumerated() {
                guard let png = UIImage(cgImage: img).pngData() else { continue }
                m.file("image[]", filename: "image\(i).png", mime: "image/png", data: png)
            }
            if let mask = request.mask, let png = UIImage(cgImage: mask).pngData() {
                m.file("mask", filename: "mask.png", mime: "image/png", data: png)
            }
            r.setValue(m.contentType, forHTTPHeaderField: "Content-Type")
            r.httpBody = m.finalized()
        }
        progress(GenerationProgress(fraction: nil, message: "Sending request to OpenAI…"))
        let (data, http) = try await NetworkGate.shared.data(for: r, feature: .cloudGeneration,
                                                             summary: "OpenAI image \(sources.isEmpty ? "generation" : "edit with \(sources.count) image(s)"): \(request.prompt)")
        guard (200..<300).contains(http.statusCode) else { throw openAIError(data, http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { throw CreativeError.noOutput }
        var out: [GeneratedMedia] = []
        for item in items {
            guard let b64 = item["b64_json"] as? String, let bytes = Data(base64Encoded: b64) else { continue }
            let url = try Provenance.save(data: bytes, ext: "png", model: model, provider: name, prompt: request.prompt, edited: !sources.isEmpty)
            let img = UIImage(data: bytes)
            out.append(GeneratedMedia(fileURL: url, isVideo: false, remoteID: nil,
                                      width: Int(img?.size.width ?? 0), height: Int(img?.size.height ?? 0), seed: nil))
        }
        guard !out.isEmpty else { throw CreativeError.noOutput }
        return out
    }
}

/// OpenAI video generation (Sora 2): text-to-video, image-to-video (first-frame reference) and remix.
struct OpenAIVideoProvider: VideoGenerationProvider {
    var model = "sora-2"
    let id = "openai.video"
    let name = "OpenAI Video"
    var modelName: String { model }
    let isLocal = false
    let capabilities: Set<VideoCapability> = [.textToVideo, .imageToVideo, .remix, .audio]
    let durations = [4, 8, 12]
    let aspects: [AspectRatio] = [.landscape, .portrait]

    func status() async -> ProviderStatus {
        if Keychain.get(CreativeKeys.openAI)?.isEmpty ?? true { return ProviderStatus(available: false, reason: "No OpenAI API key configured.") }
        if !NetworkGate.shared.isAllowed(.cloudGeneration) { return ProviderStatus(available: false, reason: "Cloud generation is turned off.") }
        return ProviderStatus(available: true, reason: "Ready · remote (OpenAI)")
    }

    static func size(_ a: AspectRatio) -> (String, Int, Int) {
        a.isPortrait ? ("720x1280", 720, 1280) : ("1280x720", 1280, 720)
    }

    func generate(_ request: VideoGenRequest, progress: @escaping @Sendable (GenerationProgress) -> Void,
                  cancel: CancellationFlag) async throws -> GeneratedMedia {
        let seconds = durations.min(by: { abs($0 - request.durationSeconds) < abs($1 - request.durationSeconds) }) ?? 8
        let (size, w, h) = Self.size(request.aspect)
        var r: URLRequest
        if let remix = request.remixOf {
            r = try openAIRequest("/videos/\(remix)/remix")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": request.composedPrompt])
        } else {
            r = try openAIRequest("/videos")
            var m = Multipart()
            m.field("model", model)
            m.field("prompt", request.composedPrompt)
            m.field("seconds", "\(seconds)")
            m.field("size", size)
            if let ref = request.referenceImage, let fitted = LocalMediaOps.aspectFill(ref, width: w, height: h),
               let jpeg = UIImage(cgImage: fitted).jpegData(compressionQuality: 0.9) {
                m.file("input_reference", filename: "reference.jpg", mime: "image/jpeg", data: jpeg)
            }
            r.setValue(m.contentType, forHTTPHeaderField: "Content-Type")
            r.httpBody = m.finalized()
        }
        progress(GenerationProgress(fraction: nil, message: request.remixOf == nil ? "Submitting to OpenAI…" : "Submitting remix to OpenAI…"))
        let (data, http) = try await NetworkGate.shared.data(for: r, feature: .cloudGeneration,
                                                             summary: "OpenAI video \(request.remixOf == nil ? "" : "remix "): \(request.prompt)")
        guard (200..<300).contains(http.statusCode) else { throw openAIError(data, http.statusCode) }
        guard let job = try JSONSerialization.jsonObject(with: data) as? [String: Any], let videoID = job["id"] as? String else {
            throw CreativeError.provider("OpenAI did not return a video id.")
        }

        // Poll until finished (real progress reported by the API).
        var status = job["status"] as? String ?? "queued"
        var polls = 0
        while status != "completed" {
            if cancel.isCancelled { throw NexusError.cancelled }
            if status == "failed" {
                throw CreativeError.provider("OpenAI video generation failed\(((job["error"] as? [String: Any])?["message"] as? String).map { ": \($0)" } ?? ".")")
            }
            try await Task.sleep(nanoseconds: 4_000_000_000)
            polls += 1
            guard polls < 300 else { throw CreativeError.provider("Timed out waiting for OpenAI video.") }
            let pr = try openAIRequest("/videos/\(videoID)", method: "GET")
            let (pd, ph) = try await NetworkGate.shared.data(for: pr, feature: .cloudGeneration, summary: "OpenAI video status \(videoID)")
            guard (200..<300).contains(ph.statusCode), let j = try JSONSerialization.jsonObject(with: pd) as? [String: Any] else {
                throw openAIError(pd, ph.statusCode)
            }
            status = j["status"] as? String ?? status
            let pct = (j["progress"] as? NSNumber)?.doubleValue
            progress(GenerationProgress(fraction: pct.map { $0 / 100 }, message: "OpenAI: \(status.replacingOccurrences(of: "_", with: " "))"))
            if status == "failed" {
                throw CreativeError.provider("OpenAI video generation failed: \(((j["error"] as? [String: Any])?["message"] as? String) ?? "unknown error")")
            }
        }
        progress(GenerationProgress(fraction: 1, message: "Downloading video…"))
        let dr = try openAIRequest("/videos/\(videoID)/content", method: "GET")
        let (bytes, dh) = try await NetworkGate.shared.data(for: dr, feature: .cloudGeneration, summary: "Download OpenAI video \(videoID)")
        guard (200..<300).contains(dh.statusCode), !bytes.isEmpty else { throw openAIError(bytes, dh.statusCode) }
        let url = MediaFiles.newURL(ext: "mp4")
        try bytes.write(to: url)
        return GeneratedMedia(fileURL: url, isVideo: true, remoteID: videoID, width: w, height: h, seed: nil)
    }
}
