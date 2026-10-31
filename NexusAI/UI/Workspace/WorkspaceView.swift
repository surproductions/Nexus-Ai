import SwiftUI
import PDFKit

struct WorkspaceView: View {
    @EnvironmentObject var app: AppModel
    @State private var segment = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    Text("Research").tag(0)
                    Text("Documents").tag(1)
                    Text("Memory").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()
                if segment == 0 {
                    ResearchView(orchestrator: app.orchestrator, settings: app.settings)
                } else if segment == 1 {
                    DocumentsView(documents: app.documents, orchestrator: app.orchestrator)
                } else {
                    MemoryView(memory: app.memory, settings: app.settings, embedded: true)
                }
            }
            .navigationTitle("Workspace")
        }
    }
}

struct ResearchReport: Codable, Identifiable, Hashable {
    var id = UUID()
    var created = Date()
    var question: String
    var report: String
    var sources: [SourceRef]
    var model: String
    var usedWeb: Bool
}

@MainActor
final class ResearchStore: ObservableObject {
    @Published private(set) var reports: [ResearchReport] = []
    private let db = Database.shared

    init() { reload() }

    func reload() {
        reports = db.query("SELECT body FROM research ORDER BY created DESC").compactMap {
            $0.blob("body").flatMap(Vault.open).flatMap { try? JSONDecoder().decode(ResearchReport.self, from: $0) }
        }
    }

    func save(_ r: ResearchReport) {
        guard let data = try? JSONEncoder().encode(r) else { return }
        db.run("INSERT OR REPLACE INTO research(id, created, title, body) VALUES(?,?,?,?)",
               [.text(r.id.uuidString), .real(r.created.timeIntervalSince1970), .text(""), .blob(Vault.seal(data))])
        reload()
    }

    func delete(_ r: ResearchReport) {
        db.run("DELETE FROM research WHERE id = ?", [.text(r.id.uuidString)])
        reload()
    }
}

struct ResearchView: View {
    let orchestrator: Orchestrator
    @ObservedObject var settings: SettingsStore
    @StateObject private var store = ResearchStore()
    @State private var question = ""
    @State private var session: TurnSession?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                TextField("What do you want to research?", text: $question, axis: .vertical).lineLimit(2...5)
                HStack {
                    Label(webStatus, systemImage: NetworkGate.shared.isAllowed(.webResearch) ? "globe" : "globe.badge.chevron.backward")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if session != nil {
                        Button("Stop", role: .destructive) { session?.cancel.cancel(); task?.cancel() }
                    } else {
                        Button("Research") { start() }.buttonStyle(.borderedProminent).disabled(question.trimmed.isEmpty)
                    }
                }
            } footer: {
                Text("Runs the Max Intelligence pipeline: planning, research agent, specialist agents, synthesis with citations and independent verification.")
            }
            if let session {
                Section("In progress") {
                    LiveTrace(steps: session.trace)
                    if !session.text.isEmpty { MarkdownView(text: session.text) }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section("Saved reports") {
                if store.reports.isEmpty { Text("Reports you run are saved here, encrypted on device.").foregroundStyle(.secondary) }
                ForEach(store.reports) { r in
                    NavigationLink {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(r.question).font(.title3.weight(.semibold))
                                HStack { Pill(text: r.model, symbol: "cpu"); if r.usedWeb { Pill(text: "Web", symbol: "globe", tint: .blue) } }
                                MarkdownView(text: r.report)
                                if !r.sources.isEmpty { SourcesView(sources: r.sources) }
                            }
                            .padding()
                        }
                        .toolbar { ShareLink(item: "# \(r.question)\n\n\(r.report)") }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.question).lineLimit(2)
                            Text(r.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in idx.map { store.reports[$0] }.forEach(store.delete) }
            }
        }
    }

    private var webStatus: String {
        if settings.offlineOnly { return "Offline-Only: local knowledge, memory and documents" }
        return settings.allowWebResearch ? "Web research enabled" : "Web research off — enable in Settings"
    }

    private func start() {
        let q = question.trimmed
        let s = TurnSession()
        session = s
        error = nil
        task = Task {
            let input = TurnInput(text: "Research and write a well-structured report with citations: \(q)", images: [], attachments: [],
                                  history: [], mode: .max, projectID: nil, documentIDs: [], modelOverride: nil)
            do {
                let meta = try await orchestrator.run(input, session: s)
                store.save(ResearchReport(question: q, report: s.text, sources: meta.sources, model: meta.modelName, usedWeb: meta.usedWeb))
                question = ""
            } catch {
                self.error = error.localizedDescription
            }
            session = nil
        }
    }
}

struct DocumentsView: View {
    @ObservedObject var documents: DocumentStore
    let orchestrator: Orchestrator
    @State private var importing = false
    @State private var error: String?
    @State private var query = ""

    var body: some View {
        List {
            if !documents.ingesting.isEmpty {
                Section("Indexing") {
                    ForEach(documents.ingesting.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                        VStack(alignment: .leading) {
                            Text(item.key).font(.subheadline)
                            ProgressView(value: item.value)
                        }
                    }
                }
            }
            if !query.isEmpty {
                Section("Search results") {
                    let hits = documents.search(query, limit: 8)
                    if hits.isEmpty { Text("No matches").foregroundStyle(.secondary) }
                    ForEach(hits, id: \.chunk.id) { h in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(h.document.title) · p. \(h.chunk.page)").font(.caption.weight(.semibold))
                            Text(h.chunk.text).font(.caption).lineLimit(4)
                        }
                    }
                }
            }
            Section {
                if documents.documents.isEmpty {
                    EmptyStateView(symbol: "doc.text.magnifyingglass", title: "No documents",
                                   message: "Import PDFs, text, Markdown, code or images. Text is extracted and indexed entirely on device; scanned pages are OCR'd.")
                        .listRowBackground(Color.clear)
                }
                ForEach(documents.documents) { doc in
                    NavigationLink {
                        DocumentDetailView(doc: doc, documents: documents, orchestrator: orchestrator)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title).lineLimit(1)
                            Text("\(doc.kind) · \(doc.pages) page\(doc.pages == 1 ? "" : "s") · \(doc.chars.formatted()) characters")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in idx.map { documents.documents[$0] }.forEach(documents.delete) }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .searchable(text: $query, prompt: "Search all documents")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { importing = true } label: { Label("Import", systemImage: "plus") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: DocumentStore.supportedTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                for url in urls {
                    do { try await documents.ingest(url: url) } catch { self.error = error.localizedDescription }
                }
            }
        }
    }
}

struct DocumentDetailView: View {
    let doc: DocumentRecord
    @ObservedObject var documents: DocumentStore
    let orchestrator: Orchestrator
    @State private var question = ""
    @State private var session: TurnSession?
    @State private var answer = ""
    @State private var summarizing = false
    @State private var find = ""
    @State private var showOriginal = false

    var body: some View {
        List {
            Section {
                StatRow(label: "Type", value: doc.kind, mono: false)
                StatRow(label: "Pages", value: "\(doc.pages)")
                StatRow(label: "Chunks indexed", value: "\(documents.chunks(for: doc.id).count)")
                if doc.kind == "PDF" { Button("View original") { showOriginal = true } }
            }
            Section("Summary") {
                if let s = documents.documents.first(where: { $0.id == doc.id })?.summary {
                    MarkdownView(text: s)
                } else if summarizing {
                    HStack { ProgressView(); Text(session?.status ?? "Summarizing…").foregroundStyle(.secondary) }
                } else {
                    Button("Summarize on device") { summarize() }
                }
            }
            Section("Ask this document") {
                TextField("Question", text: $question, axis: .vertical)
                Button("Ask") { ask() }.disabled(question.trimmed.isEmpty || session != nil)
                if let session, answer.isEmpty {
                    Text(session.text.isEmpty ? session.status : session.text).foregroundStyle(.secondary)
                }
                if !answer.isEmpty { MarkdownView(text: answer) }
            }
            Section("Find in document") {
                TextField("Exact phrase", text: $find)
                if !find.isEmpty {
                    let hits = documents.find(find, in: doc.id)
                    Text("\(hits.count) passage\(hits.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    ForEach(hits.prefix(20), id: \.id) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Page \(c.page)").font(.caption.weight(.semibold))
                            Text(c.text).font(.caption).lineLimit(5)
                        }
                    }
                }
            }
        }
        .navigationTitle(doc.title)
        .sheet(isPresented: $showOriginal) { PDFKitView(url: doc.fileURL).ignoresSafeArea() }
    }

    private func ask() {
        let s = TurnSession()
        session = s
        answer = ""
        Task {
            let input = TurnInput(text: question, images: [], attachments: [], history: [], mode: .thinking,
                                  projectID: nil, documentIDs: [doc.id], modelOverride: nil)
            _ = try? await orchestrator.run(input, session: s)
            answer = s.text.isEmpty ? "No answer could be produced." : s.text
            session = nil
        }
    }

    /// Map-reduce summarization so long documents fit small context windows.
    private func summarize() {
        summarizing = true
        let s = TurnSession()
        session = s
        Task {
            defer { summarizing = false; session = nil }
            let chunks = documents.chunks(for: doc.id)
            let groups = stride(from: 0, to: chunks.count, by: 6).map { Array(chunks[$0..<min($0 + 6, chunks.count)]) }
            var partials: [String] = []
            do {
                for (i, g) in groups.prefix(12).enumerated() {
                    s.status = "Summarizing part \(i + 1) of \(min(groups.count, 12))"
                    let text = g.map(\.text).joined(separator: "\n").truncated(to: 5000)
                    let input = TurnInput(text: "Summarize the key points of this excerpt in 3–6 bullets:\n\n\(text)", images: [], attachments: [],
                                          history: [], mode: .instant, projectID: nil, documentIDs: [], modelOverride: nil)
                    let part = TurnSession()
                    _ = try await orchestrator.run(input, session: part)
                    partials.append(part.text)
                }
                s.status = "Combining"
                let final = TurnSession()
                let input = TurnInput(text: "Combine these partial summaries of “\(doc.title)” into one coherent summary: a 2-sentence overview, then the key points as bullets.\n\n" + partials.joined(separator: "\n\n"),
                                      images: [], attachments: [], history: [], mode: .thinking, projectID: nil, documentIDs: [], modelOverride: nil)
                _ = try await orchestrator.run(input, session: final)
                if !final.text.isEmpty { documents.setSummary(final.text, for: doc.id) }
            } catch {
                s.status = error.localizedDescription
            }
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.document = PDFDocument(url: url)
        return v
    }
    func updateUIView(_ uiView: PDFView, context: Context) {}
}
