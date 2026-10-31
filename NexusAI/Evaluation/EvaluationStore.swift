import Foundation
import UIKit

struct EvalCaseResult: Codable, Identifiable, Hashable, Sendable {
    var id: String            // case id
    var title: String
    var group: String
    var category: String
    var passed: Bool
    var detail: String
    var output: String
    var latencyMs: Int
    var tokensPerSecond: Double?
    var toolsUsed: [String]
}

struct EvalRun: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date = Date()
    var suiteVersion = EvalSuite.version
    var modelID: String
    var modelName: String
    var mode: IntelligenceMode
    var device: String
    var appVersion: String
    var results: [EvalCaseResult]
    var completed: Bool

    func passRate(group: String? = nil, category: String? = nil) -> Double? {
        let r = results.filter { (group == nil || $0.group == group) && (category == nil || $0.category == category) }
        guard !r.isEmpty else { return nil }
        return Double(r.filter(\.passed).count) / Double(r.count)
    }

    var hallucinationRate: Double? {
        let probes = results.filter { $0.id == "g9" || $0.id == "g10" }
        guard !probes.isEmpty else { return nil }
        return Double(probes.filter { !$0.passed }.count) / Double(probes.count)
    }

    var toolUseSuccess: Double? {
        let r = results.filter { $0.group == EvalCase.Group.reasoning.rawValue && $0.category == TaskCategory.math.rawValue }
        guard !r.isEmpty else { return nil }
        return Double(r.filter(\.passed).count) / Double(r.count)
    }

    var medianLatencyMs: Int {
        let l = results.map(\.latencyMs).sorted()
        return l.isEmpty ? 0 : l[l.count / 2]
    }
}

struct BenchmarkResult: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date = Date()
    var modelID: String
    var modelName: String
    var quantization: String
    var mode: IntelligenceMode
    var device: String
    var contextLength: Int
    var loadTimeMs: Int?
    var ttftMs: Int
    var decodeTokensPerSecond: Double
    var promptTokensPerSecond: Double
    var longPromptTokens: Int
    var longPromptTTFTms: Int
    var totalMs: Int
    var generatedTokens: Int
    var peakMemoryBytes: UInt64
    var thermalStart: String
    var thermalEnd: String
    var batteryStart: Float
    var batteryEnd: Float
    var notes: String
}

/// Stores evaluation runs and performance benchmarks, and feeds measured quality back into routing.
@MainActor
final class EvaluationStore: ObservableObject {
    @Published private(set) var runs: [EvalRun] = []
    @Published private(set) var benchmarks: [BenchmarkResult] = []
    @Published var progress: (done: Int, total: Int, label: String)?
    private var cancelFlag: CancellationFlag?
    private let db = Database.shared

    init() { reload() }

    func reload() {
        let dec = JSONDecoder()
        runs = db.query("SELECT body FROM eval_runs ORDER BY created DESC").compactMap { $0.blob("body").flatMap { try? dec.decode(EvalRun.self, from: $0) } }
        benchmarks = db.query("SELECT body FROM benchmarks ORDER BY created DESC").compactMap { $0.blob("body").flatMap { try? dec.decode(BenchmarkResult.self, from: $0) } }
    }

    private func save(_ run: EvalRun) {
        guard let data = try? JSONEncoder().encode(run) else { return }
        db.run("INSERT OR REPLACE INTO eval_runs(id, created, body) VALUES(?,?,?)", [.text(run.id.uuidString), .real(run.date.timeIntervalSince1970), .blob(data)])
        reload()
    }

    private func save(_ b: BenchmarkResult) {
        guard let data = try? JSONEncoder().encode(b) else { return }
        db.run("INSERT OR REPLACE INTO benchmarks(id, created, body) VALUES(?,?,?)", [.text(b.id.uuidString), .real(b.date.timeIntervalSince1970), .blob(data)])
        reload()
    }

    func delete(run: EvalRun) { db.run("DELETE FROM eval_runs WHERE id = ?", [.text(run.id.uuidString)]); reload() }
    func delete(benchmark: BenchmarkResult) { db.run("DELETE FROM benchmarks WHERE id = ?", [.text(benchmark.id.uuidString)]); reload() }

    func cancel() { cancelFlag?.cancel() }

    /// Measured quality (0–10) for a model and category from its latest completed run (needs ≥ 2 cases).
    func measuredQuality(modelID: String, category: TaskCategory) -> Double? {
        guard let run = runs.first(where: { $0.modelID == modelID && $0.completed }) else { return nil }
        let r = run.results.filter { $0.category == category.rawValue }
        guard r.count >= 2 else { return nil }
        return 10 * Double(r.filter(\.passed).count) / Double(r.count)
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")"
    }

    // MARK: Evaluation

    /// Runs the full suite through the real orchestration pipeline (routing, tools, memory, verification) with
    /// the model pinned, using identical prompts for every model.
    func runSuite(modelID: String, modelName: String, mode: IntelligenceMode, orchestrator: Orchestrator,
                  cases: [EvalCase] = EvalSuite.cases) async {
        let flag = CancellationFlag()
        cancelFlag = flag
        var run = EvalRun(modelID: modelID, modelName: modelName, mode: mode,
                          device: HardwareMonitor.shared.device.marketingName, appVersion: appVersion, results: [], completed: false)
        let wasUsingMemory = orchestrator.settings.useMemory
        let wasSuggesting = orchestrator.settings.suggestMemories
        orchestrator.settings.useMemory = false        // isolate from personal memory
        orchestrator.settings.suggestMemories = false
        defer {
            orchestrator.settings.useMemory = wasUsingMemory
            orchestrator.settings.suggestMemories = wasSuggesting
            progress = nil
        }
        for (i, c) in cases.enumerated() {
            if flag.isCancelled { break }
            progress = (i, cases.count, c.title)
            var history: [ChatMessage] = []
            let start = Date()
            var output = ""
            var meta: MessageMeta?
            do {
                for (t, turn) in c.turns.enumerated() {
                    let session = TurnSession()
                    let images: [CGImage] = (t == c.turns.count - 1 && c.media != .none) ? [EvalSuite.image(for: c.media)].compactMap { $0 } : []
                    let input = TurnInput(text: turn, images: images, attachments: [], history: history, mode: mode,
                                          projectID: nil, documentIDs: [], modelOverride: modelID)
                    let m = try await orchestrator.run(input, session: session)
                    history.append(ChatMessage(role: .user, content: turn))
                    history.append(ChatMessage(role: .assistant, content: session.text))
                    output = session.text
                    meta = m
                }
            } catch {
                output = "Error: \(error.localizedDescription)"
            }
            let (passed, detail) = output.hasPrefix("Error:") ? (false, output) : EvalSuite.grade(c, output: output)
            run.results.append(EvalCaseResult(id: c.id, title: c.title, group: c.group.rawValue, category: c.category.rawValue,
                                              passed: passed, detail: detail, output: output.truncated(to: 3000),
                                              latencyMs: Int(Date().timeIntervalSince(start) * 1000),
                                              tokensPerSecond: meta?.tokensPerSecond, toolsUsed: meta?.toolsUsed ?? []))
            save(run)
        }
        run.completed = !flag.isCancelled
        save(run)
    }

    // MARK: Auto-configuration from on-device measurements

    static let quickCaseIDs = ["r1", "r3", "r6", "r9", "c1", "c4", "g1", "g3", "g8", "g9"]

    /// Benchmarks and quick-evaluates every installed chat model, then writes a measured mode policy.
    func autoConfigure(orchestrator: Orchestrator, memoryClass: MemoryClass) async -> String {
        var candidates: [(String, String, Double)] = []   // id, name, params (B)
        if AppleIntelligence.isAvailable { candidates.append((AppleFoundationBackend.modelID, "Apple Intelligence", 3)) }
        for e in ModelRegistry.allEntries where e.isChatModel && orchestrator.models.isInstalled(e.id) {
            candidates.append((e.id, "\(e.name) \(e.quantization)", e.parameterBillions))
        }
        guard !candidates.isEmpty else { return "No installed models to measure. Download at least one model first." }
        let cases = EvalSuite.cases.filter { Self.quickCaseIDs.contains($0.id) }
        var measured: [(id: String, name: String, params: Double, pass: Double, tps: Double)] = []
        var failures: [String] = []
        for c in candidates {
            if cancelFlag?.isCancelled == true { break }
            do {
                try await runBenchmark(modelID: c.0, mode: .instant, orchestrator: orchestrator)
            } catch {
                failures.append("\(c.1): \(error.localizedDescription)")
                continue
            }
            await runSuite(modelID: c.0, modelName: c.1 + " (quick)", mode: .thinking, orchestrator: orchestrator, cases: cases)
            let tps = benchmarks.first { $0.modelID == c.0 }?.decodeTokensPerSecond ?? 0
            let pass = runs.first { $0.modelID == c.0 }?.passRate() ?? 0
            measured.append((c.0, c.1, c.2, pass, tps))
        }
        guard !measured.isEmpty else { return "Measurement failed: " + failures.joined(separator: "; ") }
        let maxTPS = max(1, measured.map { $0.tps }.max() ?? 1)
        let instant = measured.filter { $0.pass >= 0.5 }.sorted { $0.tps > $1.tps }.map { $0.id }
        let thinking = measured.sorted { (0.75 * $0.pass + 0.25 * $0.tps / maxTPS) > (0.75 * $1.pass + 0.25 * $1.tps / maxTPS) }.map { $0.id }
        let maxList = measured.sorted { $0.pass != $1.pass ? $0.pass > $1.pass : $0.params > $1.params }.map { $0.id }
        var policy = ModePolicyStore.load(memoryClass)
        if !instant.isEmpty { policy.instant = instant }
        policy.thinking = thinking
        policy.max = maxList
        policy.source = "measured \(Date().formatted(date: .abbreviated, time: .shortened))"
        ModePolicyStore.save(policy, for: memoryClass)
        let summary = measured.map { "\($0.name): \(Int($0.pass * 100))% pass, \(String(format: "%.1f", $0.tps)) tok/s" }.joined(separator: "\n")
        return "Configured from measurements on this device.\nInstant → \(name(instant.first, measured))\nThinking → \(name(thinking.first, measured))\nMax → \(name(maxList.first, measured))\n\n\(summary)" +
            (failures.isEmpty ? "" : "\n\nSkipped: " + failures.joined(separator: "; ")) +
            (instant.isEmpty ? "\nNo model passed ≥50% of the quick suite, so Instant was left unchanged." : "")
    }

    private func name(_ id: String?, _ list: [(id: String, name: String, params: Double, pass: Double, tps: Double)]) -> String {
        list.first { $0.id == id }?.name ?? "unchanged"
    }

    // MARK: Performance benchmark

    func runBenchmark(modelID: String, mode: IntelligenceMode, orchestrator: Orchestrator) async throws {
        let hw = HardwareMonitor.shared
        let models = orchestrator.models
        let profile = TaskClassifier.classify("benchmark")
        let decision = try orchestrator.router.route(profile, mode: mode, override: modelID)
        hw.refresh()
        let thermalStart = hw.thermalLabel
        let batteryStart = hw.batteryLevel
        let peakBox = PeakMemory(HardwareMonitor.currentFootprint())
        let sampler = Task.detached {
            while !Task.isCancelled {
                peakBox.update(HardwareMonitor.currentFootprint())
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { sampler.cancel() }

        var loadMs: Int?
        if case .local = decision.target {
            models.unload()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let t = Date()
            _ = try await orchestrator.backend(for: decision, session: nil)
            loadMs = Int(Date().timeIntervalSince(t) * 1000)
        }
        let backend = try await orchestrator.backend(for: decision, session: nil)
        models.isGenerating = true
        defer { models.isGenerating = false }

        let maxTokens = mode == .instant ? 128 : 256
        progress = (0, 3, "Short prompt")
        let short = try await backend.complete(GenerationRequest(system: "You are a helpful assistant.",
            messages: [PromptMessage(role: .user, content: "Write two sentences about the ocean.")],
            maxTokens: 64, temperature: 0.7, enableThinking: false))
        progress = (1, 3, "Sustained generation")
        let long = try await backend.complete(GenerationRequest(system: "You are a helpful assistant.",
            messages: [PromptMessage(role: .user, content: "Write a detailed, multi-paragraph explanation of how vaccines train the immune system.")],
            maxTokens: maxTokens, temperature: 0.7, enableThinking: false))
        progress = (2, 3, "Long context")
        let filler = String(repeating: "The quarterly report notes steady growth in regional sales, improved logistics and lower costs. ", count: 60)
        let ctxTest = try await backend.complete(GenerationRequest(system: "You are a helpful assistant.",
            messages: [PromptMessage(role: .user, content: filler + "\n\nSummarize the report above in one sentence.")],
            maxTokens: 48, temperature: 0.3, enableThinking: false))
        progress = nil
        hw.refresh()

        let s1 = short.stats ?? GenerationStats()
        let s2 = long.stats ?? GenerationStats()
        let s3 = ctxTest.stats ?? GenerationStats()
        let entry = ModelRegistry.entry(modelID)
        let result = BenchmarkResult(
            modelID: decision.modelID, modelName: decision.name, quantization: entry?.quantization ?? "-", mode: mode,
            device: hw.device.marketingName, contextLength: backend.descriptor.contextLength, loadTimeMs: loadMs,
            ttftMs: s1.timeToFirstTokenMs, decodeTokensPerSecond: s2.tokensPerSecond,
            promptTokensPerSecond: s3.promptTokensPerSecond, longPromptTokens: s3.promptTokens,
            longPromptTTFTms: s3.timeToFirstTokenMs, totalMs: s1.totalMs + s2.totalMs + s3.totalMs,
            generatedTokens: s1.generatedTokens + s2.generatedTokens + s3.generatedTokens, peakMemoryBytes: peakBox.value,
            thermalStart: thermalStart, thermalEnd: hw.thermalLabel, batteryStart: batteryStart, batteryEnd: hw.batteryLevel,
            notes: decision.isOnDevice ? (backend is AppleFoundationBackend ? "Apple model runs out-of-process; token counts are estimates and app memory excludes the model." : "")
                                       : "Cloud: timings include network latency; memory reflects this app only.")
        save(result)
    }
}

final class PeakMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: UInt64
    init(_ v: UInt64) { _value = v }
    func update(_ v: UInt64) { lock.lock(); _value = max(_value, v); lock.unlock() }
    var value: UInt64 { lock.lock(); defer { lock.unlock() }; return _value }
}
