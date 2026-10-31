import Foundation
import CoreGraphics

/// Live state of one assistant turn, observed by the chat UI.
@MainActor
final class TurnSession: ObservableObject {
    @Published var text = ""
    @Published var thinking = ""
    @Published var trace: [TraceStep] = []
    @Published var status = ""
    @Published var route: RouteDecision?
    @Published var stats: GenerationStats?
    @Published var finished = false
    let cancel = CancellationFlag()

    @discardableResult
    func begin(_ agent: String, _ title: String, detail: String = "") -> UUID {
        let step = TraceStep(agent: agent, title: title, detail: detail)
        trace.append(step)
        status = title
        return step.id
    }

    func end(_ id: UUID, _ status: TraceStep.Status = .done, detail: String? = nil, started: Date) {
        guard let i = trace.firstIndex(where: { $0.id == id }) else { return }
        trace[i].status = status
        trace[i].durationMs = Int(Date().timeIntervalSince(started) * 1000)
        if let detail { trace[i].detail = detail }
    }
}

struct TurnInput {
    var text: String
    var images: [CGImage]
    var attachments: [Attachment]
    var history: [ChatMessage]
    var mode: IntelligenceMode
    var projectID: UUID?
    var documentIDs: [UUID]
    var modelOverride: String?
}

/// Coordinates classification, routing, context retrieval, tools, agents, verification and synthesis.
@MainActor
final class Orchestrator {
    let models: ModelManager
    let hardware: HardwareMonitor
    let settings: SettingsStore
    let memory: MemoryStore
    let documents: DocumentStore
    let evaluations: EvaluationStore

    init(models: ModelManager, hardware: HardwareMonitor, settings: SettingsStore, memory: MemoryStore,
         documents: DocumentStore, evaluations: EvaluationStore) {
        self.models = models
        self.hardware = hardware
        self.settings = settings
        self.memory = memory
        self.documents = documents
        self.evaluations = evaluations
    }

    var router: ModelRouter {
        ModelRouter(models: models, hardware: hardware, settings: settings,
                    measured: { [evaluations] id, cat in evaluations.measuredQuality(modelID: id, category: cat) })
    }

    // MARK: - Tools

    func tools(for names: [String]) -> [AgentTool] {
        var all: [AgentTool] = [CalculatorTool(), UnitConverterTool(), DateTool(), JavaScriptTool()]
        if NetworkGate.shared.isAllowed(.webResearch) {
            all.append(WebSearchTool(braveKey: Keychain.get("brave.key")))
            all.append(FetchPageTool())
        }
        let memory = self.memory
        all.append(ClosureTool(name: "search_memory", summary: "Searches the user's saved memories.", inputHint: "what to look for") { q in
            let hits = await MainActor.run { memory.retrieve(q, limit: 5, projectID: nil, minScore: 0.2) }
            return ToolOutput(text: hits.isEmpty ? "No matching memories." : hits.map { "- \($0.item.content)" }.joined(separator: "\n"))
        })
        let docs = self.documents
        all.append(ClosureTool(name: "search_documents", summary: "Searches the user's local document library.", inputHint: "a question or keywords") { q in
            let hits = await MainActor.run { docs.search(q, limit: 5) }
            let text = hits.isEmpty ? "No matching passages." : hits.map { "(\($0.document.title), p. \($0.chunk.page)) \($0.chunk.text.truncated(to: 700))" }.joined(separator: "\n\n")
            let sources = hits.map { SourceRef(title: $0.document.title, location: "\($0.document.title), p. \($0.chunk.page)", snippet: String($0.chunk.text.prefix(160))) }
            return ToolOutput(text: text, sources: sources)
        })
        return all.filter { names.contains($0.name) }
    }

    // MARK: - Entry point

    func run(_ input: TurnInput, session: TurnSession) async throws -> MessageMeta {
        let started = Date()
        var meta = MessageMeta()
        meta.mode = input.mode
        let profile = TaskClassifier.classify(input.text, hasImages: !input.images.isEmpty,
                                              hasDocuments: !input.documentIDs.isEmpty)
        let classifyStep = session.begin("Orchestrator", "Classified as \(profile.category.label)",
                                         detail: "complexity \(String(format: "%.2f", profile.complexity))" + (profile.signals.isEmpty ? "" : " · " + profile.signals.joined(separator: ", ")))
        session.end(classifyStep, started: started)

        // Explicit memory commands are handled deterministically.
        if let command = MemoryExtractor.command(in: input.text) {
            return handleMemoryCommand(command, projectID: input.projectID, session: session, meta: meta)
        }

        var budget = Budget.for(input.mode)
        var decision = try router.route(profile, mode: input.mode, override: input.modelOverride)
        meta.warnings = decision.warnings

        // Context retrieval and deterministic pre-tools.
        var context = ContextPack()
        await gatherContext(input: input, profile: profile, decision: decision, budget: &budget, context: &context,
                            session: session, meta: &meta)

        // Acquire a backend (with fallback to smaller models if memory is short).
        let backend = try await acquire(&decision, profile: profile, mode: input.mode, session: session, meta: &meta)
        session.route = decision
        meta.modelID = decision.modelID
        meta.modelName = decision.name
        meta.routeReason = decision.reason
        meta.usedCloud = !decision.isOnDevice

        models.isGenerating = true
        defer { models.isGenerating = false }

        let useAgents = input.mode == .max && (profile.complexity >= 0.4 ||
            [.research, .planning, .coding, .reasoning, .math, .document].contains(profile.category))
        if useAgents {
            try await runMultiAgent(input: input, profile: profile, decision: decision, backend: backend,
                                    context: context, budget: &budget, session: session, meta: &meta)
        } else {
            let tools = input.mode == .instant ? [] : self.tools(for: Self.defaultTools(profile))
            let result = try await generateWithTools(backend: backend, system: systemPrompt(input: input, profile: profile, context: context, tools: tools, backend: backend),
                                                     messages: buildMessages(input: input, context: context, backend: backend),
                                                     mode: input.mode, tools: tools, budget: &budget, session: session,
                                                     agent: "Assistant", stream: true, meta: &meta)
            session.text = result
            if input.mode != .instant {
                deterministicChecks(answer: result, profile: profile, context: context, session: session, meta: &meta)
            }
            if input.mode == .max {
                try await verifyAndRevise(input: input, notes: context.notesText, backend: backend, budget: &budget,
                                          session: session, meta: &meta, profile: profile, context: context)
            }
        }

        meta.sources = context.sources + meta.sources
        meta.thinking = session.thinking.isEmpty ? nil : session.thinking
        meta.trace = session.trace
        meta.totalMs = Int(Date().timeIntervalSince(started) * 1000)
        if let s = session.stats {
            meta.ttftMs = s.timeToFirstTokenMs
            meta.tokensPerSecond = s.tokensPerSecond
            meta.generatedTokens = s.generatedTokens
        }
        memory.markUsed(context.memoryIDs)
        if settings.suggestMemories {
            for (text, kind) in MemoryExtractor.suggestions(in: input.text) {
                memory.add(text, kind: kind, projectID: input.projectID, status: .suggested, importance: 0.5, source: "suggested from chat")
            }
        }
        return meta
    }

    static func defaultTools(_ p: TaskProfile) -> [String] {
        var names = ["calculator", "convert_units", "date_time", "search_memory"]
        if p.category == .coding { names.append("javascript") }
        if p.hasDocuments || p.category == .document { names.append("search_documents") }
        if p.needsCurrentInfo || p.category == .research { names += ["web_search", "fetch_page"] }
        return names
    }

    // MARK: - Memory commands

    private func handleMemoryCommand(_ command: MemoryExtractor.Command, projectID: UUID?, session: TurnSession, meta: MessageMeta) -> MessageMeta {
        var meta = meta
        let t0 = Date()
        switch command {
        case .remember(let content, let kind):
            let item = memory.add(content, kind: kind, projectID: projectID, status: .active, importance: 0.8, source: "explicit request")
            let id = session.begin("Memory", "Saved to long-term memory")
            session.end(id, detail: item.content, started: t0)
            session.text = "Saved to memory (\(item.kind.label.lowercased())): “\(item.content)”. You can review, edit or delete it anytime in the Memory tab."
        case .forget(let query):
            let hits = memory.retrieve(query, limit: 3, projectID: projectID, minScore: 0.4)
            let id = session.begin("Memory", "Searched memory to forget")
            if let best = hits.first {
                memory.delete(best.item)
                session.end(id, detail: best.item.content, started: t0)
                session.text = "Deleted from memory: “\(best.item.content)”."
            } else {
                session.end(id, .failed, detail: "No match", started: t0)
                session.text = "I couldn't find a saved memory matching “\(query)”. You can browse everything I remember in the Memory tab."
            }
        }
        meta.modelName = "Memory system"
        meta.trace = session.trace
        return meta
    }

    // MARK: - Backend acquisition

    private func acquire(_ decision: inout RouteDecision, profile: TaskProfile, mode: IntelligenceMode,
                         session: TurnSession, meta: inout MessageMeta) async throws -> InferenceBackend {
        var attempt = decision
        var excluded: Set<String> = []
        for _ in 0..<3 {
            do {
                let b = try await backend(for: attempt, session: session)
                decision = attempt
                return b
            } catch let error as NexusError {
                switch error {
                case .insufficientMemory, .modelLoadFailed:
                    excluded.insert(attempt.modelID)
                    let r = router
                    let ranked = r.candidates(for: profile, mode: mode)
                        .filter { !excluded.contains(RouteDecision(target: $0.target, name: $0.name, quality: $0.quality, context: $0.context, reason: "").modelID) }
                        .sorted { r.score($0, mode: mode) > r.score($1, mode: mode) }
                    guard let next = ranked.first else { throw error }
                    meta.warnings.append("\(attempt.name) could not be loaded (\(error.localizedDescription)). Fell back to \(next.name).")
                    attempt = RouteDecision(target: next.target, name: next.name, quality: next.quality, context: next.context,
                                            reason: "Fallback after load failure", usesVisionModel: next.vision)
                default:
                    throw error
                }
            }
        }
        throw NexusError.unavailable("No model could be loaded within the available memory.")
    }

    func backend(for decision: RouteDecision, session: TurnSession?) async throws -> InferenceBackend {
        switch decision.target {
        case .local(let entry):
            if models.loadedEntry?.id != entry.id {
                let t0 = Date()
                let id = session?.begin("Runtime", "Loading \(entry.name) (\(entry.quantization))")
                do {
                    let b = try await models.backend(for: entry, context: decision.context, vision: decision.usesVisionModel)
                    if let id { session?.end(id, detail: "\(b.runtime.contextLength)-token context · \(models.lastLoadMs) ms", started: t0) }
                    return b
                } catch {
                    if let id { session?.end(id, .failed, detail: error.localizedDescription, started: t0) }
                    throw error
                }
            }
            return try await models.backend(for: entry, context: decision.context, vision: decision.usesVisionModel)
        case .apple:
            return AppleFoundationBackend()
        case .cloud(let config):
            try NetworkGate.shared.authorize(.cloudInference)
            return CloudBackend(config: config)
        }
    }

    // MARK: - Context

    struct ContextPack {
        var memoryLines: [String] = []
        var memoryIDs: [UUID] = []
        var standing: [String] = []
        var project: String?
        var documentExcerpts: [String] = []
        var toolResults: [String] = []
        var webFindings: [String] = []
        var imageAnalyses: [String] = []
        var notes: [String] = []
        var sources: [SourceRef] = []
        var verifiedValue: String?

        var notesText: String { notes.joined(separator: "\n\n") }
    }

    private func gatherContext(input: TurnInput, profile: TaskProfile, decision: RouteDecision, budget: inout Budget,
                               context: inout ContextPack, session: TurnSession, meta: inout MessageMeta) async {
        let memLimit = input.mode == .instant ? 3 : (input.mode == .thinking ? 6 : 10)
        if settings.useMemory {
            let t0 = Date()
            context.standing = memory.standingInstructions(projectID: input.projectID).map(\.content)
            let hits = memory.retrieve(input.text, limit: memLimit, projectID: input.projectID)
            context.memoryLines = hits.map { "- (\($0.item.kind.label)) \($0.item.content)" }
            context.memoryIDs = hits.map(\.item.id)
            if !hits.isEmpty || !context.standing.isEmpty {
                let id = session.begin("Memory", "Retrieved \(hits.count) memories")
                session.end(id, detail: hits.map { $0.item.content.truncated(to: 60) }.joined(separator: " · "), started: t0)
            }
        }
        if let project = memory.project(input.projectID) { context.project = project.contextBlock }

        // Documents: attached docs, or the project's library.
        var docIDs = input.documentIDs
        if docIDs.isEmpty, let pid = input.projectID {
            docIDs = documents.documents.filter { $0.projectID == pid }.map(\.id)
        }
        if !docIDs.isEmpty {
            let t0 = Date()
            let k = input.mode == .instant ? 3 : (input.mode == .thinking ? 6 : 8)
            let hits = documents.search(input.text, in: docIDs, limit: k)
            context.documentExcerpts = hits.map { "[\($0.document.title), p. \($0.chunk.page)]\n\($0.chunk.text)" }
            context.sources += hits.map { SourceRef(title: $0.document.title, location: "\($0.document.title), p. \($0.chunk.page)", snippet: String($0.chunk.text.prefix(160))) }
            let id = session.begin("Document agent", "Retrieved \(hits.count) passages from \(docIDs.count) document(s)")
            session.end(id, started: t0)
        }

        // Images: always ground with on-device OCR / classification.
        for (i, image) in input.images.enumerated() {
            let t0 = Date()
            let id = session.begin("Vision agent", "Analyzing image \(i + 1) on device")
            let result = await VisionAnalyzer.analyze(image)
            context.imageAnalyses.append("Image \(i + 1) analysis:\n\(result.summary)")
            session.end(id, detail: result.text.isEmpty ? "No text" : "\(result.text.count) characters of text", started: t0)
        }

        // Deterministic tools: exact math, units, dates.
        if let expr = profile.mathExpression, let v = try? Calculator.evaluate(expr) {
            let t0 = Date()
            let line = "\(expr) = \(Calculator.format(v))"
            context.toolResults.append("Calculator (exact): \(line)")
            context.verifiedValue = Calculator.format(v)
            meta.toolsUsed.append("calculator")
            let id = session.begin("Reasoning agent", "Calculator: \(line)")
            session.end(id, started: t0)
        }
        if profile.unitConversion, let out = try? await UnitConverterTool().run(input.text) {
            context.toolResults.append("Unit conversion (exact): \(out.text)")
            meta.toolsUsed.append("convert_units")
            let id = session.begin("Reasoning agent", out.text)
            session.end(id, started: Date())
        }
        if profile.wantsDateTime, let out = try? await DateTool().run("now") {
            context.toolResults.append(out.text)
        }

        // Current information: web research when the user allows it.
        if profile.needsCurrentInfo && input.mode != .instant {
            if NetworkGate.shared.isAllowed(.webResearch) && NetworkGate.shared.isOnline {
                await research(query: input.text, deep: input.mode == .max, context: &context, budget: &budget, session: session, meta: &meta)
            } else {
                meta.warnings.append("This looks like it needs current information, but web research is \(settings.offlineOnly ? "disabled by Offline-Only mode" : "turned off"). The answer relies on the model's training data, which may be outdated.")
            }
        }
    }

    private func research(query: String, deep: Bool, context: inout ContextPack, budget: inout Budget,
                          session: TurnSession, meta: inout MessageMeta) async {
        let t0 = Date()
        let id = session.begin("Research agent", "Searching the web")
        do {
            budget.toolCalls += 1
            let results = try await WebResearch.search(query, braveKey: Keychain.get("brave.key"), limit: deep ? 6 : 4)
            session.end(id, detail: "\(results.count) results", started: t0)
            meta.usedWeb = true
            meta.toolsUsed.append("web_search")
            var numbered: [String] = []
            for (i, r) in results.enumerated() {
                numbered.append("[\(i + 1)] \(r.title) — \(r.location)\n\(r.snippet)")
            }
            context.sources += results
            // Read the top pages for substance.
            let pagesToRead = deep ? 3 : 1
            for (i, r) in results.prefix(pagesToRead).enumerated() where budget.canCallTool {
                let t1 = Date()
                let pid = session.begin("Research agent", "Reading \(URL(string: r.location)?.host ?? r.location)")
                budget.toolCalls += 1
                if let page = try? await WebResearch.fetch(r.location, maxChars: deep ? 4000 : 2500) {
                    numbered[i] += "\nPage extract:\n\(page.text)"
                    session.end(pid, started: t1)
                } else {
                    session.end(pid, .failed, detail: "Could not fetch", started: t1)
                }
            }
            context.webFindings = numbered
        } catch {
            session.end(id, .failed, detail: error.localizedDescription, started: t0)
            meta.warnings.append("Web research failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Prompt construction

    func systemPrompt(input: TurnInput, profile: TaskProfile, context: ContextPack, tools: [AgentTool],
                      backend: InferenceBackend, role: AgentRole? = nil) -> String {
        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = .short
        var s = """
        You are NEXUS, a private, capable AI assistant running \(backend.descriptor.isOnDevice ? "on the user's iPhone" : "via a cloud model the user enabled"). \
        Today is \(df.string(from: Date())). Be accurate, direct and genuinely helpful. Use Markdown when it aids clarity. \
        If you are not sure about something, say so rather than guessing. Never claim to have browsed the web, run code, or seen \
        content unless it appears below.
        """
        switch input.mode {
        case .instant: s += "\nRespond concisely: lead with the answer, then only essential detail."
        case .thinking: s += "\nThink the problem through carefully, then give a well-structured answer."
        case .max: s += "\nProduce the most complete, rigorous and well-organized answer you can. Check your work."
        }
        if let role { s += "\n\nRole: \(role.instructions)" }
        if !settings.persona.trimmed.isEmpty { s += "\n\nUser's custom instructions: \(settings.persona.trimmed)" }
        if !context.standing.isEmpty { s += "\n\nStanding instructions from the user:\n" + context.standing.map { "- \($0)" }.joined(separator: "\n") }
        if let p = context.project { s += "\n\nActive project:\n\(p)" }
        if !context.memoryLines.isEmpty {
            s += "\n\nRelevant things the user has asked you to remember (use only if relevant):\n" + context.memoryLines.joined(separator: "\n")
        }
        if !context.toolResults.isEmpty {
            s += "\n\nVerified tool results (authoritative — use these exact values):\n" + context.toolResults.joined(separator: "\n")
        }
        if !context.webFindings.isEmpty {
            s += "\n\nWeb research results (cite as [n]; prefer these over your training data for current facts):\n" + context.webFindings.joined(separator: "\n\n")
        }
        if !context.documentExcerpts.isEmpty {
            s += "\n\nExcerpts from the user's documents (cite as (Title, p. N)):\n" + context.documentExcerpts.joined(separator: "\n---\n")
        }
        if !tools.isEmpty { s += "\n\n" + ToolCallParser.describe(tools) }
        return s
    }

    func buildMessages(input: TurnInput, context: ContextPack, backend: InferenceBackend, extra: String? = nil) -> [PromptMessage] {
        var user = input.text
        if !input.attachments.isEmpty {
            let names = input.attachments.map { "\($0.kind == .image ? "Image" : "Document"): \($0.filename)" }.joined(separator: ", ")
            user = "[Attached: \(names)]\n\(user)"
        }
        if !context.imageAnalyses.isEmpty {
            user += "\n\n" + (backend.descriptor.supportsVision
                ? "On-device OCR of the attached image(s), for exact text:\n"
                : "You cannot see the image directly. Here is an on-device analysis of it:\n") + context.imageAnalyses.joined(separator: "\n\n")
        }
        if let extra { user += "\n\n" + extra }
        let current = PromptMessage(role: .user, content: user, images: backend.descriptor.supportsVision ? input.images : [])

        // Fit history to the remaining context window (newest first).
        let window = backend.descriptor.contextLength
        let reserved = Budget.for(input.mode).maxTokensPerCall + 600
        let systemEstimate = 900 + (context.memoryLines + context.documentExcerpts + context.webFindings + context.toolResults)
            .reduce(0) { $0 + $1.approxTokens }
        var available = max(256, window - reserved - systemEstimate - user.approxTokens - input.images.count * 700)
        var history: [PromptMessage] = []
        for m in input.history.reversed() where m.role == .user || m.role == .assistant {
            let cost = m.content.approxTokens + 8
            if cost > available { break }
            available -= cost
            history.insert(PromptMessage(role: m.role, content: m.content), at: 0)
        }
        return history + [current]
    }

    // MARK: - Generation with tool loop

    struct Sampling { var temperature: Float; var topP: Float; var topK: Int32; var minP: Float }

    func sampling(for backend: InferenceBackend, thinking: Bool, mode: IntelligenceMode) -> Sampling {
        let userT = Float(settings.temperature)
        if let llama = backend as? LlamaBackend {
            switch llama.format {
            case .qwen35: return thinking ? Sampling(temperature: 0.6, topP: 0.95, topK: 20, minP: 0) : Sampling(temperature: min(userT, 0.7), topP: 0.8, topK: 20, minP: 0)
            case .gemma4: return Sampling(temperature: min(1.0, userT + 0.3), topP: 0.95, topK: 64, minP: 0)
            default: break
            }
        }
        return Sampling(temperature: mode == .instant ? min(userT, 0.6) : userT, topP: 0.9, topK: 40, minP: 0.05)
    }

    /// Streams a response, executing tool calls the model makes (bounded by the budget).
    func generateWithTools(backend: InferenceBackend, system: String, messages: [PromptMessage], mode: IntelligenceMode,
                           tools: [AgentTool], budget: inout Budget, session: TurnSession, agent: String,
                           stream: Bool, meta: inout MessageMeta, thinkingOverride: Bool? = nil) async throws -> String {
        var transcript = messages
        let thinking = thinkingOverride ?? (mode != .instant && backend.descriptor.supportsThinking)
        let samp = sampling(for: backend, thinking: thinking, mode: mode)
        var finalText = ""
        let prefixBeforeThisCall = stream ? session.text : ""

        while true {
            guard budget.canCallModel else {
                if finalText.isEmpty { throw NexusError.unavailable("The \(mode.title) budget was exhausted before an answer was produced.") }
                break
            }
            budget.modelCalls += 1
            let request = GenerationRequest(system: system, messages: transcript,
                                            maxTokens: budget.maxTokensPerCall + (thinking ? 1024 : 0),
                                            temperature: samp.temperature, topP: samp.topP, topK: samp.topK, minP: samp.minP,
                                            enableThinking: thinking, stopSequences: tools.isEmpty ? [] : [ToolCallParser.closeTag])
            var raw = ""
            do {
                for try await event in backend.generate(request) {
                    if session.cancel.isCancelled { throw NexusError.cancelled }
                    switch event {
                    case .text(let t):
                        raw += t
                        if stream { session.text = prefixBeforeThisCall + Self.visible(raw) }
                    case .thinking(let t):
                        if stream || agent != "Assistant" { session.thinking += t }
                    case .stats(let s):
                        session.stats = s
                    }
                }
            } catch NexusError.contextOverflow(let p, let c) where transcript.count > 1 {
                // Drop the oldest history and retry once.
                transcript = Array(transcript.suffix(max(1, transcript.count / 2)))
                meta.warnings.append("Conversation trimmed to fit the \(c)-token context (prompt was \(p) tokens).")
                budget.modelCalls -= 1
                continue
            }

            if !tools.isEmpty, raw.contains(ToolCallParser.openTag), let call = ToolCallParser.parse(raw),
               let tool = tools.first(where: { $0.name == call.name }), budget.canCallTool {
                budget.toolCalls += 1
                let t0 = Date()
                let id = session.begin(agent, "Tool: \(tool.name)", detail: call.input.truncated(to: 120))
                var output: String
                do {
                    let out = try await tool.run(call.input)
                    output = out.text
                    meta.sources += out.sources
                    if tool.needsNetwork { meta.usedWeb = true }
                    session.end(id, detail: "\(call.input.truncated(to: 80)) → \(out.text.truncated(to: 120))", started: t0)
                } catch {
                    output = "Tool error: \(error.localizedDescription)"
                    session.end(id, .failed, detail: error.localizedDescription, started: t0)
                }
                if !meta.toolsUsed.contains(tool.name) { meta.toolsUsed.append(tool.name) }
                let callText = raw.contains(ToolCallParser.closeTag) ? raw : raw + ToolCallParser.closeTag
                transcript.append(PromptMessage(role: .assistant, content: callText))
                transcript.append(PromptMessage(role: .tool, content: "<tool_response>\n\(output.truncated(to: 6000))\n</tool_response>"))
                continue
            }
            finalText = Self.visible(raw).trimmed
            break
        }
        return finalText
    }

    /// Text shown to the user: everything before any tool-call markup.
    static func visible(_ raw: String) -> String {
        if let r = raw.range(of: ToolCallParser.openTag) { return String(raw[..<r.lowerBound]) }
        let hold = OutputStreamParser.partialSuffixLength(raw, ToolCallParser.openTag)
        return hold > 0 ? String(raw.dropLast(hold)) : raw
    }

    // MARK: - Multi-agent Max mode

    private func runMultiAgent(input: TurnInput, profile: TaskProfile, decision: RouteDecision, backend: InferenceBackend,
                               context: ContextPack, budget: inout Budget, session: TurnSession, meta: inout MessageMeta) async throws {
        var context = context
        var mainBackend = backend

        // 1. Plan
        let t0 = Date()
        let planID = session.begin("Orchestrator", "Planning sub-tasks")
        budget.modelCalls += 1
        let planReq = GenerationRequest(system: AgentRole.orchestrator.instructions,
                                        messages: [PromptMessage(role: .user, content: "Request:\n\(input.text)\n\nContext available: " +
                                            [context.documentExcerpts.isEmpty ? nil : "user documents",
                                             context.webFindings.isEmpty ? nil : "web results",
                                             input.images.isEmpty ? nil : "attached images"].compactMap { $0 }.joined(separator: ", "))],
                                        maxTokens: 300, temperature: 0.2, enableThinking: false)
        let planText = (try? await backend.complete(planReq, cancel: session.cancel).text) ?? ""
        var steps = PlanParser.parse(planText)
        if steps.isEmpty {
            steps = [PlanStep(agent: Self.primaryAgent(for: profile), task: input.text)]
        }
        if !input.images.isEmpty && !steps.contains(where: { $0.agent == .vision }) {
            steps.insert(PlanStep(agent: .vision, task: "Describe the attached image(s) as they relate to: \(input.text)"), at: 0)
        }
        steps = Array(steps.prefix(4))
        session.end(planID, detail: steps.map { "[\($0.agent.rawValue)] \($0.task.truncated(to: 70))" }.joined(separator: "\n"), started: t0)

        // 2. Execute sub-tasks with specialists
        for (i, step) in steps.enumerated() {
            if session.cancel.isCancelled { throw NexusError.cancelled }
            guard budget.canCallModel, budget.secondsLeft > 30 else {
                let id = session.begin(step.agent.displayName, "Skipped: budget reached")
                session.end(id, .skipped, started: Date())
                continue
            }
            let ts = Date()
            let stepID = session.begin(step.agent.displayName, "Step \(i + 1)/\(steps.count): \(step.task.truncated(to: 80))")
            var agentBackend = mainBackend
            if step.agent == .coding || step.agent == .reasoning {
                let spec = router.specialist(for: step.agent.category, mode: .max, current: decision)
                if spec.modelID != decision.modelID, let b = try? await self.backend(for: spec, session: session) {
                    agentBackend = b
                }
            }
            if step.agent == .research && context.webFindings.isEmpty && NetworkGate.shared.isAllowed(.webResearch) && NetworkGate.shared.isOnline {
                await research(query: step.task, deep: true, context: &context, budget: &budget, session: session, meta: &meta)
            }
            var agentContext = context
            agentContext.notes = context.notes
            let tools = self.tools(for: step.agent.toolNames)
            var sys = systemPrompt(input: input, profile: profile, context: agentContext, tools: tools, backend: agentBackend, role: step.agent)
            if !context.notes.isEmpty { sys += "\n\nWorking notes from other agents:\n\(context.notesText)" }
            let msgs = [PromptMessage(role: .user,
                                      content: "Overall request: \(input.text)\n\nYour sub-task: \(step.task)\n\n" +
                                        (context.imageAnalyses.isEmpty ? "" : context.imageAnalyses.joined(separator: "\n") + "\n\n") +
                                        "Complete only your sub-task. Be concise but complete.",
                                      images: step.agent == .vision && agentBackend.descriptor.supportsVision ? input.images : [])]
            do {
                let out = try await generateWithTools(backend: agentBackend, system: sys, messages: msgs, mode: .max, tools: tools,
                                                      budget: &budget, session: session, agent: step.agent.displayName,
                                                      stream: false, meta: &meta, thinkingOverride: step.agent == .reasoning)
                context.notes.append("[\(step.agent.displayName) — \(step.task.truncated(to: 80))]\n\(out.truncated(to: 1800))")
                session.end(stepID, detail: out.truncated(to: 240), started: ts)
            } catch NexusError.cancelled {
                throw NexusError.cancelled
            } catch {
                session.end(stepID, .failed, detail: error.localizedDescription, started: ts)
            }
            // Return to the primary model for synthesis if a specialist was swapped in.
            if agentBackend !== mainBackend, case .local = decision.target {
                mainBackend = (try? await self.backend(for: decision, session: session)) ?? agentBackend
            }
        }

        // 3. Synthesise (streamed)
        let ts = Date()
        let synthID = session.begin("Orchestrator", "Synthesizing final answer")
        let sys = systemPrompt(input: input, profile: profile, context: context, tools: [], backend: mainBackend) +
            (context.notes.isEmpty ? "" : "\n\nWorking notes from specialist agents (verified intermediate results):\n\(context.notesText)")
        let messages = buildMessages(input: input, context: context, backend: mainBackend,
                                     extra: "Write the final answer for the user, integrating the working notes. Do not mention the agents.")
        var budgetForSynthesis = budget
        budgetForSynthesis.maxModelCalls = max(budget.maxModelCalls, budget.modelCalls + 1)
        budgetForSynthesis.deadline = max(budget.deadline, Date().addingTimeInterval(90))
        let answer = try await generateWithTools(backend: mainBackend, system: sys, messages: messages, mode: .max, tools: [],
                                                 budget: &budgetForSynthesis, session: session, agent: "Assistant", stream: true,
                                                 meta: &meta, thinkingOverride: false)
        budget.modelCalls = budgetForSynthesis.modelCalls
        session.text = answer
        session.end(synthID, started: ts)

        deterministicChecks(answer: answer, profile: profile, context: context, session: session, meta: &meta)
        try await verifyAndRevise(input: input, notes: context.notesText, backend: mainBackend, budget: &budget,
                                  session: session, meta: &meta, profile: profile, context: context)
    }

    static func primaryAgent(for p: TaskProfile) -> AgentRole {
        switch p.category {
        case .coding: return .coding
        case .research: return .research
        case .document: return .document
        case .vision: return .vision
        default: return .reasoning
        }
    }

    // MARK: - Verification

    /// Non-model checks: exact calculator agreement, JavaScript/JSON syntax.
    private func deterministicChecks(answer: String, profile: TaskProfile, context: ContextPack, session: TurnSession, meta: inout MessageMeta) {
        let t0 = Date()
        var findings: [String] = []
        if let v = context.verifiedValue {
            let normalized = answer.replacingOccurrences(of: ",", with: "")
            if normalized.contains(v) { findings.append("Result matches exact calculation (\(v))") }
            else {
                findings.append("Answer does not state the exact computed value \(v)")
                meta.warnings.append("Exact calculator result: \(profile.mathExpression ?? "") = \(v)")
            }
        }
        for block in CodeBlocks.extract(answer) {
            switch block.language {
            case "js", "javascript":
                if let err = JavaScriptSandbox.syntaxCheck(block.code) { findings.append("JavaScript syntax error: \(err)") }
                else { findings.append("JavaScript block parses") }
            case "json":
                if let d = block.code.data(using: .utf8), (try? JSONSerialization.jsonObject(with: d)) != nil { findings.append("JSON is valid") }
                else { findings.append("JSON block is invalid") }
            default: break
            }
        }
        guard !findings.isEmpty else { return }
        let failed = findings.contains { $0.contains("error") || $0.contains("invalid") || $0.contains("does not") }
        let id = session.begin("Verification agent", "Deterministic checks")
        session.end(id, failed ? .failed : .done, detail: findings.joined(separator: "\n"), started: t0)
        meta.verified = findings.joined(separator: "; ")
    }

    private func verifyAndRevise(input: TurnInput, notes: String, backend: InferenceBackend, budget: inout Budget,
                                 session: TurnSession, meta: inout MessageMeta, profile: TaskProfile, context: ContextPack) async throws {
        guard budget.modelCalls < budget.maxModelCalls + 2, budget.secondsLeft > 20, !session.text.isEmpty else {
            let id = session.begin("Verification agent", "Skipped: budget reached")
            session.end(id, .skipped, started: Date())
            return
        }
        let t0 = Date()
        let id = session.begin("Verification agent", "Independently reviewing the answer")
        budget.modelCalls += 1
        let req = GenerationRequest(
            system: AgentRole.verification.instructions,
            messages: [PromptMessage(role: .user, content: """
                Request:
                \(input.text)

                Working notes and evidence:
                \((notes + "\n" + context.toolResults.joined(separator: "\n") + "\n" + context.webFindings.joined(separator: "\n")).truncated(to: 6000))

                Draft answer:
                \(session.text.truncated(to: 6000))
                """)],
            maxTokens: 400, temperature: 0.1, enableThinking: false)
        let review = (try? await backend.complete(req, cancel: session.cancel).text) ?? ""
        let verdictPass = review.uppercased().contains("VERDICT: PASS") || !review.uppercased().contains("REVISE")
        if verdictPass {
            session.end(id, detail: "PASS", started: t0)
            meta.verified = [meta.verified, "Passed independent review"].compactMap { $0 }.joined(separator: "; ")
            return
        }
        let issues = review.components(separatedBy: "\n").dropFirst().map(\.trimmed).filter { !$0.isEmpty }.joined(separator: "\n")
        session.end(id, .failed, detail: "Issues found:\n\(issues.truncated(to: 400))", started: t0)
        guard budget.secondsLeft > 20, !session.cancel.isCancelled else { return }

        let t1 = Date()
        let rid = session.begin("Orchestrator", "Revising answer to address review")
        let draft = session.text
        session.text = ""
        var reviseBudget = budget
        reviseBudget.maxModelCalls = budget.modelCalls + 1
        reviseBudget.deadline = max(budget.deadline, Date().addingTimeInterval(60))
        let sys = systemPrompt(input: input, profile: profile, context: context, tools: [], backend: backend)
        let revised = try await generateWithTools(
            backend: backend, system: sys,
            messages: [PromptMessage(role: .user, content: "\(input.text)\n\nA reviewer found these problems in your draft:\n\(issues)\n\nDraft:\n\(draft.truncated(to: 5000))\n\nWrite the corrected, complete final answer. Do not mention the review.")],
            mode: .max, tools: [], budget: &reviseBudget, session: session, agent: "Assistant", stream: true, meta: &meta,
            thinkingOverride: false)
        budget.modelCalls = reviseBudget.modelCalls
        if revised.trimmed.isEmpty { session.text = draft } else { session.text = revised }
        session.end(rid, started: t1)
        meta.verified = "Revised after independent review: " + issues.replacingOccurrences(of: "\n", with: " ").truncated(to: 200)
    }
}

enum CodeBlocks {
    struct Block { var language: String; var code: String }

    static func extract(_ text: String) -> [Block] {
        var out: [Block] = []
        let parts = text.components(separatedBy: "```")
        guard parts.count >= 3 else { return [] }
        var i = 1
        while i < parts.count {
            let block = parts[i]
            let firstLine = block.components(separatedBy: "\n").first ?? ""
            let code = block.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            out.append(Block(language: firstLine.trimmed.lowercased(), code: code))
            i += 2
        }
        return out
    }
}
