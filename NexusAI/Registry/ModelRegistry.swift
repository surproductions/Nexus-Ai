import Foundation

enum TaskCategory: String, Codable, CaseIterable, Sendable {
    case quick, chat, reasoning, math, coding, research, document, vision, planning, creative

    var label: String {
        switch self {
        case .quick: return "Quick"
        case .chat: return "Conversation"
        case .reasoning: return "Reasoning"
        case .math: return "Math"
        case .coding: return "Coding"
        case .research: return "Research"
        case .document: return "Documents"
        case .vision: return "Vision"
        case .planning: return "Planning"
        case .creative: return "Writing"
        }
    }
}

enum ModelCapability: String, Codable, CaseIterable, Sendable {
    case chat, reasoning, coding, math, vision, multilingual, longContext, toolUse, thinking

    var label: String {
        switch self {
        case .chat: return "Chat"
        case .reasoning: return "Reasoning"
        case .coding: return "Code"
        case .math: return "Math"
        case .vision: return "Vision"
        case .multilingual: return "Multilingual"
        case .longContext: return "Long context"
        case .toolUse: return "Tools"
        case .thinking: return "Thinking mode"
        }
    }
}

enum ModelKind: String, Codable, Sendable {
    case llm             // chat/instruction model (GGUF)
    case toolCaller      // function-calling specialist (GGUF), not used for chat
    case imageDiffusion  // Core ML Stable Diffusion resources (zip, unpacked after verification)

    var label: String {
        switch self {
        case .llm: return "Language model"
        case .toolCaller: return "Tool-calling model"
        case .imageDiffusion: return "Image generation"
        }
    }
}

struct ModelFile: Codable, Hashable, Sendable {
    var filename: String
    var url: URL
    var sizeBytes: Int64
    /// SHA-256 of the file, from the Hugging Face LFS pointer (verified after download).
    var sha256: String?
}

struct ModelEntry: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var family: String
    var version: String
    var publisher: String
    var sourceRepo: String
    var parameterBillions: Double
    var quantization: String
    var file: ModelFile
    var visionProjector: ModelFile?
    var nativeContext: Int
    /// Estimated KV-cache bytes per token at f16 (used for memory planning; deliberately conservative).
    var kvBytesPerToken: Int
    var promptFormat: PromptFormat
    var capabilities: [ModelCapability]
    /// Prior quality ratings (0–10) per task category. These are editorial priors derived from publisher-reported
    /// benchmarks and are superseded by your own on-device evaluation results once you run the eval suite.
    var priors: [String: Double]
    var license: String
    var licenseURL: URL
    var notes: String
    var isCustom: Bool = false
    /// nil = .llm (kept optional so entries saved by earlier versions still decode).
    var kind: ModelKind? = nil
    var modelKind: ModelKind { kind ?? .llm }
    var isChatModel: Bool { modelKind == .llm }

    var supportsThinking: Bool { capabilities.contains(.thinking) }
    var supportsVision: Bool { visionProjector != nil }
    var downloadBytes: Int64 { file.sizeBytes }

    func prior(_ c: TaskCategory) -> Double { priors[c.rawValue] ?? priors["chat"] ?? 4 }

    /// Estimated resident memory for a given context length.
    func estimatedMemory(context: Int, withVision: Bool) -> UInt64 {
        let weights = UInt64(file.sizeBytes)
        let kv = UInt64(kvBytesPerToken * context)
        let compute: UInt64 = 300 * 1_048_576 + UInt64(Double(weights) * 0.04)
        let vision = withVision ? UInt64(Double(visionProjector?.sizeBytes ?? 0) * 1.15) + 150 * 1_048_576 : 0
        return weights + kv + compute + vision
    }
}

enum ModelRegistry {
    private static func hf(_ repo: String, _ file: String, _ size: Int64, _ sha: String) -> ModelFile {
        ModelFile(filename: file,
                  url: URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)?download=true")!,
                  sizeBytes: size, sha256: sha)
    }

    private static let apache = URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!

    /// Curated catalog. Weights are never bundled or redistributed: they download directly from the
    /// publisher's (or a well-known quantizer's) Hugging Face repository under the model's own license.
    static let catalog: [ModelEntry] = [
        ModelEntry(
            id: "lfm2.5-1.2b-q4km", name: "LFM2.5 1.2B", family: "LFM2.5", version: "2.5", publisher: "Liquid AI",
            sourceRepo: "LiquidAI/LFM2.5-1.2B-Instruct-GGUF", parameterBillions: 1.2, quantization: "Q4_K_M",
            file: hf("LiquidAI/LFM2.5-1.2B-Instruct-GGUF", "LFM2.5-1.2B-Instruct-Q4_K_M.gguf", 730_895_168,
                     "b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5"),
            visionProjector: nil,
            nativeContext: 32_768, kvBytesPerToken: 12_288, promptFormat: .chatml,
            capabilities: [.chat, .multilingual, .toolUse],
            priors: ["quick": 6, "chat": 5, "reasoning": 4, "math": 4.5, "coding": 3.5, "research": 4.5, "document": 5, "vision": 0, "planning": 4, "creative": 5],
            license: "LFM Open License v1.0", licenseURL: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/blob/main/LICENSE")!,
            notes: "Hybrid convolution/attention edge model designed for very fast on-device decoding. Default Instant-mode model. License permits commercial use below a revenue threshold. Check the terms."),
        ModelEntry(
            id: "functiongemma-270m-q8", name: "FunctionGemma 270M", family: "FunctionGemma", version: "1", publisher: "Google DeepMind",
            sourceRepo: "unsloth/functiongemma-270m-it-GGUF", parameterBillions: 0.27, quantization: "Q8_0",
            file: hf("unsloth/functiongemma-270m-it-GGUF", "functiongemma-270m-it-Q8_0.gguf", 291_558_624,
                     "8a17a4eda2b28eaf685a487129fd5295eeff3f722b9c6451dd3d98c18c23a98d"),
            visionProjector: nil,
            nativeContext: 32_768, kvBytesPerToken: 18_432, promptFormat: .functionGemma,
            capabilities: [.toolUse],
            priors: ["chat": 0],
            license: "Gemma Terms of Use", licenseURL: URL(string: "https://ai.google.dev/gemma/terms")!,
            notes: "Tiny function-calling specialist. NEXUS uses it only to map requests to tools (calculator, units, dates, search, image/video generation), never for chat. It is a base model that is not fine-tuned for NEXUS's tools, so its calls are validated before execution.",
            kind: .toolCaller),
        ModelEntry(
            id: "sd-2.1-base-coreml", name: "Stable Diffusion 2.1 (Core ML)", family: "Stable Diffusion", version: "2.1-base", publisher: "Stability AI · Apple Core ML conversion",
            sourceRepo: "apple/coreml-stable-diffusion-2-1-base-palettized", parameterBillions: 0.87, quantization: "6-bit palettized",
            file: hf("apple/coreml-stable-diffusion-2-1-base-palettized", "coreml-stable-diffusion-2-1-base-palettized_split_einsum_v2_compiled.zip", 1_141_379_936,
                     "90c532943d460c559a8d84b7a0f05a4d265fee78ca355fdd5aa734fd43e08972"),
            visionProjector: nil,
            nativeContext: 77, kvBytesPerToken: 0, promptFormat: .auto,
            capabilities: [],
            priors: [:],
            license: "CreativeML Open RAIL++-M", licenseURL: URL(string: "https://huggingface.co/stabilityai/stable-diffusion-2-1-base/blob/main/LICENSE-MODEL")!,
            notes: "Local text-to-image and image-to-image at 512×512 on the Neural Engine (split-einsum). Apple's built-in safety checker blocks unsafe outputs when included. The license prohibits certain uses.",
            kind: .imageDiffusion),
        ModelEntry(
            id: "qwen3.5-0.8b-q4km", name: "Qwen3.5 0.8B", family: "Qwen3.5", version: "3.5", publisher: "Alibaba Qwen",
            sourceRepo: "unsloth/Qwen3.5-0.8B-GGUF", parameterBillions: 0.8, quantization: "Q4_K_M",
            file: hf("unsloth/Qwen3.5-0.8B-GGUF", "Qwen3.5-0.8B-Q4_K_M.gguf", 532_517_120,
                     "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517"),
            visionProjector: hf("unsloth/Qwen3.5-0.8B-GGUF", "mmproj-F16.gguf", 204_987_232,
                                "56e4c6cfe73b0c82e3e82bc518d7591997e61d81f723fc41a586f4fa69ea2453"),
            nativeContext: 262_144, kvBytesPerToken: 16_384, promptFormat: .qwen35,
            capabilities: [.chat, .multilingual, .vision, .thinking, .longContext],
            priors: ["quick": 4.5, "chat": 3.5, "reasoning": 2.5, "math": 3, "coding": 2.5, "research": 3, "document": 3.5, "vision": 3, "planning": 2.5, "creative": 3],
            license: "Apache-2.0", licenseURL: apache,
            notes: "Tiny hybrid (Gated DeltaNet + attention) model. Works on every supported iPhone; best for quick replies and as a fallback under memory pressure."),
        ModelEntry(
            id: "qwen3.5-2b-q4km", name: "Qwen3.5 2B", family: "Qwen3.5", version: "3.5", publisher: "Alibaba Qwen",
            sourceRepo: "unsloth/Qwen3.5-2B-GGUF", parameterBillions: 2, quantization: "Q4_K_M",
            file: hf("unsloth/Qwen3.5-2B-GGUF", "Qwen3.5-2B-Q4_K_M.gguf", 1_280_835_840,
                     "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223"),
            visionProjector: hf("unsloth/Qwen3.5-2B-GGUF", "mmproj-F16.gguf", 668_227_264,
                                "7035e9cb8d7c6a9681d07eef9a364783e86ea4cd73faab2eabb4f43a101830c7"),
            nativeContext: 262_144, kvBytesPerToken: 24_576, promptFormat: .qwen35,
            capabilities: [.chat, .reasoning, .multilingual, .vision, .thinking, .toolUse, .longContext],
            priors: ["quick": 5.5, "chat": 5, "reasoning": 4.5, "math": 5, "coding": 4, "research": 4.5, "document": 5, "vision": 4.5, "planning": 4, "creative": 4.5],
            license: "Apache-2.0", licenseURL: apache,
            notes: "Recommended Instant-mode model: fast, multimodal, thinking-capable."),
        ModelEntry(
            id: "qwen3.5-4b-q4km", name: "Qwen3.5 4B", family: "Qwen3.5", version: "3.5", publisher: "Alibaba Qwen",
            sourceRepo: "unsloth/Qwen3.5-4B-GGUF", parameterBillions: 4, quantization: "Q4_K_M",
            file: hf("unsloth/Qwen3.5-4B-GGUF", "Qwen3.5-4B-Q4_K_M.gguf", 2_740_937_888,
                     "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4"),
            visionProjector: hf("unsloth/Qwen3.5-4B-GGUF", "mmproj-F16.gguf", 672_423_616,
                                "cd88edcf8d031894960bb0c9c5b9b7e1fea6ebee02b9f7ce925a00d12891f864"),
            nativeContext: 262_144, kvBytesPerToken: 32_768, promptFormat: .qwen35,
            capabilities: [.chat, .reasoning, .coding, .math, .multilingual, .vision, .thinking, .toolUse, .longContext],
            priors: ["quick": 6.5, "chat": 7, "reasoning": 7, "math": 7.5, "coding": 6.5, "research": 6.5, "document": 7, "vision": 6.5, "planning": 6.5, "creative": 6.5],
            license: "Apache-2.0", licenseURL: apache,
            notes: "Recommended Thinking-mode model for 6–8 GB iPhones. Strong tool use and reasoning for its size."),
        ModelEntry(
            id: "qwen3.5-4b-q6k", name: "Qwen3.5 4B (high fidelity)", family: "Qwen3.5", version: "3.5", publisher: "Alibaba Qwen",
            sourceRepo: "unsloth/Qwen3.5-4B-GGUF", parameterBillions: 4, quantization: "Q6_K",
            file: hf("unsloth/Qwen3.5-4B-GGUF", "Qwen3.5-4B-Q6_K.gguf", 3_525_956_768,
                     "fdedd781c9ce676ab66b018ca247ff78e8a33c98098a822c1e2d5075e7718f66"),
            visionProjector: hf("unsloth/Qwen3.5-4B-GGUF", "mmproj-F16.gguf", 672_423_616,
                                "cd88edcf8d031894960bb0c9c5b9b7e1fea6ebee02b9f7ce925a00d12891f864"),
            nativeContext: 262_144, kvBytesPerToken: 32_768, promptFormat: .qwen35,
            capabilities: [.chat, .reasoning, .coding, .math, .multilingual, .vision, .thinking, .toolUse, .longContext],
            priors: ["quick": 6.5, "chat": 7.2, "reasoning": 7.3, "math": 7.8, "coding": 6.8, "research": 6.7, "document": 7.2, "vision": 6.7, "planning": 6.7, "creative": 6.7],
            license: "Apache-2.0", licenseURL: apache,
            notes: "6-bit quantization: closer to full precision than Q4_K_M at ~30% more memory and lower speed."),
        ModelEntry(
            id: "qwen3.5-9b-q3km", name: "Qwen3.5 9B (compact)", family: "Qwen3.5", version: "3.5", publisher: "Alibaba Qwen",
            sourceRepo: "unsloth/Qwen3.5-9B-GGUF", parameterBillions: 9, quantization: "Q3_K_M",
            file: hf("unsloth/Qwen3.5-9B-GGUF", "Qwen3.5-9B-Q3_K_M.gguf", 4_673_643_744,
                     "8fed90306e4f019e2bf35f3766470b7bc59ea1a9dae00f5ceb20b43cb5514393"),
            visionProjector: nil,
            nativeContext: 262_144, kvBytesPerToken: 49_152, promptFormat: .qwen35,
            capabilities: [.chat, .reasoning, .coding, .math, .multilingual, .thinking, .toolUse, .longContext],
            priors: ["quick": 7, "chat": 8, "reasoning": 8.2, "math": 8.3, "coding": 7.8, "research": 7.8, "document": 8, "vision": 0, "planning": 8, "creative": 7.8],
            license: "Apache-2.0", licenseURL: apache,
            notes: "Strongest local option for 8 GB iPhones when the app's memory limit allows it. 3-bit quantization costs some accuracy versus 4-bit."),
        ModelEntry(
            id: "qwen3.5-9b-iq4xs", name: "Qwen3.5 9B", family: "Qwen3.5", version: "3.5", publisher: "Alibaba Qwen",
            sourceRepo: "unsloth/Qwen3.5-9B-GGUF", parameterBillions: 9, quantization: "IQ4_XS",
            file: hf("unsloth/Qwen3.5-9B-GGUF", "Qwen3.5-9B-IQ4_XS.gguf", 5_168_653_536,
                     "7e918aeca06c52bcb528ea6b04b4ec957e75ee8c0a73138854c0dfcf371ea429"),
            visionProjector: hf("unsloth/Qwen3.5-9B-GGUF", "mmproj-F16.gguf", 918_166_080,
                                "f70dc3509053962b0d0d3ee8a7eacebf5d60aa560cad78254ae8698516ae029f"),
            nativeContext: 262_144, kvBytesPerToken: 49_152, promptFormat: .qwen35,
            capabilities: [.chat, .reasoning, .coding, .math, .multilingual, .vision, .thinking, .toolUse, .longContext],
            priors: ["quick": 7, "chat": 8.5, "reasoning": 8.7, "math": 8.8, "coding": 8.3, "research": 8.3, "document": 8.5, "vision": 8, "planning": 8.5, "creative": 8.3],
            license: "Apache-2.0", licenseURL: apache,
            notes: "Max-Intelligence model for 12 GB iPhones (iPhone 17 Pro class). Importance-matrix 4-bit quantization."),
        ModelEntry(
            id: "gemma-4-e2b-q4km", name: "Gemma 4 E2B", family: "Gemma 4", version: "4", publisher: "Google DeepMind",
            sourceRepo: "unsloth/gemma-4-E2B-it-GGUF", parameterBillions: 2, quantization: "Q4_K_M",
            file: hf("unsloth/gemma-4-E2B-it-GGUF", "gemma-4-E2B-it-Q4_K_M.gguf", 3_106_738_272,
                     "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8"),
            visionProjector: hf("unsloth/gemma-4-E2B-it-GGUF", "mmproj-F16.gguf", 985_654_080,
                                "140be8d7849741f88c50757d529b84373ee8e27052cc2236855b537f4a8215fa"),
            nativeContext: 131_072, kvBytesPerToken: 40_960, promptFormat: .gemma4,
            capabilities: [.chat, .reasoning, .multilingual, .vision, .thinking, .toolUse, .longContext],
            priors: ["quick": 5.5, "chat": 6.5, "reasoning": 5.5, "math": 5.5, "coding": 5, "research": 6, "document": 6, "vision": 6.5, "planning": 5.5, "creative": 6.5],
            license: "Apache-2.0", licenseURL: apache,
            notes: "Edge model with per-layer embeddings (2B effective compute, larger file). Natural writing style, good image understanding."),
        ModelEntry(
            id: "gemma-4-e4b-q4km", name: "Gemma 4 E4B", family: "Gemma 4", version: "4", publisher: "Google DeepMind",
            sourceRepo: "unsloth/gemma-4-E4B-it-GGUF", parameterBillions: 4, quantization: "Q4_K_M",
            file: hf("unsloth/gemma-4-E4B-it-GGUF", "gemma-4-E4B-it-Q4_K_M.gguf", 4_977_171_584,
                     "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87"),
            visionProjector: hf("unsloth/gemma-4-E4B-it-GGUF", "mmproj-F16.gguf", 990_372_672,
                                "ddf46c21d7078e95338cfc22306b19b276a29a5ad089023449dd54d4b6170a51"),
            nativeContext: 131_072, kvBytesPerToken: 49_152, promptFormat: .gemma4,
            capabilities: [.chat, .reasoning, .coding, .math, .multilingual, .vision, .thinking, .toolUse, .longContext],
            priors: ["quick": 6, "chat": 7.8, "reasoning": 7.3, "math": 7.3, "coding": 6.8, "research": 7.3, "document": 7.3, "vision": 7.8, "planning": 7, "creative": 7.8],
            license: "Apache-2.0", licenseURL: apache,
            notes: "Strong general and vision model for 8–12 GB iPhones."),
        ModelEntry(
            id: "phi-4-mini-q4km", name: "Phi-4 mini", family: "Phi-4", version: "4-mini", publisher: "Microsoft",
            sourceRepo: "unsloth/Phi-4-mini-instruct-GGUF", parameterBillions: 3.8, quantization: "Q4_K_M",
            file: hf("unsloth/Phi-4-mini-instruct-GGUF", "Phi-4-mini-instruct-Q4_K_M.gguf", 2_491_874_272,
                     "88c00229914083cd112853aab84ed51b87bdf6b9ce42f532d8c85c7c63b1730a"),
            visionProjector: nil,
            nativeContext: 131_072, kvBytesPerToken: 131_072, promptFormat: .phi4,
            capabilities: [.chat, .reasoning, .math, .coding, .longContext],
            priors: ["quick": 5.5, "chat": 6, "reasoning": 6.8, "math": 7, "coding": 6, "research": 5.5, "document": 6, "vision": 0, "planning": 6, "creative": 5.5],
            license: "MIT", licenseURL: URL(string: "https://huggingface.co/microsoft/Phi-4-mini-instruct/blob/main/LICENSE")!,
            notes: "Reasoning- and math-focused dense model. Full attention, so long contexts use more memory than Qwen3.5."),
        ModelEntry(
            id: "llama-3.2-3b-q4km", name: "Llama 3.2 3B", family: "Llama 3.2", version: "3.2", publisher: "Meta",
            sourceRepo: "bartowski/Llama-3.2-3B-Instruct-GGUF", parameterBillions: 3.2, quantization: "Q4_K_M",
            file: hf("bartowski/Llama-3.2-3B-Instruct-GGUF", "Llama-3.2-3B-Instruct-Q4_K_M.gguf", 2_019_377_696,
                     "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff"),
            visionProjector: nil,
            nativeContext: 131_072, kvBytesPerToken: 114_688, promptFormat: .llama3,
            capabilities: [.chat, .multilingual, .toolUse, .longContext],
            priors: ["quick": 5.5, "chat": 5.5, "reasoning": 4.5, "math": 4.5, "coding": 4.5, "research": 5, "document": 5.5, "vision": 0, "planning": 4.5, "creative": 5.5],
            license: "Llama 3.2 Community License",
            licenseURL: URL(string: "https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct/blob/main/LICENSE.txt")!,
            notes: "Widely used baseline with predictable behaviour. Subject to Meta's license and acceptable use policy (\"Built with Llama\")."),
        ModelEntry(
            id: "qwen2.5-coder-7b-q4km", name: "Qwen2.5 Coder 7B", family: "Qwen2.5-Coder", version: "2.5", publisher: "Alibaba Qwen",
            sourceRepo: "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF", parameterBillions: 7.6, quantization: "Q4_K_M",
            file: hf("Qwen/Qwen2.5-Coder-7B-Instruct-GGUF", "qwen2.5-coder-7b-instruct-q4_k_m.gguf", 4_683_073_536,
                     "509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c"),
            visionProjector: nil,
            nativeContext: 32_768, kvBytesPerToken: 57_344, promptFormat: .chatml,
            capabilities: [.coding, .chat, .reasoning],
            priors: ["quick": 4.5, "chat": 5.5, "reasoning": 6, "math": 6, "coding": 8, "research": 5, "document": 5.5, "vision": 0, "planning": 5.5, "creative": 4.5],
            license: "Apache-2.0", licenseURL: apache,
            notes: "Code specialist. Used by the Coding agent on devices with enough memory."),
    ]

    static func entry(_ id: String) -> ModelEntry? {
        catalog.first { $0.id == id } ?? CustomModels.all().first { $0.id == id }
    }

    static var allEntries: [ModelEntry] { catalog + CustomModels.all() }

    /// Priors for Apple's on-device model (used by the router; not a downloadable entry).
    static let applePriors: [TaskCategory: Double] = [
        .quick: 6, .chat: 5.5, .reasoning: 4.5, .math: 4, .coding: 4, .research: 4.5,
        .document: 5.5, .vision: 0, .planning: 4.5, .creative: 6,
    ]
}

/// User-imported GGUF files (via the Files app or document picker).
enum CustomModels {
    private static let key = "custom.models.v1"

    static func all() -> [ModelEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([ModelEntry].self, from: data) else { return [] }
        return list
    }

    static func add(fileURL: URL, sizeBytes: Int64) -> ModelEntry {
        let name = fileURL.deletingPathExtension().lastPathComponent
        let quant = ["Q2_K", "Q3_K_S", "Q3_K_M", "Q4_0", "Q4_K_S", "Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0", "IQ4_XS", "IQ4_NL", "F16", "BF16"]
            .first { name.uppercased().contains($0) } ?? "unknown"
        let params = estimateParams(name: name, size: sizeBytes)
        let entry = ModelEntry(
            id: "custom." + name.lowercased().replacingOccurrences(of: " ", with: "-"),
            name: name, family: "Custom", version: "-", publisher: "Imported by you", sourceRepo: "local file",
            parameterBillions: params, quantization: quant,
            file: ModelFile(filename: fileURL.lastPathComponent, url: fileURL, sizeBytes: sizeBytes, sha256: nil),
            visionProjector: nil, nativeContext: 8192, kvBytesPerToken: 131_072, promptFormat: .auto,
            capabilities: [.chat],
            priors: ["chat": min(8, 2 + params * 0.7)],
            license: "See model card", licenseURL: URL(string: "https://huggingface.co")!,
            notes: "Imported GGUF. Uses the chat template embedded in the file.", isCustom: true)
        var list = all().filter { $0.id != entry.id }
        list.append(entry)
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
        return entry
    }

    static func remove(_ id: String) {
        let list = all().filter { $0.id != id }
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func estimateParams(name: String, size: Int64) -> Double {
        let pattern = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*[bB]\\b")
        if let m = pattern?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let r = Range(m.range(at: 1), in: name), let v = Double(name[r]) {
            return v
        }
        return Double(size) / 1e9 / 0.6
    }
}
