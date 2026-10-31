import SwiftUI
import UniformTypeIdentifiers

struct ModelsView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var models: ModelManager
    @ObservedObject var downloads: DownloadManager
    @ObservedObject var hardware = HardwareMonitor.shared
    @State private var confirm: (ModelEntry, DownloadManager.Kind)?
    @State private var error: String?
    @State private var showImporter = false
    @State private var showCompare = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    deviceSummary
                }
                if !downloads.items.isEmpty {
                    Section("Downloads") {
                        ForEach(downloads.items.values.sorted { $0.id < $1.id }) { item in
                            DownloadRow(item: item, downloads: downloads)
                        }
                    }
                }
                Section {
                    AppleModelRow()
                } header: { Text("Built in") }
                Section {
                    ForEach(sortedCatalog) { entry in
                        NavigationLink {
                            ModelDetailView(entry: entry, models: models, downloads: downloads, evaluations: app.evaluations,
                                            onDownload: { request($0, $1) })
                        } label: {
                            ModelRow(entry: entry, models: models, downloads: downloads, fit: fit(entry))
                        }
                    }
                } header: {
                    Text("Catalog")
                } footer: {
                    Text("Weights download directly from each publisher's Hugging Face repository under the model's own license; NEXUS never redistributes them. Every file is verified against its published SHA-256 before use.")
                }
                let custom = CustomModels.all()
                if !custom.isEmpty {
                    Section("Imported") {
                        ForEach(custom) { e in
                            ModelRow(entry: e, models: models, downloads: downloads, fit: fit(e))
                                .swipeActions { Button(role: .destructive) { models.delete(e) } label: { Label("Delete", systemImage: "trash") } }
                        }
                    }
                }
                Section {
                    StatRow(label: "Models on disk", value: ByteCountFormatter.file(models.diskUsage()))
                    StatRow(label: "Free storage", value: ByteCountFormatter.file(hardware.freeStorage))
                    Button { showImporter = true } label: { Label("Import GGUF file…", systemImage: "square.and.arrow.down") }
                } footer: {
                    Text("You can also copy .gguf files into NEXUS's folder in the Files app; they're imported on next launch.")
                }
            }
            .navigationTitle("Models")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCompare = true } label: { Label("Compare", systemImage: "square.split.2x1") }
                }
            }
            .sheet(isPresented: $showCompare) { CompareModelsView(models: models, evaluations: app.evaluations) }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data, .data]) { result in
                if case .success(let url) = result {
                    do { _ = try models.importModel(from: url) } catch { self.error = error.localizedDescription }
                }
            }
            .alert("Download \(confirm?.0.name ?? "")?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
                Button("Download") {
                    if let c = confirm { start(c.0, c.1) }
                    confirm = nil
                }
                Button("Cancel", role: .cancel) { confirm = nil }
            } message: {
                if let c = confirm {
                    let e = c.0, k = c.1
                    let size = k == .vision ? (e.visionProjector?.sizeBytes ?? 0) : e.file.sizeBytes
                    Text("This is a \(ByteCountFormatter.file(size)) download\(NetworkGate.shared.isExpensive ? " over a cellular or metered connection" : ""). It continues in the background and is verified with SHA-256 when complete. License: \(e.license).")
                }
            }
            .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
            .onAppear { hardware.refresh(); models.rescan() }
        }
    }

    private var sortedCatalog: [ModelEntry] {
        ModelRegistry.catalog.sorted { a, b in
            let ia = models.isInstalled(a.id), ib = models.isInstalled(b.id)
            if ia != ib { return ia }
            return a.file.sizeBytes < b.file.sizeBytes
        }
    }

    private var deviceSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hardware.device.marketingName).font(.headline)
                    Text("\(hardware.device.chip) · \(ByteCountFormatter.memory(Int64(hardware.device.physicalMemory))) RAM").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Pill(text: hardware.tier.rawValue, symbol: "gauge.with.dots.needle.67percent", tint: .accentColor)
            }
            Text(recommendation).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var recommendation: String {
        let gb = Double(hardware.device.physicalMemory) / 1_073_741_824
        if gb >= 11 { return "Recommended: Qwen3.5 2B for Instant, Qwen3.5 4B for Thinking, Qwen3.5 9B (with vision) for Max Intelligence." }
        if gb >= 7.5 { return "Recommended: Qwen3.5 2B for Instant and Qwen3.5 4B for Thinking/Max. Qwen3.5 9B (compact) may fit when few apps are open." }
        if gb >= 5.5 { return "Recommended: Qwen3.5 2B for Instant and Qwen3.5 4B for Thinking. Larger models will not fit reliably." }
        return "Recommended: Qwen3.5 0.8B or 2B. This device has limited memory for local models."
    }

    enum Fit { case good, tight, no }

    private func fit(_ e: ModelEntry) -> Fit {
        let ctx = 2048
        let need = Double(e.estimatedMemory(context: ctx, withVision: false))
        let budget = Double(hardware.memoryBudget > 0 ? hardware.memoryBudget : hardware.device.physicalMemory / 2)
        if need < budget * 0.6 { return .good }
        if need < budget * 0.85 { return .tight }
        return .no
    }

    private func request(_ e: ModelEntry, _ k: DownloadManager.Kind) {
        let size = k == .vision ? (e.visionProjector?.sizeBytes ?? 0) : e.file.sizeBytes
        if size > 1_000_000_000 || NetworkGate.shared.isExpensive { confirm = (e, k) } else { start(e, k) }
    }

    private func start(_ e: ModelEntry, _ k: DownloadManager.Kind) {
        do { try downloads.start(e, kind: k) } catch { self.error = error.localizedDescription }
    }
}

struct AppleModelRow: View {
    var body: some View {
        let status = AppleIntelligence.status
        HStack(spacing: 12) {
            Image(systemName: "apple.logo").font(.title3).frame(width: 34, height: 34)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Intelligence").font(.body.weight(.medium))
                Text(status.available ? "~3B on-device model · no download · runs outside the app's memory" : status.reason)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: status.available ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(status.available ? .green : .secondary)
        }
    }
}

struct ModelRow: View {
    let entry: ModelEntry
    @ObservedObject var models: ModelManager
    @ObservedObject var downloads: DownloadManager
    var fit: ModelsView.Fit

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.body.weight(.medium))
                    if models.loadedEntry?.id == entry.id { Pill(text: "Loaded", tint: .green) }
                }
                Text("\(entry.publisher) · \(Calculator.format(entry.parameterBillions))B · \(entry.quantization) · \(ByteCountFormatter.file(entry.file.sizeBytes))")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(entry.capabilities.filter { [.reasoning, .coding, .vision, .thinking].contains($0) }, id: \.self) { c in
                        Pill(text: c.label)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if models.isInstalled(entry.id) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Installed")
                } else if let d = downloads.item(entry.id, .model) {
                    ProgressView(value: d.progress).frame(width: 54)
                } else {
                    Image(systemName: "arrow.down.circle").foregroundStyle(Color.accentColor).accessibilityLabel("Not installed")
                }
                fitLabel
            }
        }
    }

    @ViewBuilder private var fitLabel: some View {
        switch fit {
        case .good: Text("Fits").font(.caption2).foregroundStyle(.green)
        case .tight: Text("Tight").font(.caption2).foregroundStyle(.orange)
        case .no: Text("Too large").font(.caption2).foregroundStyle(.red)
        }
    }
}

struct DownloadRow: View {
    let item: DownloadManager.Item
    @ObservedObject var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name + (item.kind == .vision ? " · vision adapter" : "")).font(.subheadline.weight(.medium))
                Spacer()
                controls
            }
            ProgressView(value: item.progress)
            HStack {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(ByteCountFormatter.file(item.written)) / \(ByteCountFormatter.file(item.total))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        switch item.status {
        case .downloading:
            if item.bytesPerSecond > 0 {
                let remaining = Double(item.total - item.written) / item.bytesPerSecond
                return "\(ByteCountFormatter.file(Int64(item.bytesPerSecond)))/s · \(Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))) left"
            }
            return "Downloading…"
        case .paused: return "Paused"
        case .verifying: return "Verifying SHA-256…"
        case .failed(let e): return "Failed: \(e)"
        case .completed: return "Installed and verified"
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 14) {
            switch item.status {
            case .downloading:
                Button { downloads.pause(item.entryID, item.kind) } label: { Image(systemName: "pause.fill") }.accessibilityLabel("Pause")
            case .paused, .failed:
                Button {
                    if let e = ModelRegistry.entry(item.entryID) { try? downloads.start(e, kind: item.kind) }
                } label: { Image(systemName: "play.fill") }.accessibilityLabel("Resume")
            case .completed:
                Button { downloads.clearFinished() } label: { Image(systemName: "checkmark") }.accessibilityLabel("Dismiss")
            case .verifying:
                ProgressView().controlSize(.small)
            }
            if item.status != .completed && item.status != .verifying {
                Button(role: .destructive) { downloads.cancel(item.entryID, item.kind) } label: { Image(systemName: "xmark") }.accessibilityLabel("Cancel")
            }
        }
        .buttonStyle(.borderless)
    }
}

struct ModelDetailView: View {
    let entry: ModelEntry
    @ObservedObject var models: ModelManager
    @ObservedObject var downloads: DownloadManager
    @ObservedObject var evaluations: EvaluationStore
    var onDownload: (ModelEntry, DownloadManager.Kind) -> Void
    @ObservedObject private var hardware = HardwareMonitor.shared
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                Text(entry.notes).font(.subheadline)
                StatRow(label: "Publisher", value: entry.publisher, mono: false)
                StatRow(label: "Parameters", value: "\(Calculator.format(entry.parameterBillions))B")
                StatRow(label: "Quantization", value: entry.quantization)
                StatRow(label: "Download size", value: ByteCountFormatter.file(entry.file.sizeBytes))
                if let p = entry.visionProjector { StatRow(label: "Vision adapter", value: ByteCountFormatter.file(p.sizeBytes)) }
                StatRow(label: "Native context", value: "\(entry.nativeContext / 1024)K tokens")
                StatRow(label: "Est. memory @ 4K ctx", value: ByteCountFormatter.memory(Int64(entry.estimatedMemory(context: 4096, withVision: false))))
                StatRow(label: "Chat format", value: entry.promptFormat.rawValue)
            }
            Section {
                ForEach(TaskCategory.allCases.filter { $0 != .quick }, id: \.self) { c in
                    let measured = evaluations.measuredQuality(modelID: entry.id, category: c)
                    HStack {
                        Text(c.label).frame(width: 110, alignment: .leading)
                        MeterBar(value: (measured ?? entry.prior(c)) / 10, tint: measured != nil ? .green : .accentColor)
                        Text(String(format: "%.1f", measured ?? entry.prior(c))).font(.caption.monospacedDigit()).frame(width: 30)
                    }
                }
            } header: { Text("Capability profile") } footer: {
                Text("Blue bars are priors from publisher-reported benchmarks (not measured by NEXUS). Green bars are your own on-device evaluation results, which the router uses instead once available.")
            }
            Section("Measured on this device") {
                let runs = evaluations.benchmarks.filter { $0.modelID == entry.id }
                if runs.isEmpty {
                    Text("No benchmarks yet. Run one from Settings → Benchmarks.").foregroundStyle(.secondary)
                }
                ForEach(runs.prefix(3)) { b in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(b.mode.title) · \(b.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        Text("\(String(format: "%.1f", b.decodeTokensPerSecond)) tok/s · TTFT \(b.ttftMs) ms · peak \(ByteCountFormatter.memory(Int64(b.peakMemoryBytes)))")
                            .font(.subheadline.monospacedDigit())
                    }
                }
            }
            Section("Provenance & license") {
                StatRow(label: "Source", value: entry.sourceRepo, mono: false)
                StatRow(label: "File", value: entry.file.filename, mono: false)
                if let sha = entry.file.sha256 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SHA-256").foregroundStyle(.secondary)
                        Text(sha).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
                Link(destination: entry.licenseURL) { Label(entry.license, systemImage: "doc.plaintext") }
            }
            Section {
                if models.isInstalled(entry.id) {
                    if entry.visionProjector != nil && !models.visionInstalled.contains(entry.id) {
                        Button { onDownload(entry, .vision) } label: { Label("Add vision adapter", systemImage: "eye") }
                    }
                    if models.loadedEntry?.id == entry.id {
                        Button("Unload from memory") { models.unload() }
                    }
                    if models.visionInstalled.contains(entry.id) {
                        Button("Remove vision adapter", role: .destructive) { models.deleteProjector(entry) }
                    }
                    Button("Delete model", role: .destructive) { confirmDelete = true }
                } else if downloads.item(entry.id, .model) == nil {
                    Button { onDownload(entry, .model) } label: { Label("Download \(ByteCountFormatter.file(entry.file.sizeBytes))", systemImage: "arrow.down.circle") }
                    if entry.visionProjector != nil {
                        Button { onDownload(entry, .model); onDownload(entry, .vision) } label: { Label("Download with vision adapter", systemImage: "eye") }
                    }
                } else if let d = downloads.item(entry.id, .model) {
                    DownloadRow(item: d, downloads: downloads)
                }
            }
        }
        .navigationTitle(entry.name)
        .confirmationDialog("Delete \(entry.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { models.delete(entry) }
        }
    }
}

struct CompareModelsView: View {
    @ObservedObject var models: ModelManager
    @ObservedObject var evaluations: EvaluationStore
    @Environment(\.dismiss) private var dismiss
    private let categories: [TaskCategory] = [.chat, .reasoning, .math, .coding, .research, .vision]

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("Model").font(.caption.weight(.semibold))
                        Text("Size").font(.caption.weight(.semibold))
                        ForEach(categories, id: \.self) { Text($0.label).font(.caption.weight(.semibold)) }
                    }
                    Divider()
                    ForEach(ModelRegistry.catalog) { e in
                        GridRow {
                            VStack(alignment: .leading) {
                                Text(e.name).font(.caption.weight(.medium))
                                Text(e.quantization).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(ByteCountFormatter.file(e.file.sizeBytes)).font(.caption.monospacedDigit())
                            ForEach(categories, id: \.self) { c in
                                let m = evaluations.measuredQuality(modelID: e.id, category: c)
                                Text(String(format: "%.1f", m ?? e.prior(c)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(m != nil ? .green : (e.prior(c) == 0 ? .secondary : .primary))
                            }
                        }
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                Text("Scores 0–10. Green = measured by your on-device eval suite; others are priors from publisher-reported benchmarks, not NEXUS measurements.")
                    .font(.caption).foregroundStyle(.secondary).padding()
                    .background(.bar)
            }
            .navigationTitle("Compare models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
