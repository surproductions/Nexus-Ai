import Foundation

struct MemoryItem: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case preference, fact, instruction, decision, knowledge
        var label: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .preference: return "heart"
            case .fact: return "person.text.rectangle"
            case .instruction: return "text.badge.checkmark"
            case .decision: return "checkmark.seal"
            case .knowledge: return "book"
            }
        }
    }
    enum Status: String, Codable, Sendable { case active, suggested }

    var id = UUID()
    var kind: Kind
    var content: String
    var projectID: UUID?
    var created = Date()
    var updated = Date()
    var lastUsed: Date?
    var useCount = 0
    var importance: Double = 0.5
    var pinned = false
    var status: Status = .active
    var source: String = "user"
}

struct ProjectTask: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var done = false
}

struct Project: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var summary: String = ""
    var decisions: [String] = []
    var tasks: [ProjectTask] = []
    var notes: String = ""
    var created = Date()
    var updated = Date()

    var contextBlock: String {
        var s = "Project “\(name)”"
        if !summary.isEmpty { s += "\nSummary: \(summary)" }
        if !decisions.isEmpty { s += "\nDecisions so far:\n" + decisions.map { "- \($0)" }.joined(separator: "\n") }
        let open = tasks.filter { !$0.done }
        if !open.isEmpty { s += "\nOutstanding tasks:\n" + open.map { "- \($0.title)" }.joined(separator: "\n") }
        let done = tasks.filter(\.done)
        if !done.isEmpty { s += "\nCompleted: " + done.map(\.title).joined(separator: "; ") }
        if !notes.isEmpty { s += "\nNotes: \(notes.truncated(to: 1200))" }
        return s
    }
}

struct RetrievedMemory: Sendable {
    var item: MemoryItem
    var score: Float
}

/// Persistent, user-controlled long-term memory with semantic retrieval.
/// Nothing is remembered implicitly: explicit "remember …" requests are stored; everything else is only *suggested*
/// and requires the user's approval.
@MainActor
final class MemoryStore: ObservableObject {
    @Published private(set) var items: [MemoryItem] = []
    @Published private(set) var projects: [Project] = []
    private var vectors: [UUID: [Float]] = [:]
    private let db = Database.shared

    init() { reload() }

    var active: [MemoryItem] { items.filter { $0.status == .active } }
    var suggestions: [MemoryItem] { items.filter { $0.status == .suggested } }

    func reload() {
        var list: [MemoryItem] = []
        var vecs: [UUID: [Float]] = [:]
        for row in db.query("SELECT * FROM memories ORDER BY updated DESC") {
            guard let id = row.uuid("id"), let content = row.sealedText("content") else { continue }
            let item = MemoryItem(id: id, kind: MemoryItem.Kind(rawValue: row.string("kind") ?? "") ?? .fact,
                                  content: content, projectID: row.uuid("project_id"), created: row.date("created"),
                                  updated: row.date("updated"),
                                  lastUsed: row.double("last_used").map { Date(timeIntervalSince1970: $0) },
                                  useCount: Int(row.int("use_count") ?? 0), importance: row.double("importance") ?? 0.5,
                                  pinned: (row.int("pinned") ?? 0) == 1,
                                  status: MemoryItem.Status(rawValue: row.string("status") ?? "") ?? .active,
                                  source: row.string("source") ?? "user")
            list.append(item)
            if let e = row.blob("embedding") { vecs[id] = Embedder.decode(e) }
        }
        items = list
        vectors = vecs
        projects = db.query("SELECT * FROM projects ORDER BY updated DESC").compactMap { row in
            row.blob("body").flatMap(Vault.open).flatMap { try? JSONDecoder().decode(Project.self, from: $0) }
        }
    }

    // MARK: Memories

    /// Adds a memory. If a near-duplicate exists (cosine ≥ 0.92 or identical text) it is refreshed instead.
    @discardableResult
    func add(_ content: String, kind: MemoryItem.Kind, projectID: UUID? = nil, status: MemoryItem.Status = .active,
             importance: Double = 0.6, source: String = "user") -> MemoryItem {
        let text = content.trimmed
        let vec = Embedder.shared.embed(text)
        if let dup = duplicate(of: text, vector: vec, projectID: projectID) {
            var updated = dup
            updated.updated = Date()
            if status == .active { updated.status = .active }
            updated.importance = max(dup.importance, importance)
            if text.count > dup.content.count && status == .active { updated.content = text }
            save(updated, vector: Embedder.shared.embed(updated.content))
            return updated
        }
        let item = MemoryItem(kind: kind, content: text, projectID: projectID, importance: importance, status: status, source: source)
        save(item, vector: vec)
        return item
    }

    func duplicate(of text: String, vector: [Float], projectID: UUID?) -> MemoryItem? {
        let lower = text.lowercased()
        var best: (MemoryItem, Float)?
        for item in items where item.projectID == projectID {
            if item.content.lowercased() == lower { return item }
            if let v = vectors[item.id] {
                let c = Embedder.cosine(v, vector)
                if c >= 0.92, c > (best?.1 ?? 0) { best = (item, c) }
            }
        }
        return best?.0
    }

    func save(_ item: MemoryItem, vector: [Float]? = nil) {
        var item = item
        item.updated = Date()
        let vec = vector ?? Embedder.shared.embed(item.content)
        db.run("""
            INSERT OR REPLACE INTO memories(id, kind, content, project_id, created, updated, last_used, use_count,
                importance, pinned, status, source, embedding) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(item.id.uuidString), .text(item.kind.rawValue), .blob(Vault.sealString(item.content)),
                  item.projectID.sql, .real(item.created.timeIntervalSince1970), .real(item.updated.timeIntervalSince1970),
                  item.lastUsed.map { .real($0.timeIntervalSince1970) } ?? .null, .int(Int64(item.useCount)),
                  .real(item.importance), .int(item.pinned ? 1 : 0), .text(item.status.rawValue), .text(item.source),
                  .blob(Embedder.encode(vec))])
        vectors[item.id] = vec
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.insert(item, at: 0) }
    }

    func delete(_ item: MemoryItem) {
        db.run("DELETE FROM memories WHERE id = ?", [.text(item.id.uuidString)])
        items.removeAll { $0.id == item.id }
        vectors[item.id] = nil
    }

    func approve(_ item: MemoryItem) {
        var i = item
        i.status = .active
        save(i)
    }

    func deleteAll() {
        db.run("DELETE FROM memories")
        items = []
        vectors = [:]
    }

    /// Hybrid retrieval: semantic similarity + keyword coverage + importance, with recency decay and pin boost.
    func retrieve(_ query: String, limit: Int, projectID: UUID?, minScore: Float = 0.32) -> [RetrievedMemory] {
        let q = Embedder.shared.embed(query)
        let now = Date()
        var scored: [RetrievedMemory] = []
        for item in active where item.projectID == nil || item.projectID == projectID {
            let sem = vectors[item.id].map { Embedder.cosine($0, q) } ?? 0
            let kw = Embedder.keywordScore(query: query, text: item.content)
            let age = now.timeIntervalSince(item.lastUsed ?? item.updated) / 86_400
            let recency = Float(0.85 + 0.15 * exp(-age / 90))
            var score = (0.62 * sem + 0.28 * kw + 0.10 * Float(item.importance)) * recency
            if item.pinned { score += 0.12 }
            if item.projectID != nil && item.projectID == projectID { score += 0.05 }
            scored.append(RetrievedMemory(item: item, score: score))
        }
        let top = scored.filter { $0.score >= minScore }.sorted { $0.score > $1.score }.prefix(limit)
        return Array(top)
    }

    /// Standing instructions and pinned memories apply to every request.
    func standingInstructions(projectID: UUID?) -> [MemoryItem] {
        active.filter { ($0.kind == .instruction || $0.pinned) && ($0.projectID == nil || $0.projectID == projectID) }
    }

    func markUsed(_ ids: [UUID]) {
        for id in ids {
            guard var item = items.first(where: { $0.id == id }) else { continue }
            item.lastUsed = Date()
            item.useCount += 1
            db.run("UPDATE memories SET last_used = ?, use_count = ? WHERE id = ?",
                   [.real(Date().timeIntervalSince1970), .int(Int64(item.useCount)), .text(id.uuidString)])
            if let i = items.firstIndex(where: { $0.id == id }) { items[i] = item }
        }
    }

    // MARK: Projects

    func saveProject(_ p: Project) {
        var p = p
        p.updated = Date()
        guard let data = try? JSONEncoder().encode(p) else { return }
        db.run("INSERT OR REPLACE INTO projects(id, name, created, updated, body) VALUES(?,?,?,?,?)",
               [.text(p.id.uuidString), .text(""), .real(p.created.timeIntervalSince1970),
                .real(p.updated.timeIntervalSince1970), .blob(Vault.seal(data))])
        if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p } else { projects.insert(p, at: 0) }
    }

    func deleteProject(_ p: Project) {
        db.run("DELETE FROM projects WHERE id = ?", [.text(p.id.uuidString)])
        db.run("DELETE FROM memories WHERE project_id = ?", [.text(p.id.uuidString)])
        projects.removeAll { $0.id == p.id }
        reload()
    }

    func project(_ id: UUID?) -> Project? { id.flatMap { pid in projects.first { $0.id == pid } } }

    // MARK: Export / import

    struct Backup: Codable {
        var exportedAt = Date()
        var memories: [MemoryItem]
        var projects: [Project]
        var conversations: [Conversation]
    }

    func exportBackup(conversations: [Conversation]) throws -> URL {
        let backup = Backup(memories: items, projects: projects, conversations: conversations)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(backup)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NEXUS-backup-\(Int(Date().timeIntervalSince1970)).json")
        try data.write(to: url, options: [.completeFileProtection])
        return url
    }

    func importBackup(from url: URL) throws -> (memories: Int, projects: Int, conversations: [Conversation]) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let backup = try dec.decode(Backup.self, from: Data(contentsOf: url))
        for m in backup.memories { save(m) }
        for p in backup.projects { saveProject(p) }
        return (backup.memories.count, backup.projects.count, backup.conversations)
    }
}

/// Detects explicit memory commands and proposes (never silently stores) candidate memories.
enum MemoryExtractor {
    enum Command {
        case remember(String, MemoryItem.Kind)
        case forget(String)
    }

    static func command(in text: String) -> Command? {
        let t = text.trimmed
        let lower = t.lowercased()
        let rememberPrefixes = ["please remember that ", "please remember ", "remember that ", "remember: ", "remember ",
                                "don't forget that ", "note that i ", "keep in mind that "]
        for p in rememberPrefixes where lower.hasPrefix(p) {
            var content = String(t.dropFirst(p.count)).trimmed
            if p == "note that i " { content = "I " + content }
            guard content.count > 3 else { return nil }
            return .remember(content, classify(content))
        }
        let forgetPrefixes = ["forget that ", "please forget ", "forget about ", "forget "]
        for p in forgetPrefixes where lower.hasPrefix(p) {
            let content = String(t.dropFirst(p.count)).trimmed
            guard content.count > 2 else { return nil }
            return .forget(content)
        }
        return nil
    }

    static func classify(_ s: String) -> MemoryItem.Kind {
        let l = s.lowercased()
        if l.contains("always") || l.contains("never") || l.hasPrefix("when ") || l.contains("respond") || l.contains("answer in") { return .instruction }
        if l.contains("prefer") || l.contains(" like ") || l.contains("favorite") || l.contains("favourite") || l.contains("don't like") { return .preference }
        if l.contains("decided") || l.contains("we will use") || l.contains("we chose") { return .decision }
        return .fact
    }

    /// Candidate personal facts/preferences in a user message (returned as suggestions for approval).
    static func suggestions(in text: String) -> [(String, MemoryItem.Kind)] {
        let triggers = ["my name is", "call me", "i am a ", "i'm a ", "i am an ", "i'm an ", "i work as", "i work at",
                        "i live in", "i prefer", "i'm allergic", "i am allergic", "i always", "i never", "my favorite",
                        "my favourite", "i'm vegetarian", "i'm vegan", "my birthday", "i use ", "i'm learning", "i am learning"]
        var out: [(String, MemoryItem.Kind)] = []
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).map(\.trimmed).filter { !$0.isEmpty }
        for s in sentences {
            let l = s.lowercased()
            guard s.count < 220, triggers.contains(where: { l.contains($0) }) else { continue }
            guard !l.hasSuffix("?") && !l.hasPrefix("what") && !l.hasPrefix("how") && !l.hasPrefix("can you") else { continue }
            let personal = s.replacingOccurrences(of: "^I ", with: "User ", options: .regularExpression)
                .replacingOccurrences(of: "^I'm ", with: "User is ", options: .regularExpression)
                .replacingOccurrences(of: "^My ", with: "User's ", options: .regularExpression)
            out.append((personal, classify(s)))
        }
        return Array(out.prefix(3))
    }
}
