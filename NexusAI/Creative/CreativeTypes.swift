import Foundation
import CoreGraphics

enum AspectRatio: String, Codable, CaseIterable, Identifiable, Sendable {
    case square = "1:1", portrait = "9:16", landscape = "16:9", photoPortrait = "3:4", photoLandscape = "4:3", tall = "2:3", wide = "3:2"
    var id: String { rawValue }
    var ratio: Double {
        switch self {
        case .square: return 1
        case .portrait: return 9.0 / 16
        case .landscape: return 16.0 / 9
        case .photoPortrait: return 3.0 / 4
        case .photoLandscape: return 4.0 / 3
        case .tall: return 2.0 / 3
        case .wide: return 3.0 / 2
        }
    }
    var isPortrait: Bool { ratio < 1 }
}

enum GenerationQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case draft = "Draft", standard = "Standard", high = "High"
    var id: String { rawValue }
}

/// Style presets are prompt guidance, not restrictions: "Custom" leaves the prompt untouched.
struct StylePreset: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var suffix: String
    var negative: String = ""

    static let all: [StylePreset] = [
        StylePreset(id: "custom", name: "Custom", suffix: ""),
        StylePreset(id: "photo", name: "Photorealistic", suffix: "photorealistic, natural lighting, 35mm photograph, sharp focus, high detail", negative: "cartoon, illustration, painting, blurry, deformed"),
        StylePreset(id: "cinematic", name: "Cinematic", suffix: "cinematic still, dramatic lighting, anamorphic lens, film grain, color graded", negative: "flat lighting, cartoon"),
        StylePreset(id: "illustration", name: "Illustration", suffix: "detailed digital illustration, clean linework, vibrant colors", negative: "photo, blurry"),
        StylePreset(id: "anime", name: "Anime", suffix: "anime style, cel shading, expressive, studio quality", negative: "photo, 3d render"),
        StylePreset(id: "3d", name: "3D Render", suffix: "3D render, octane, soft global illumination, studio lighting", negative: "flat, sketch"),
        StylePreset(id: "watercolor", name: "Watercolor", suffix: "watercolor painting, soft washes, textured paper", negative: "photo, harsh edges"),
        StylePreset(id: "concept", name: "Concept Art", suffix: "concept art, matte painting, epic scale, atmospheric perspective", negative: "photo"),
        StylePreset(id: "product", name: "Product Shot", suffix: "professional product photography, seamless studio background, softbox lighting, commercial", negative: "clutter, people"),
        StylePreset(id: "architecture", name: "Architecture", suffix: "architectural visualization, interior design photography, wide angle, natural light", negative: "distorted lines"),
        StylePreset(id: "logo", name: "Logo", suffix: "minimal vector logo, flat design, simple shapes, centered, plain background", negative: "photo, gradient noise, text artifacts"),
        StylePreset(id: "wallpaper", name: "Wallpaper", suffix: "high-resolution wallpaper, aesthetic, balanced composition", negative: "text, watermark"),
        StylePreset(id: "social", name: "Social Post", suffix: "eye-catching social media visual, bold composition, vibrant", negative: "clutter"),
        StylePreset(id: "character", name: "Character Concept", suffix: "character concept sheet, full body, consistent design, neutral background", negative: "cropped, deformed"),
    ]

    static func named(_ id: String) -> StylePreset { all.first { $0.id == id } ?? all[0] }

    func apply(to prompt: String) -> String { suffix.isEmpty ? prompt : "\(prompt), \(suffix)" }
}

struct ImageGenRequest: Sendable {
    enum Operation: String, Sendable { case generate, edit, variation }
    var prompt: String
    var negativePrompt: String = ""
    var style: StylePreset = StylePreset.all[0]
    var aspect: AspectRatio = .square
    var count: Int = 1
    var quality: GenerationQuality = .standard
    var referenceImages: [CGImage] = []
    /// 0 = follow the reference closely, 1 = ignore it (img2img strength semantics).
    var referenceStrength: Double = 0.6
    var operation: Operation = .generate
    var editSource: CGImage?
    var mask: CGImage?
    var transparentBackground = false
    var seed: UInt32?
}

struct VideoGenRequest: Sendable {
    var prompt: String
    var durationSeconds: Int = 8
    var aspect: AspectRatio = .landscape
    var resolution: String = "720p"
    var fps: Int?
    var style: StylePreset = StylePreset.all[0]
    var camera: String = ""
    var motion: String = ""
    var lighting: String = ""
    var mood: String = ""
    var audio = false
    var referenceImage: CGImage?
    /// Provider-side id of a previous video to remix (edit while preserving the original).
    var remixOf: String?

    /// Combines structured controls into one prompt (providers receive natural language).
    var composedPrompt: String {
        var parts = [style.apply(to: prompt)]
        if !camera.isEmpty { parts.append("Camera: \(camera)") }
        if !motion.isEmpty { parts.append("Motion: \(motion)") }
        if !lighting.isEmpty { parts.append("Lighting: \(lighting)") }
        if !mood.isEmpty { parts.append("Mood: \(mood)") }
        return parts.joined(separator: ". ")
    }
}

enum ImageCapability: String, CaseIterable, Sendable {
    case textToImage = "Text to image"
    case reference = "Reference image"
    case instructionEdit = "Natural-language editing"
    case maskedEdit = "Masked edit / object removal"
    case variations = "Variations"
    case transparentBackground = "Transparent background"
    case photorealism = "Photorealism"
    case customStyle = "Custom styles"
}

enum VideoCapability: String, CaseIterable, Sendable {
    case textToVideo = "Text to video"
    case imageToVideo = "Image to video"
    case remix = "Edit / remix"
    case audio = "Audio"
}

struct GenerationProgress: Sendable {
    var fraction: Double?        // nil = indeterminate (provider doesn't report progress)
    var message: String
}

struct GeneratedMedia: Sendable {
    var fileURL: URL
    var isVideo: Bool
    var remoteID: String?
    var width: Int
    var height: Int
    var seed: UInt32?
}

struct ProviderStatus: Sendable {
    var available: Bool
    var reason: String
}

protocol ImageGenerationProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var modelName: String { get }
    var isLocal: Bool { get }
    var capabilities: Set<ImageCapability> { get }
    var maxCount: Int { get }
    var styleNote: String { get }
    func status() async -> ProviderStatus
    func generate(_ request: ImageGenRequest, progress: @escaping @Sendable (GenerationProgress) -> Void,
                  cancel: CancellationFlag) async throws -> [GeneratedMedia]
}

protocol VideoGenerationProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var modelName: String { get }
    var isLocal: Bool { get }
    var capabilities: Set<VideoCapability> { get }
    var durations: [Int] { get }
    var aspects: [AspectRatio] { get }
    func status() async -> ProviderStatus
    func generate(_ request: VideoGenRequest, progress: @escaping @Sendable (GenerationProgress) -> Void,
                  cancel: CancellationFlag) async throws -> GeneratedMedia
}

enum CreativeError: LocalizedError {
    case unavailable(String)
    case blocked(String)
    case unsupported(String)
    case provider(String)
    case noOutput

    var errorDescription: String? {
        switch self {
        case .unavailable(let s), .unsupported(let s), .provider(let s): return s
        case .blocked(let s): return "Request blocked: \(s)"
        case .noOutput: return "The provider returned no media."
        }
    }
}

enum MediaFiles {
    static var directory: URL {
        let d = Paths.appSupport.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func newURL(ext: String) -> URL { directory.appendingPathComponent("\(UUID().uuidString).\(ext)") }
}
