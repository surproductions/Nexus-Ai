import Foundation

struct RouteDecision: Sendable {
    enum Target: Hashable, Sendable {
        case local(ModelEntry)
        case apple
        case cloud(CloudProviderConfig)
    }
    var target: Target
    var name: String
    var quality: Double
    var context: Int
    var reason: String
    var warnings: [String] = []
    var usesVisionModel: Bool = false

    var isOnDevice: Bool { if case .cloud = target { return false }; return true }
    var modelID: String {
        switch target {
        case .local(let e): return e.id
        case .apple: return AppleFoundationBackend.modelID
        case .cloud(let c): return "cloud:\(c.id.uuidString)"
        }
    }
}

/// Chooses the best backend for a request given the mode, task, installed models, hardware headroom,
/// network policy, measured evaluation results and any user override.
@MainActor
struct ModelRouter {
    let models: ModelManager
    let hardware: HardwareMonitor
    let settings: SettingsStore
    let measured: (String, TaskCategory) -> Double?

    struct Candidate {
        var target: RouteDecision.Target
        var name: String
        var quality: Double
        var speed: Double
        var loaded: Bool
        var context: Int
        var vision: Bool
        var measuredQuality: Bool
    }

    func candidates(for profile: TaskProfile, mode: IntelligenceMode) -> [Candidate] {
        var list: [Candidate] = []
        let preferredCtx = hardware.suggestedContext(for: mode)
        for entry in ModelRegistry.allEntries where entry.isChatModel && models.isInstalled(entry.id) {
            let visionReady = models.visionInstalled.contains(entry.id)
            let wantVision = profile.hasImages && visionReady
            let isLoaded = models.loadedEntry?.id == entry.id
            let reclaim = models.reclaimableMemory
            guard let ctx = hardware.fittingContext(for: entry, preferred: preferredCtx, vision: wantVision, reclaimable: reclaim) else { continue }
            let m = measured(entry.id, profile.category)
            var q = m ?? entry.prior(profile.category)
            if profile.category == .vision && !visionReady {
                q = max(0, entry.prior(.chat) - 3)   // can only reason over on-device OCR/classifier text
            }
            if ctx < 2048 { q -= 1 }
            let speed = max(1, 10 - entry.parameterBillions * 1.05) - (entry.quantization.hasPrefix("Q6") ? 0.5 : 0)
            list.append(Candidate(target: .local(entry), name: entry.name, quality: q, speed: speed, loaded: isLoaded,
                                  context: ctx, vision: wantVision, measuredQuality: m != nil))
        }
        if AppleIntelligence.isAvailable {
            let m = measured(AppleFoundationBackend.modelID, profile.category)
            var q = m ?? (ModelRegistry.applePriors[profile.category] ?? 5)
            if profile.category == .vision { q = 2.5 }
            list.append(Candidate(target: .apple, name: "Apple Intelligence", quality: q, speed: 8, loaded: true,
                                  context: 4096, vision: false, measuredQuality: m != nil))
        }
        if let provider = settings.activeProvider, NetworkGate.shared.isAllowed(.cloudInference),
           mode == .max && settings.cloudForMax {
            let m = measured("cloud:\(provider.id.uuidString)", profile.category)
            list.append(Candidate(target: .cloud(provider), name: provider.name, quality: m ?? 9.5, speed: 6, loaded: true,
                                  context: provider.contextLength, vision: provider.supportsVision, measuredQuality: m != nil))
        }
        return list
    }

    func score(_ c: Candidate, mode: IntelligenceMode) -> Double {
        let thermalPenalty = hardware.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? 1.0 : 0.0
        switch mode {
        case .instant:
            guard c.quality >= 3 else { return -1 }
            return 0.35 * c.quality + 0.65 * (c.speed + thermalPenalty) + (c.loaded ? 1.5 : 0)
        case .thinking:
            return 0.7 * c.quality + 0.3 * (c.speed + thermalPenalty * 0.5) + (c.loaded ? 0.8 : 0)
        case .max:
            return c.quality + 0.1 * c.speed + (c.loaded ? 0.2 : 0)
        }
    }

    func route(_ profile: TaskProfile, mode: IntelligenceMode, override: String?) throws -> RouteDecision {
        let all = candidates(for: profile, mode: mode)
        var warnings: [String] = []

        if let override, !override.isEmpty {
            if let c = all.first(where: { cand in
                decision(from: cand, reason: "").modelID == override || (override == "cloud" && Self.isCloud(cand.target))
            }) {
                return decision(from: c, reason: "Manually selected")
            }
            if override == "cloud", let p = settings.activeProvider {
                if NetworkGate.shared.isAllowed(.cloudInference) {
                    return RouteDecision(target: .cloud(p), name: p.name, quality: 9.5, context: p.contextLength,
                                         reason: "Manually selected (cloud)")
                }
                warnings.append("Your selected cloud model is unavailable (cloud inference is off or Offline-Only is on). Using the best local model instead.")
            } else if let e = ModelRegistry.entry(override) {
                warnings.append(models.isInstalled(e.id)
                    ? "\(e.name) does not fit in the memory currently available. Using the best model that fits."
                    : "\(e.name) is not installed. Using the best available model.")
            } else if override == AppleFoundationBackend.modelID {
                warnings.append("Apple Intelligence is unavailable: \(AppleIntelligence.status.reason).")
            }
        }

        guard !all.isEmpty else {
            if models.installed.isEmpty && !AppleIntelligence.isAvailable {
                throw NexusError.unavailable("No on-device model is available yet. Download a model from the Models tab (Qwen3.5 2B is a good start), or enable Apple Intelligence on supported devices.")
            }
            throw NexusError.unavailable("No installed model fits in the memory currently available. Close other apps or choose a smaller model.")
        }
        // Connected Max: hand substantially demanding Max tasks to the user's frontier provider.
        if mode == .max, settings.cloudForMax, let cloud = all.first(where: { Self.isCloud($0.target) }),
           profile.complexity >= 0.45 || [.research, .coding, .planning, .reasoning, .math].contains(profile.category) {
            var d = decision(from: cloud, reason: "Connected Max: demanding \(profile.category.label.lowercased()) task sent to \(cloud.name) (remote)")
            d.warnings = warnings
            return d
        }

        // Configured mode policy (per memory class): first preferred model that is installed and fits.
        let memClass = MemoryClass.detect(physicalMemory: hardware.device.physicalMemory)
        let policy = ModePolicyStore.load(memClass)
        for id in policy.preferred(for: mode) {
            guard let c = all.first(where: { decision(from: $0, reason: "").modelID == id }) else { continue }
            if profile.hasImages && !c.vision && all.contains(where: \.vision) { continue }  // keep image tasks on a vision model
            if mode == .instant && c.quality < 3 { continue }
            var d = decision(from: c, reason: "Preferred \(mode.title) model for \(memClass.rawValue) devices (\(policy.source) configuration)")
            d.warnings = warnings
            if profile.hasImages && !c.vision {
                d.warnings.append("No vision model is ready, so images are described with Apple's on-device OCR and classifier. Download a model's vision adapter in Models for full image understanding.")
            }
            if mode == .max, case .local(let e) = c.target, e.parameterBillions < 5 {
                d.warnings.append("Max Intelligence is running on a \(Calculator.format(e.parameterBillions))B on-device model. Answers are planned and verified, but they are not frontier-model quality. Connected Max (Settings) can use a cloud model for demanding tasks.")
            }
            return d
        }

        let ranked = all.map { ($0, score($0, mode: mode)) }.sorted { $0.1 > $1.1 }
        let best = ranked[0].0
        var reason: String
        switch mode {
        case .instant: reason = "Fastest capable model for a \(profile.category.label.lowercased()) request"
        case .thinking: reason = "Best quality/speed balance for \(profile.category.label.lowercased())"
        case .max: reason = "Highest-quality model available for \(profile.category.label.lowercased())"
        }
        reason += best.measuredQuality ? " (based on your on-device eval results)" : " (based on published benchmark priors)"
        if best.loaded, case .local = best.target { reason += "; already loaded" }
        var d = decision(from: best, reason: reason)
        d.warnings = warnings
        if profile.hasImages && !best.vision {
            d.warnings.append("No vision model is ready, so images are described with Apple's on-device OCR and classifier. Download a model's vision adapter in Models for full image understanding.")
        }
        if mode == .max, case .local(let e) = best.target, e.parameterBillions < 5 {
            d.warnings.append("Max Intelligence is running on a \(Calculator.format(e.parameterBillions))B on-device model. Answers are verified, but they are not frontier-model quality. A larger model or an opt-in cloud provider would be stronger.")
        }
        return d
    }

    /// Best specialist for an agent sub-task. Avoids swapping models unless the gain is material.
    func specialist(for category: TaskCategory, mode: IntelligenceMode, current: RouteDecision) -> RouteDecision {
        let profile = TaskProfile(category: category, complexity: 0.7, needsCurrentInfo: false, hasImages: false,
                                  hasDocuments: false, mathExpression: nil, wantsDateTime: false, unitConversion: false,
                                  wantsCode: category == .coding, codeLanguage: nil, isAmbiguous: false, signals: [])
        let all = candidates(for: profile, mode: mode)
        guard let best = all.max(by: { $0.quality < $1.quality }) else { return current }
        let currentQuality = all.first { decision(from: $0, reason: "").modelID == current.modelID }?.quality ?? current.quality
        if best.quality - currentQuality >= 1.0 {
            return decision(from: best, reason: "\(category.label) specialist (+\(String(format: "%.1f", best.quality - currentQuality)) quality)")
        }
        return current
    }

    static func isCloud(_ t: RouteDecision.Target) -> Bool {
        if case .cloud = t { return true }
        return false
    }

    private func decision(from c: Candidate, reason: String) -> RouteDecision {
        RouteDecision(target: c.target, name: c.name, quality: c.quality, context: c.context, reason: reason,
                      usesVisionModel: c.vision)
    }
}
