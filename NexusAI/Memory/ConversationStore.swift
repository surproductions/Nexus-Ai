import Foundation

/// Encrypted conversation history.
@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var summaries: [ConversationSummary] = []
    private let db = Database.shared

    private struct Header: Codable { var t: String; var p: String }

    init() { reload() }

    func reload() {
        summaries = db.query("SELECT id, updated, project_id, preview FROM conversations ORDER BY updated DESC").compactMap { row in
            guard let id = row.uuid("id") else { return nil }
            let header = row.blob("preview").flatMap(Vault.open).flatMap { try? JSONDecoder().decode(Header.self, from: $0) }
            return ConversationSummary(id: id, title: header?.t ?? "Conversation", updatedAt: row.date("updated"),
                                       preview: header?.p ?? "", projectID: row.uuid("project_id"))
        }
    }

    func load(_ id: UUID) -> Conversation? {
        guard let row = db.query("SELECT body FROM conversations WHERE id = ?", [.text(id.uuidString)]).first,
              let data = row.blob("body").flatMap(Vault.open) else { return nil }
        return try? JSONDecoder().decode(Conversation.self, from: data)
    }

    func save(_ c: Conversation) {
        guard !c.messages.isEmpty, let body = try? JSONEncoder().encode(c) else { return }
        let preview = c.messages.last(where: { $0.role != .system })?.content.truncated(to: 140) ?? ""
        let header = (try? JSONEncoder().encode(Header(t: c.title, p: preview))) ?? Data()
        db.run("INSERT OR REPLACE INTO conversations(id, title, updated, project_id, preview, body) VALUES(?,?,?,?,?,?)",
               [.text(c.id.uuidString), .text(""), .real(c.updatedAt.timeIntervalSince1970), c.projectID.sql,
                .blob(Vault.seal(header)), .blob(Vault.seal(body))])
        reload()
    }

    func delete(_ id: UUID) {
        db.run("DELETE FROM conversations WHERE id = ?", [.text(id.uuidString)])
        reload()
    }

    func deleteAll() {
        db.run("DELETE FROM conversations")
        reload()
    }

    func all() -> [Conversation] { summaries.compactMap { load($0.id) } }

    /// Keyword search over decrypted conversations (performed locally, in memory).
    func search(_ query: String) -> [ConversationSummary] {
        let q = query.lowercased()
        guard !q.isEmpty else { return summaries }
        return summaries.filter { s in
            if s.title.lowercased().contains(q) || s.preview.lowercased().contains(q) { return true }
            return load(s.id)?.messages.contains { $0.content.lowercased().contains(q) } ?? false
        }
    }
}
