import Foundation
import SwiftUI

/// User preferences (non-secret). API keys live in the Keychain, never here.
@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var mode: IntelligenceMode { didSet { save("mode", mode.rawValue) } }
    @Published var offlineOnly: Bool { didSet { save("offlineOnly", offlineOnly); syncPolicy() } }
    @Published var allowWebResearch: Bool { didSet { save("allowWeb", allowWebResearch); syncPolicy() } }
    @Published var allowCloud: Bool { didSet { save("allowCloud", allowCloud); syncPolicy() } }
    @Published var cloudForMax: Bool { didSet { save("cloudForMax", cloudForMax) } }
    @Published var activeProviderID: String { didSet { save("activeProvider", activeProviderID) } }
    @Published var modelOverride: String { didSet { save("modelOverride", modelOverride) } }   // "" = automatic
    @Published var allowCellularDownloads: Bool { didSet { save("cellular", allowCellularDownloads) } }
    @Published var showThinking: Bool { didSet { save("showThinking", showThinking) } }
    @Published var suggestMemories: Bool { didSet { save("suggestMemories", suggestMemories) } }
    @Published var useMemory: Bool { didSet { save("useMemory", useMemory) } }
    @Published var biometricLock: Bool { didSet { save("biometricLock", biometricLock) } }
    @Published var speakResponses: Bool { didSet { save("speak", speakResponses) } }
    @Published var voiceIdentifier: String { didSet { save("voice", voiceIdentifier) } }
    @Published var speechRate: Double { didSet { save("speechRate", speechRate) } }
    @Published var temperature: Double { didSet { save("temperature", temperature) } }
    @Published var persona: String { didSet { save("persona", persona) } }
    @Published var searchProvider: String { didSet { save("searchProvider", searchProvider) } } // duckduckgo | brave
    @Published var hasOnboarded: Bool { didSet { save("onboarded", hasOnboarded) } }
    @Published var appearance: String { didSet { save("appearance", appearance) } } // system | light | dark
    @Published var providers: [CloudProviderConfig] { didSet { saveProviders() } }

    init() {
        let d = UserDefaults.standard
        mode = IntelligenceMode(rawValue: d.string(forKey: "mode") ?? "") ?? .thinking
        offlineOnly = d.object(forKey: "offlineOnly") as? Bool ?? false
        allowWebResearch = d.object(forKey: "allowWeb") as? Bool ?? false
        allowCloud = d.object(forKey: "allowCloud") as? Bool ?? false
        cloudForMax = d.object(forKey: "cloudForMax") as? Bool ?? false
        activeProviderID = d.string(forKey: "activeProvider") ?? ""
        modelOverride = d.string(forKey: "modelOverride") ?? ""
        allowCellularDownloads = d.object(forKey: "cellular") as? Bool ?? false
        showThinking = d.object(forKey: "showThinking") as? Bool ?? true
        suggestMemories = d.object(forKey: "suggestMemories") as? Bool ?? true
        useMemory = d.object(forKey: "useMemory") as? Bool ?? true
        biometricLock = d.object(forKey: "biometricLock") as? Bool ?? false
        speakResponses = d.object(forKey: "speak") as? Bool ?? true
        voiceIdentifier = d.string(forKey: "voice") ?? ""
        speechRate = d.object(forKey: "speechRate") as? Double ?? 0.5
        temperature = d.object(forKey: "temperature") as? Double ?? 0.7
        persona = d.string(forKey: "persona") ?? ""
        searchProvider = d.string(forKey: "searchProvider") ?? "duckduckgo"
        hasOnboarded = d.object(forKey: "onboarded") as? Bool ?? false
        appearance = d.string(forKey: "appearance") ?? "system"
        if let data = d.data(forKey: "providers"), let list = try? JSONDecoder().decode([CloudProviderConfig].self, from: data) {
            providers = list
        } else {
            providers = []
        }
        syncPolicy()
    }

    var activeProvider: CloudProviderConfig? {
        providers.first { $0.id.uuidString == activeProviderID } ?? providers.first
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }

    private func saveProviders() {
        if let data = try? JSONEncoder().encode(providers) { defaults.set(data, forKey: "providers") }
    }

    private func syncPolicy() {
        NetworkGate.shared.policy = .init(offlineOnly: offlineOnly, allowWebResearch: allowWebResearch, allowCloud: allowCloud)
    }
}
