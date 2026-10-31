import SwiftUI

struct ModelConfigView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var models: ModelManager
    @ObservedObject var settings: SettingsStore
    @ObservedObject var evaluations: EvaluationStore
    @State private var memClass = MemoryClass.detect(physicalMemory: HardwareMonitor.shared.device.physicalMemory)
    @State private var policy = ModePolicyStore.load(MemoryClass.detect(physicalMemory: HardwareMonitor.shared.device.physicalMemory))
    @State private var tuning = false
    @State private var tuneResult: String?
    @State private var addingFor: IntelligenceMode?

    private let detected = MemoryClass.detect(physicalMemory: HardwareMonitor.shared.device.physicalMemory)

    var body: some View {
        List {
            Section {
                Picker("Memory class", selection: $memClass) {
                    ForEach(MemoryClass.allCases, id: \.self) { c in Text(c.rawValue + (c == detected ? " (this device)" : "")).tag(c) }
                }
                Text(memClass.examples).font(.caption).foregroundStyle(.secondary)
                StatRow(label: "Source", value: policy.source, mono: false)
            } footer: {
                Text("Each mode uses the first model in its list that is installed and fits in memory right now; otherwise NEXUS falls back to scored routing. Defaults are initial candidates, not measurements. Use Auto-configure to choose from real results on this device.")
            }
            ForEach(IntelligenceMode.allCases) { mode in
                Section {
                    ForEach(policy.preferred(for: mode), id: \.self) { id in
                        HStack {
                            Text(displayName(id))
                            Spacer()
                            if id == ModePolicy.apple {
                                Text(AppleIntelligence.isAvailable ? "Built in" : "Unavailable").font(.caption).foregroundStyle(AppleIntelligence.isAvailable ? Color.green : Color.secondary)
                            } else if models.isInstalled(id) {
                                Text("Installed").font(.caption).foregroundStyle(.green)
                            } else {
                                Text("Not downloaded").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { from, to in
                        var list = policy.preferred(for: mode)
                        list.move(fromOffsets: from, toOffset: to)
                        policy.set(list, for: mode); save()
                    }
                    .onDelete { idx in
                        var list = policy.preferred(for: mode)
                        list.remove(atOffsets: idx)
                        policy.set(list, for: mode); save()
                    }
                    Menu {
                        let current = Set(policy.preferred(for: mode))
                        if !current.contains(ModePolicy.apple) { Button("Apple Intelligence") { append(ModePolicy.apple, mode) } }
                        ForEach(ModelRegistry.allEntries.filter { $0.isChatModel && !current.contains($0.id) }) { e in
                            Button("\(e.name) \(e.quantization)\(models.isInstalled(e.id) ? "" : " (download needed)")") { append(e.id, mode) }
                        }
                    } label: { Label("Add model", systemImage: "plus") }
                } header: {
                    Label(mode.title, systemImage: mode.symbol)
                }
            }
            Section {
                Picker("Tool-calling model", selection: Binding(get: { policy.toolCaller ?? "" }, set: { policy.toolCaller = $0.isEmpty ? nil : $0; save() })) {
                    Text("None").tag("")
                    ForEach(ModelRegistry.catalog.filter { $0.modelKind == .toolCaller }) { Text($0.name).tag($0.id) }
                }
                Toggle("Use tool-calling model", isOn: $settings.useToolCaller)
            } footer: {
                Text("FunctionGemma maps requests to tools (calculator, units, dates, search, image/video generation). Its proposals are validated before anything runs.")
            }
            Section {
                Toggle("Connected Max", isOn: $settings.cloudForMax).disabled(settings.offlineOnly || !settings.allowCloud)
                if settings.activeProvider == nil { Text("Add a cloud provider in Settings → Cloud providers first.").font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("When on, Max Intelligence sends substantially demanding tasks (complex reasoning, coding, research, planning) to your configured frontier provider. Every such message is labelled Remote. Simpler Max requests stay local.")
            }
            Section {
                Button {
                    tuning = true
                    tuneResult = nil
                    Task {
                        tuneResult = await evaluations.autoConfigure(orchestrator: app.orchestrator, memoryClass: detected)
                        policy = ModePolicyStore.load(memClass)
                        tuning = false
                    }
                } label: { Label(tuning ? "Measuring installed models…" : "Auto-configure from on-device measurements", systemImage: "gauge.with.dots.needle.67percent") }
                .disabled(tuning || memClass != detected)
                if tuning, let p = evaluations.progress { Text("\(p.label) (\(p.done + 1)/\(p.total))").font(.caption).foregroundStyle(.secondary) }
                if let tuneResult { Text(tuneResult).font(.caption) }
                Button("Reset to defaults", role: .destructive) { ModePolicyStore.reset(memClass); policy = ModePolicyStore.load(memClass) }
            } footer: {
                Text("Auto-configure benchmarks every installed chat model on this iPhone (speed, memory) and runs a 10-case quality check, then assigns Instant to the fastest model that passes, Thinking to the best quality/speed balance and Max to the highest-scoring model. It takes several minutes and runs entirely on device.")
            }
        }
        .navigationTitle("Model configuration")
        .toolbar { EditButton() }
        .onChange(of: memClass) { c in policy = ModePolicyStore.load(c) }
    }

    private func displayName(_ id: String) -> String {
        id == ModePolicy.apple ? "Apple Intelligence" : (ModelRegistry.entry(id).map { "\($0.name) \($0.quantization)" } ?? id)
    }

    private func append(_ id: String, _ mode: IntelligenceMode) {
        var list = policy.preferred(for: mode)
        list.append(id)
        policy.set(list, for: mode)
        save()
    }

    private func save() {
        policy.source = "custom"
        ModePolicyStore.save(policy, for: memClass)
    }
}

struct ConnectorsView: View {
    @ObservedObject var store: ConnectorStore
    @ObservedObject var settings: SettingsStore
    @State private var editing: ConnectorConfig?
    @State private var testResults: [UUID: String] = [:]

    var body: some View {
        List {
            Section {
                Toggle("Allow connectors", isOn: $settings.allowConnectors).disabled(settings.offlineOnly)
            } footer: {
                Text("Connectors are optional external services. When allowed, NEXUS sends search queries or tool arguments to the connectors you add. Every request appears in the network log.")
            }
            Section("Your connectors") {
                if store.connectors.isEmpty { Text("No connectors yet.").foregroundStyle(.secondary) }
                ForEach(store.connectors) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(c.name).font(.body.weight(.medium))
                            Pill(text: c.kind.rawValue)
                            Spacer()
                            Toggle("", isOn: Binding(get: { c.enabled }, set: { v in var x = c; x.enabled = v; store.upsert(x) })).labelsHidden()
                        }
                        if c.kind == .mcp && !c.mcpTools.isEmpty {
                            Text("Tools: " + c.mcpTools.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                        if let r = testResults[c.id] { Text(r).font(.caption).foregroundStyle(r.hasPrefix("Connected") ? .green : .red) }
                        HStack {
                            Button("Test connection") { Task { testResults[c.id] = await store.test(c) } }.font(.caption)
                            Button("Edit") { editing = c }.font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                    .swipeActions { Button(role: .destructive) { store.remove(c) } label: { Label("Delete", systemImage: "trash") } }
                }
            }
            Section("Add a connector") {
                ForEach(ConnectorConfig.Kind.allCases, id: \.self) { kind in
                    Button {
                        editing = ConnectorConfig(kind: kind, name: kind.rawValue, baseURL: kind.defaultURL)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(kind.rawValue, systemImage: kind == .mcp ? "point.3.connected.trianglepath.dotted" : "magnifyingglass")
                            Text(kind.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Connectors")
        .sheet(item: $editing) { c in ConnectorEditor(store: store, connector: c) }
    }
}

struct ConnectorEditor: View {
    @ObservedObject var store: ConnectorStore
    @State var connector: ConnectorConfig
    @State private var key = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $connector.name)
                TextField(connector.kind == .mcp ? "Server URL (Streamable HTTP endpoint)" : "Base URL", text: $connector.baseURL)
                    .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                SecureField(connector.apiKey == nil ? (connector.kind.keyRequired ? "API key" : "Bearer token (optional)") : "Stored — enter to replace", text: $key)
                Text(connector.kind.summary).font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle(connector.kind.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if !key.isEmpty { Keychain.set(key, for: connector.keychainKey) }
                        store.upsert(connector)
                        dismiss()
                    }
                    .disabled(connector.baseURL.count < 10 || (connector.kind.keyRequired && key.isEmpty && connector.apiKey == nil))
                }
            }
        }
    }
}
