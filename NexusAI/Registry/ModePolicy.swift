import Foundation

/// Device memory classes used to pick model defaults. Detected from physical RAM, never from the model name.
enum MemoryClass: String, Codable, CaseIterable, Sendable {
    case gb6 = "≤ 6 GB"
    case gb8 = "8 GB"
    case gb12 = "12 GB+"

    static func detect(physicalMemory: UInt64) -> MemoryClass {
        let gb = Double(physicalMemory) / 1_073_741_824
        if gb >= 11 { return .gb12 }
        if gb >= 7.5 { return .gb8 }
        return .gb6
    }

    var examples: String {
        switch self {
        case .gb6: return "iPhone 13–15 (non-Pro), iPhone 16e"
        case .gb8: return "iPhone 15 Pro, iPhone 16 series, iPhone 17"
        case .gb12: return "iPhone 17 Pro / Pro Max / Air, iPhone 18 Pro / Pro Max"
        }
    }
}

/// Which models each intelligence mode prefers, per memory class. Purely data: changing it never requires code
/// changes, and the router falls back to scored selection when no preferred model is installed or fits.
struct ModePolicy: Codable, Hashable, Sendable {
    var instant: [String]
    var thinking: [String]
    var max: [String]
    var toolCaller: String?
    var source: String = "default"   // "default", "custom", or "measured <date>"

    func preferred(for mode: IntelligenceMode) -> [String] {
        switch mode {
        case .instant: return instant
        case .thinking: return thinking
        case .max: return max
        }
    }

    mutating func set(_ ids: [String], for mode: IntelligenceMode) {
        switch mode {
        case .instant: instant = ids
        case .thinking: thinking = ids
        case .max: max = ids
        }
    }

    static let apple = AppleFoundationBackend.modelID

    /// Launch defaults (initial candidates). They're unverified until the user runs Auto-configure on their device.
    static func defaults(for c: MemoryClass) -> ModePolicy {
        switch c {
        case .gb12:
            return ModePolicy(instant: ["lfm2.5-1.2b-q4km", "qwen3.5-2b-q4km", apple],
                              thinking: ["gemma-4-e2b-q4km", "qwen3.5-4b-q4km", "qwen3.5-2b-q4km"],
                              max: ["qwen3.5-4b-q4km", "qwen3.5-9b-iq4xs", "gemma-4-e4b-q4km", "qwen3.5-4b-q6k", "gemma-4-e2b-q4km"],
                              toolCaller: "functiongemma-270m-q8")
        case .gb8:
            return ModePolicy(instant: ["lfm2.5-1.2b-q4km", "qwen3.5-2b-q4km", apple],
                              thinking: ["gemma-4-e2b-q4km", "qwen3.5-2b-q4km", "qwen3.5-4b-q4km"],
                              max: ["qwen3.5-4b-q4km", "gemma-4-e2b-q4km", "qwen3.5-2b-q4km"],
                              toolCaller: "functiongemma-270m-q8")
        case .gb6:
            return ModePolicy(instant: ["lfm2.5-1.2b-q4km", "qwen3.5-0.8b-q4km", apple],
                              thinking: ["qwen3.5-2b-q4km", "lfm2.5-1.2b-q4km"],
                              max: ["qwen3.5-4b-q4km", "qwen3.5-2b-q4km"],
                              toolCaller: "functiongemma-270m-q8")
        }
    }
}

/// Persists one policy per memory class.
enum ModePolicyStore {
    private static func key(_ c: MemoryClass) -> String { "modepolicy.\(c.rawValue)" }

    static func load(_ c: MemoryClass) -> ModePolicy {
        if let d = UserDefaults.standard.data(forKey: key(c)), let p = try? JSONDecoder().decode(ModePolicy.self, from: d) { return p }
        return .defaults(for: c)
    }

    static func save(_ p: ModePolicy, for c: MemoryClass) {
        if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: key(c)) }
        NotificationCenter.default.post(name: .nexusPolicyChanged, object: nil)
    }

    static func reset(_ c: MemoryClass) {
        UserDefaults.standard.removeObject(forKey: key(c))
        NotificationCenter.default.post(name: .nexusPolicyChanged, object: nil)
    }
}

extension Notification.Name {
    static let nexusPolicyChanged = Notification.Name("nexus.policy.changed")
}
