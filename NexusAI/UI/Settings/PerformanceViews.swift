import SwiftUI

struct PerformanceView: View {
    @ObservedObject var models: ModelManager
    @ObservedObject private var hw = HardwareMonitor.shared

    var body: some View {
        List {
            Section("Device") {
                StatRow(label: "Model", value: hw.device.marketingName, mono: false)
                StatRow(label: "Identifier", value: hw.device.identifier)
                StatRow(label: "Chip", value: hw.device.chip, mono: false)
                StatRow(label: "CPU cores", value: "\(hw.device.cpuCores) (\(hw.device.performanceCores) performance)")
                StatRow(label: "GPU", value: hw.device.gpuName, mono: false)
                StatRow(label: "GPU family", value: hw.device.gpuFamily, mono: false)
                StatRow(label: "iOS", value: hw.device.osVersion)
                StatRow(label: "Profile", value: hw.tier.rawValue, mono: false)
                Text(hw.tier.detail).font(.caption).foregroundStyle(.secondary)
            }
            Section("Memory (live)") {
                StatRow(label: "Physical RAM", value: ByteCountFormatter.memory(Int64(hw.device.physicalMemory)))
                StatRow(label: "App footprint", value: ByteCountFormatter.memory(Int64(hw.appFootprint)))
                StatRow(label: "Still available to app", value: hw.availableMemory > 0 ? ByteCountFormatter.memory(Int64(hw.availableMemory)) : "Not reported (estimated \(ByteCountFormatter.memory(Int64(hw.usableMemory))))")
                MeterBar(value: hw.memoryBudget > 0 ? Double(hw.appFootprint) / Double(hw.memoryBudget) : 0,
                         tint: Double(hw.appFootprint) / Double(max(1, hw.memoryBudget)) > 0.8 ? .red : .accentColor)
                StatRow(label: "Memory warnings", value: "\(hw.memoryWarnings)")
            }
            Section {
                Toggle("Allow models that may not fit", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "allowOversizedModels") },
                    set: { UserDefaults.standard.set($0, forKey: "allowOversizedModels"); hw.refresh() }))
            } header: { Text("Memory safety") } footer: {
                Text("NEXUS normally refuses to load a model whose estimated memory exceeds what iOS lets this app use, because iOS would close the app. Turn this on to try anyway; if iOS closes NEXUS, turn it off or pick a smaller model or shorter context. Sideloaded builds signed without the Increased Memory Limit entitlement get a lower limit.")
            }
            Section("Thermal & power") {
                StatRow(label: "Thermal state", value: hw.thermalLabel, mono: false)
                StatRow(label: "Battery", value: hw.batteryLevel >= 0 ? "\(Int(hw.batteryLevel * 100))%" : "Unknown")
                StatRow(label: "Low Power Mode", value: hw.lowPowerMode ? "On" : "Off", mono: false)
                StatRow(label: "Free storage", value: ByteCountFormatter.file(hw.freeStorage))
            }
            Section("Runtime") {
                switch models.loadState {
                case .idle: Text("No local model loaded")
                case .loading(let id, let p):
                    VStack(alignment: .leading) { Text("Loading \(ModelRegistry.entry(id)?.name ?? id)"); ProgressView(value: p) }
                case .ready:
                    if let e = models.loadedEntry {
                        StatRow(label: "Loaded model", value: "\(e.name) \(e.quantization)", mono: false)
                        StatRow(label: "Context window", value: "\(models.loadedContext) tokens")
                        StatRow(label: "Load time", value: "\(models.lastLoadMs) ms")
                        StatRow(label: "Vision", value: models.loadedBackend?.descriptor.supportsVision == true ? "Enabled" : "Off", mono: false)
                        Button("Unload model") { models.unload() }
                    }
                case .failed(let e): Text(e).foregroundStyle(.orange)
                }
                StatRow(label: "Engine", value: "llama.cpp (Metal) + Apple Foundation Models", mono: false)
                StatRow(label: "Embeddings", value: Embedder.shared.method, mono: false)
            }
            Section {
                Text("Adaptive behaviour: the router lowers model size and context under Serious/Critical thermal state or Low Power Mode; models are unloaded on iOS memory warnings (never mid-generation); every load passes an admission check against the memory iOS will actually grant this app (os_proc_available_memory).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Hardware & performance")
        .onAppear { hw.startSampling() }
        .onDisappear { hw.stopSampling() }
    }
}

struct BenchmarksView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var evaluations: EvaluationStore
    @ObservedObject var models: ModelManager
    @State private var target = ""
    @State private var mode: IntelligenceMode = .instant
    @State private var running = false
    @State private var error: String?
    @State private var selectedRun: EvalRun?

    private var targets: [(String, String)] {
        var t: [(String, String)] = []
        if AppleIntelligence.isAvailable { t.append((AppleFoundationBackend.modelID, "Apple Intelligence")) }
        for e in ModelRegistry.allEntries where e.isChatModel && models.isInstalled(e.id) { t.append((e.id, "\(e.name) \(e.quantization)")) }
        if let p = app.settings.activeProvider, app.settings.allowCloud, !app.settings.offlineOnly { t.append(("cloud", "\(p.name) (cloud)")) }
        return t
    }

    var body: some View {
        List {
            Section {
                Picker("Model", selection: $target) {
                    Text("Choose…").tag("")
                    ForEach(targets, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Mode", selection: $mode) {
                    ForEach(IntelligenceMode.allCases) { Text($0.shortTitle).tag($0) }
                }
                .pickerStyle(.segmented)
                if let p = evaluations.progress {
                    VStack(alignment: .leading) {
                        Text("\(p.label) (\(p.done + 1)/\(p.total))").font(.caption)
                        ProgressView(value: Double(p.done), total: Double(max(1, p.total)))
                    }
                    Button("Cancel", role: .destructive) { evaluations.cancel() }
                } else {
                    Button { run { try await evaluations.runBenchmark(modelID: target, mode: mode, orchestrator: app.orchestrator) } } label: {
                        Label("Run performance benchmark", systemImage: "speedometer")
                    }
                    .disabled(target.isEmpty || running)
                    Button { run { await evaluations.runSuite(modelID: target, modelName: targets.first { $0.0 == target }?.1 ?? target, mode: mode, orchestrator: app.orchestrator) } } label: {
                        Label("Run evaluation suite (\(EvalSuite.cases.count) tests)", systemImage: "checklist")
                    }
                    .disabled(target.isEmpty || running)
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            } footer: {
                Text("All numbers are measured on this device at run time; nothing is estimated or pre-filled. The evaluation suite sends identical prompts through the full NEXUS pipeline and grades them automatically (exact answers, executed JavaScript tests, format checks, hallucination probes). Results feed back into automatic model routing. Scores are pass rates on this suite, not a general intelligence measure.")
            }

            Section("Evaluation results") {
                if evaluations.runs.isEmpty { Text("No evaluation runs yet.").foregroundStyle(.secondary) }
                ForEach(evaluations.runs) { r in
                    Button { selectedRun = r } label: { EvalRunRow(run: r) }
                        .swipeActions { Button(role: .destructive) { evaluations.delete(run: r) } label: { Label("Delete", systemImage: "trash") } }
                }
            }

            Section("Performance benchmarks") {
                if evaluations.benchmarks.isEmpty { Text("No benchmarks yet.").foregroundStyle(.secondary) }
                ForEach(evaluations.benchmarks) { b in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(b.modelName) · \(b.mode.shortTitle)").font(.subheadline.weight(.medium))
                            Spacer()
                            Text(b.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                            GridRow { metric("Decode", String(format: "%.1f tok/s", b.decodeTokensPerSecond)); metric("TTFT", "\(b.ttftMs) ms") }
                            GridRow { metric("Prompt", String(format: "%.0f tok/s", b.promptTokensPerSecond)); metric("\(b.longPromptTokens)-tok TTFT", "\(b.longPromptTTFTms) ms") }
                            GridRow { metric("Peak mem", ByteCountFormatter.memory(Int64(b.peakMemoryBytes))); metric("Load", b.loadTimeMs.map { "\($0) ms" } ?? "—") }
                            GridRow { metric("Thermal", "\(b.thermalStart)→\(b.thermalEnd)"); metric("Battery", b.batteryStart >= 0 ? "\(Int(b.batteryStart * 100))→\(Int(b.batteryEnd * 100))%" : "n/a") }
                        }
                        Text("\(b.device) · ctx \(b.contextLength) · \(b.generatedTokens) tokens in \(b.totalMs) ms").font(.caption2).foregroundStyle(.tertiary)
                        if !b.notes.isEmpty { Text(b.notes).font(.caption2).foregroundStyle(.secondary) }
                    }
                    .swipeActions { Button(role: .destructive) { evaluations.delete(benchmark: b) } label: { Label("Delete", systemImage: "trash") } }
                }
            }
        }
        .navigationTitle("Benchmarks")
        .sheet(item: $selectedRun) { EvalRunDetail(run: $0) }
    }

    private func metric(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.caption.monospacedDigit())
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        running = true
        error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            running = false
        }
    }
}

struct EvalRunRow: View {
    let run: EvalRun

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(run.modelName) · \(run.mode.shortTitle)").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                if !run.completed { Pill(text: "Partial", tint: .orange) }
                Spacer()
                Text(run.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                ForEach(EvalCase.Group.allCases, id: \.self) { g in
                    if let r = run.passRate(group: g.rawValue) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.rawValue).font(.caption2).foregroundStyle(.secondary)
                            Text("\(Int((r * 100).rounded()))%").font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(.primary)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if let h = run.hallucinationRate { Text("Hallucination \(Int(h * 100))%").font(.caption2) }
                if let t = run.toolUseSuccess { Text("Math/tool success \(Int(t * 100))%").font(.caption2) }
                Text("Median \(run.medianLatencyMs) ms").font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct EvalRunDetail: View {
    let run: EvalRun
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatRow(label: "Model", value: run.modelName, mono: false)
                    StatRow(label: "Mode", value: run.mode.title, mono: false)
                    StatRow(label: "Device", value: run.device, mono: false)
                    StatRow(label: "Suite", value: run.suiteVersion)
                    StatRow(label: "App", value: run.appVersion)
                    StatRow(label: "Passed", value: "\(run.results.filter(\.passed).count)/\(run.results.count)")
                }
                ForEach(EvalCase.Group.allCases, id: \.self) { g in
                    let results = run.results.filter { $0.group == g.rawValue }
                    if !results.isEmpty {
                        Section(g.rawValue) {
                            ForEach(results) { r in
                                DisclosureGroup {
                                    if let c = EvalSuite.cases.first(where: { $0.id == r.id }) {
                                        Text("Tests: \(c.measures)").font(.caption).foregroundStyle(.secondary)
                                        Text("Prompt: \(c.prompt)").font(.caption)
                                    }
                                    Text("Grader: \(r.detail)").font(.caption)
                                    Text(r.output).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                    if !r.toolsUsed.isEmpty { Text("Tools: \(r.toolsUsed.joined(separator: ", "))").font(.caption2) }
                                } label: {
                                    HStack {
                                        Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(r.passed ? .green : .red)
                                        Text(r.title)
                                        Spacer()
                                        Text("\(r.latencyMs) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Evaluation run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { ShareLink(item: Self.export(run)) }
            }
        }
    }

    static func export(_ run: EvalRun) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return (try? String(data: enc.encode(run), encoding: .utf8)) ?? ""
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NEXUS AI").font(.title2.weight(.bold))
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))")
                        .foregroundStyle(.secondary)
                    Text("A local-first AI assistant. Inference runs on this iPhone with llama.cpp (Metal) and Apple's Foundation Models; cloud and web features are optional and off by default.")
                        .font(.footnote)
                }
            }
            Section("Known limitations") {
                ForEach(Self.limitations, id: \.self) { Text($0).font(.footnote) }
            }
            Section("Open-source components") {
                Text("llama.cpp & ggml — MIT License, © The ggml authors").font(.footnote)
                Text("Model weights are downloaded from their publishers under their own licenses (Apache-2.0 for Qwen3.5, Gemma 4 and Qwen2.5-Coder; MIT for Phi-4-mini; Llama 3.2 Community License for Llama 3.2). See each model's page in the Models tab.").font(.footnote)
            }
        }
        .navigationTitle("About")
    }

    static let limitations = [
        "On-device models (0.8B–9B parameters) are far smaller than frontier cloud models. Max Intelligence improves reliability with planning, tools and verification but cannot match frontier-model knowledge or reasoning depth.",
        "Only one llama.cpp model is resident at a time; switching specialists in Max mode reloads weights (typically a few seconds).",
        "Speculative decoding is not used: the recommended Qwen3.5 models are hybrid recurrent architectures whose state cannot be partially rolled back, which speculative decoding requires.",
        "The Neural Engine is used only through Apple's Foundation Models; llama.cpp models run on the GPU via Metal. Core ML conversion of third-party LLMs was evaluated and not adopted (no streaming KV-cache support for these architectures).",
        "Apple Intelligence requires iOS 26 and a supported device, and has a 4,096-token context.",
        "Web search without an API key uses DuckDuckGo's HTML page, which can change or rate-limit at any time.",
        "iOS suspends background apps, so generation stops if you leave the app; downloads continue in the background.",
        "Speech recognition is on-device only for languages Apple supports on-device.",
    ]
}
