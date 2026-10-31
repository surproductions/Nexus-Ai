import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var settings: SettingsStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $settings.offlineOnly) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Offline-Only mode")
                                Text("Blocks every network request, including web, cloud and downloads").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "airplane") }
                    }
                    .tint(.orange)
                }
                Section("Intelligence") {
                    Picker("Default mode", selection: $settings.mode) {
                        ForEach(IntelligenceMode.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Show thought process", isOn: $settings.showThinking)
                    VStack(alignment: .leading) {
                        HStack { Text("Creativity"); Spacer(); Text(String(format: "%.1f", settings.temperature)).monospacedDigit().foregroundStyle(.secondary) }
                        Slider(value: $settings.temperature, in: 0...1.2, step: 0.1)
                    }
                    NavigationLink { PersonaView(settings: settings) } label: { Label("Custom instructions", systemImage: "text.quote") }
                    NavigationLink { ModelConfigView(models: app.models, settings: settings, evaluations: app.evaluations) } label: {
                        Label("Model configuration", systemImage: "slider.horizontal.below.square.and.square.filled")
                    }
                }
                Section("Privacy & data") {
                    NavigationLink { PrivacyView(settings: settings) } label: { Label("Privacy & network", systemImage: "hand.raised") }
                    NavigationLink { CloudProvidersView(settings: settings) } label: { Label("Cloud providers", systemImage: "cloud") }
                    NavigationLink { ConnectorsView(store: app.connectors, settings: settings) } label: { Label("Connectors", systemImage: "point.3.connected.trianglepath.dotted") }
                    NavigationLink { CreativeProvidersView(creative: app.creative, settings: settings) } label: { Label("Generation providers", systemImage: "paintpalette") }
                }
                Section("Voice") {
                    NavigationLink { VoiceSettingsView(settings: settings) } label: { Label("Voice & speech", systemImage: "waveform") }
                }
                Section("Performance") {
                    NavigationLink { PerformanceView(models: app.models) } label: { Label("Hardware & performance", systemImage: "gauge.with.dots.needle.67percent") }
                    NavigationLink { BenchmarksView(evaluations: app.evaluations, models: app.models) } label: { Label("Benchmarks & evaluation", systemImage: "chart.bar.xaxis") }
                }
                Section("Appearance") {
                    Picker("Theme", selection: $settings.appearance) {
                        Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                Section("About") {
                    NavigationLink { AboutView() } label: { Label("About NEXUS, licenses & limitations", systemImage: "info.circle") }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct PersonaView: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        Form {
            Section {
                TextEditor(text: $settings.persona).frame(minHeight: 180)
            } footer: {
                Text("Applied to every conversation, e.g. “Use British English. Prefer concise answers with examples.”")
            }
        }
        .navigationTitle("Custom instructions")
    }
}

struct PrivacyView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var settings: SettingsStore
    @State private var log: [NetworkGate.LogEntry] = NetworkGate.shared.log
    @State private var confirmWipe = false

    var body: some View {
        List {
            Section {
                Toggle("Offline-Only mode", isOn: $settings.offlineOnly).tint(.orange)
                Toggle("Web research", isOn: $settings.allowWebResearch).disabled(settings.offlineOnly)
                Toggle("Cloud inference", isOn: $settings.allowCloud).disabled(settings.offlineOnly)
                Toggle("Connected Max (cloud for demanding Max tasks)", isOn: $settings.cloudForMax).disabled(settings.offlineOnly || !settings.allowCloud)
                Toggle("Cloud image & video generation", isOn: $settings.allowCloudGeneration).disabled(settings.offlineOnly)
                Toggle("Connectors (Firecrawl, MCP…)", isOn: $settings.allowConnectors).disabled(settings.offlineOnly)
                Toggle("Allow cellular model downloads", isOn: $settings.allowCellularDownloads)
            } header: { Text("Network permissions") } footer: {
                Text("Everything is off by default except model downloads. Nothing is uploaded silently: cloud requests only happen when you enable them, and each message that used the cloud is marked with a cloud badge.")
            }
            Section("What uses the network") {
                ForEach(NetworkGate.Feature.allCases, id: \.self) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(f.rawValue).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(NetworkGate.shared.isAllowed(f) ? "Allowed" : "Blocked").font(.caption)
                                .foregroundStyle(NetworkGate.shared.isAllowed(f) ? .green : .secondary)
                        }
                        Text(f.explanation).font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Everything else runs on device").font(.subheadline.weight(.medium))
                    Text("Chat with local models, Apple Intelligence, memory, embeddings, document indexing, OCR, image analysis, speech recognition (when on-device is supported), speech synthesis, tools and benchmarks.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Require \(Biometrics.biometryName)", isOn: $settings.biometricLock)
            } header: { Text("Lock") } footer: {
                Text("Conversations, memories, projects, research reports and document text are additionally encrypted with AES-256-GCM using a key stored in this device's Keychain. No telemetry or analytics are collected.")
            }
            Section {
                if log.isEmpty { Text("No network requests recorded.").foregroundStyle(.secondary) }
                ForEach(log.prefix(100)) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(e.feature.rawValue).font(.caption.weight(.semibold))
                            Spacer()
                            Text(e.date, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text("\(e.host) · \(e.summary)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if e.bytesSent > 0 { Text("\(ByteCountFormatter.file(Int64(e.bytesSent))) sent").font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
                if !log.isEmpty { Button("Clear log", role: .destructive) { NetworkGate.shared.clearLog() } }
            } header: { Text("Network activity log (local only)") }
            Section {
                Picker("Keep uploaded photos & videos", selection: $settings.uploadRetentionDays) {
                    Text("Until I delete them").tag(0)
                    Text("30 days").tag(30)
                    Text("7 days").tag(7)
                    Text("1 day").tag(1)
                }
                Toggle("Transcribe video audio (on device)", isOn: $settings.transcribeVideoAudio)
                StatRow(label: "Uploaded media", value: ByteCountFormatter.file(MediaLibrary.uploadsUsage()))
                Button("Delete uploaded photos & videos now", role: .destructive) { MediaLibrary.clearUploads() }
            } header: { Text("Uploaded media") } footer: {
                Text("Photos and videos you attach are stored encrypted on this device for follow-up questions. Analysis text stays with the conversation. Generated media in the Studio library is managed separately.")
            }
            Section {
                Button("Delete all conversations, memories and documents", role: .destructive) { confirmWipe = true }
            }
        }
        .navigationTitle("Privacy & network")
        .onReceive(NotificationCenter.default.publisher(for: .nexusNetworkLogChanged)) { _ in log = NetworkGate.shared.log }
        .confirmationDialog("Delete all data?", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { app.wipeAllData() }
        } message: { Text("Downloaded models are kept. This cannot be undone.") }
    }
}

struct CloudProvidersView: View {
    @ObservedObject var settings: SettingsStore
    @State private var editing: CloudProviderConfig?

    var body: some View {
        List {
            Section {
                if settings.providers.isEmpty { Text("No providers configured.").foregroundStyle(.secondary) }
                ForEach(settings.providers) { p in
                    Button { editing = p } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).foregroundStyle(.primary)
                                Text("\(p.kind.rawValue) · \(p.model)").font(.caption).foregroundStyle(.secondary)
                                Text(p.apiKey?.isEmpty == false ? "API key stored in Keychain" : "No API key").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if settings.activeProvider?.id == p.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Keychain.delete(p.keychainKey)
                            settings.providers.removeAll { $0.id == p.id }
                        } label: { Label("Delete", systemImage: "trash") }
                        Button { settings.activeProviderID = p.id.uuidString } label: { Label("Use", systemImage: "checkmark") }.tint(.accentColor)
                    }
                }
            } footer: {
                Text("Providers are optional. API keys are stored only in the iOS Keychain on this device. Requests go directly from your iPhone to the provider you configure.")
            }
            Section("Add a provider") {
                ForEach(CloudProviderConfig.presets, id: \.name) { preset in
                    Button {
                        var p = preset
                        p.id = UUID()
                        editing = p
                    } label: { Label(preset.name, systemImage: "plus.circle") }
                }
            }
            Section {
                SecureKeyField(title: "Brave Search API key (optional)", key: "brave.key")
            } header: { Text("Web search") } footer: {
                Text("Without a key NEXUS uses DuckDuckGo's HTML results and Wikipedia. A Brave Search key gives more reliable results.")
            }
        }
        .navigationTitle("Cloud providers")
        .sheet(item: $editing) { p in ProviderEditor(settings: settings, provider: p) }
    }
}

struct SecureKeyField: View {
    let title: String
    let key: String
    @State private var value = ""
    @State private var saved = false

    var body: some View {
        HStack {
            SecureField(title, text: $value)
            Button(saved ? "Saved" : "Save") {
                Keychain.set(value, for: key)
                saved = true
            }
            .disabled(value.isEmpty)
        }
        .onAppear { saved = Keychain.get(key) != nil }
    }
}

struct ProviderEditor: View {
    @ObservedObject var settings: SettingsStore
    @State var provider: CloudProviderConfig
    @State private var apiKey = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    TextField("Name", text: $provider.name)
                    Picker("API type", selection: $provider.kind) {
                        ForEach(CloudProviderConfig.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Base URL", text: $provider.baseURL).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    TextField("Model", text: $provider.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Supports images", isOn: $provider.supportsVision)
                }
                Section {
                    SecureField(provider.apiKey == nil ? "API key" : "API key (stored — enter to replace)", text: $apiKey)
                } footer: {
                    Text("Stored in the Keychain, never in plain preferences or backups.")
                }
            }
            .navigationTitle(provider.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if !apiKey.isEmpty { Keychain.set(apiKey, for: provider.keychainKey) }
                        if let i = settings.providers.firstIndex(where: { $0.id == provider.id }) { settings.providers[i] = provider }
                        else { settings.providers.append(provider) }
                        if settings.activeProviderID.isEmpty { settings.activeProviderID = provider.id.uuidString }
                        dismiss()
                    }
                }
            }
        }
    }
}

struct VoiceSettingsView: View {
    @ObservedObject var settings: SettingsStore
    private let synth = AVSpeechSynthesizer()

    var body: some View {
        Form {
            Toggle("Speak responses in voice mode", isOn: $settings.speakResponses)
            Picker("Voice", selection: $settings.voiceIdentifier) {
                Text("Best available").tag("")
                ForEach(VoiceEngine.availableVoices(), id: \.identifier) { v in
                    Text("\(v.name)\(v.quality == .premium ? " (Premium)" : v.quality == .enhanced ? " (Enhanced)" : "")").tag(v.identifier)
                }
            }
            VStack(alignment: .leading) {
                Text("Speaking rate").font(.caption).foregroundStyle(.secondary)
                Slider(value: $settings.speechRate, in: 0.35...0.65)
            }
            Button("Preview voice") {
                let u = AVSpeechUtterance(string: "Hi, I'm NEXUS. Everything I say here is synthesized on your iPhone.")
                u.voice = AVSpeechSynthesisVoice(identifier: settings.voiceIdentifier) ?? VoiceEngine.bestVoice()
                u.rate = Float(settings.speechRate)
                synth.speak(u)
            }
            Section {
                Text("Speech recognition uses Apple's on-device recognizer when your language supports it. In Offline-Only mode, server recognition is never used. For more natural voices, download Enhanced or Premium voices in iOS Settings → Accessibility → Spoken Content → Voices.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Voice & speech")
    }
}
