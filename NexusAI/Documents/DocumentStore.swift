import Foundation
import PDFKit
import UniformTypeIdentifiers
import UIKit

struct DocumentRecord: Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var filename: String
    var kind: String
    var pages: Int
    var chars: Int
    var projectID: UUID?
    var created: Date
    var summary: String?

    var fileURL: URL { Paths.attachments.appendingPathComponent("docs/\(id.uuidString)-\(filename)") }
}

struct DocChunk: Sendable {
    var id: UUID
    var docID: UUID
    var index: Int
    var page: Int
    var text: String
    var vector: [Float]
}

struct ChunkHit: Sendable {
    var chunk: DocChunk
    var document: DocumentRecord
    var score: Float
}

/// Local document library: extraction (PDF text, OCR for scanned pages), chunking, embeddings and hybrid search.
@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var documents: [DocumentRecord] = []
    @Published private(set) var ingesting: [String: Double] = [:]
    private var chunkCache: [UUID: [DocChunk]] = [:]
    private let db = Database.shared

    static let supportedTypes: [UTType] = [.pdf, .plainText, .utf8PlainText, .rtf, .json, .commaSeparatedText,
                                           .sourceCode, .html, .xml, .image, UTType(filenameExtension: "md") ?? .plainText]

    init() { reload() }

    func reload() {
        documents = db.query("SELECT * FROM documents ORDER BY created DESC").compactMap { row in
            guard let id = row.uuid("id") else { return nil }
            return DocumentRecord(id: id, title: row.string("title") ?? "Document", filename: row.string("filename") ?? "",
                                  kind: row.string("kind") ?? "", pages: Int(row.int("pages") ?? 0),
                                  chars: Int(row.int("chars") ?? 0), projectID: row.uuid("project_id"),
                                  created: row.date("created"), summary: row.sealedText("summary"))
        }
    }

    func chunks(for docID: UUID) -> [DocChunk] {
        if let cached = chunkCache[docID] { return cached }
        let list = db.query("SELECT * FROM chunks WHERE doc_id = ? ORDER BY idx", [.text(docID.uuidString)]).compactMap { row -> DocChunk? in
            guard let id = row.uuid("id"), let text = row.sealedText("text") else { return nil }
            return DocChunk(id: id, docID: docID, index: Int(row.int("idx") ?? 0), page: Int(row.int("page") ?? 0),
                            text: text, vector: row.blob("embedding").map(Embedder.decode) ?? [])
        }
        chunkCache[docID] = list
        return list
    }

    func fullText(_ docID: UUID) -> String { chunks(for: docID).map(\.text).joined(separator: "\n") }

    /// Imports and indexes a file entirely on device.
    @discardableResult
    func ingest(url: URL, projectID: UUID? = nil) async throws -> DocumentRecord {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let filename = url.lastPathComponent
        ingesting[filename] = 0
        defer { ingesting[filename] = nil }

        let dir = Paths.attachments.appendingPathComponent("docs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stored = dir.appendingPathComponent("\(id.uuidString)-\(filename)")
        try FileManager.default.copyItem(at: url, to: stored)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: stored.path)

        let progressHandler: @Sendable (Double) -> Void = { p in
            Task { @MainActor [weak self] in self?.ingesting[filename] = p }
        }
        let extracted = try await Task.detached(priority: .userInitiated) {
            try DocumentExtractor.extract(stored, progress: progressHandler)
        }.value
        guard !extracted.pages.allSatisfy({ $0.trimmed.isEmpty }) else {
            try? FileManager.default.removeItem(at: stored)
            throw NexusError.generic("No text could be extracted from \(filename).")
        }

        let pieces = DocumentExtractor.chunk(pages: extracted.pages)
        let vectors = await Task.detached(priority: .userInitiated) {
            pieces.map { Embedder.shared.embed($0.text) }
        }.value
        let record = DocumentRecord(id: id, title: url.deletingPathExtension().lastPathComponent, filename: filename,
                                    kind: extracted.kind, pages: extracted.pages.count,
                                    chars: extracted.pages.reduce(0) { $0 + $1.count }, projectID: projectID,
                                    created: Date(), summary: nil)
        db.run("INSERT INTO documents(id, title, filename, kind, pages, chars, project_id, created, summary) VALUES(?,?,?,?,?,?,?,?,?)",
               [.text(id.uuidString), .text(record.title), .text(filename), .text(record.kind), .int(Int64(record.pages)),
                .int(Int64(record.chars)), projectID.sql, .real(Date().timeIntervalSince1970), .null])
        var cached: [DocChunk] = []
        for (i, piece) in pieces.enumerated() {
            let cid = UUID()
            db.run("INSERT INTO chunks(id, doc_id, idx, page, text, embedding) VALUES(?,?,?,?,?,?)",
                   [.text(cid.uuidString), .text(id.uuidString), .int(Int64(i)), .int(Int64(piece.page)),
                    .blob(Vault.sealString(piece.text)), .blob(Embedder.encode(vectors[i]))])
            cached.append(DocChunk(id: cid, docID: id, index: i, page: piece.page, text: piece.text, vector: vectors[i]))
        }
        chunkCache[id] = cached
        reload()
        return record
    }

    func setSummary(_ summary: String, for id: UUID) {
        db.run("UPDATE documents SET summary = ? WHERE id = ?", [.blob(Vault.sealString(summary)), .text(id.uuidString)])
        reload()
    }

    func delete(_ doc: DocumentRecord) {
        db.run("DELETE FROM chunks WHERE doc_id = ?", [.text(doc.id.uuidString)])
        db.run("DELETE FROM documents WHERE id = ?", [.text(doc.id.uuidString)])
        try? FileManager.default.removeItem(at: doc.fileURL)
        chunkCache[doc.id] = nil
        reload()
    }

    /// Hybrid semantic + keyword search across selected documents (or all).
    func search(_ query: String, in ids: [UUID]? = nil, limit: Int = 6) -> [ChunkHit] {
        let q = Embedder.shared.embed(query)
        let docs = documents.filter { ids == nil || ids!.contains($0.id) }
        var hits: [ChunkHit] = []
        for doc in docs {
            for c in chunks(for: doc.id) {
                let sem = c.vector.isEmpty ? 0 : Embedder.cosine(c.vector, q)
                let kw = Embedder.keywordScore(query: query, text: c.text)
                let exact: Float = query.count > 4 && c.text.localizedCaseInsensitiveContains(query) ? 0.25 : 0
                hits.append(ChunkHit(chunk: c, document: doc, score: 0.6 * sem + 0.4 * kw + exact))
            }
        }
        // Prefer diverse chunks: at most 3 per document.
        var perDoc: [UUID: Int] = [:]
        return hits.sorted { $0.score > $1.score }.filter { h in
            perDoc[h.document.id, default: 0] += 1
            return perDoc[h.document.id]! <= 3
        }.prefix(limit).map { $0 }
    }

    /// Exact phrase search for the in-document find UI.
    func find(_ phrase: String, in docID: UUID) -> [DocChunk] {
        chunks(for: docID).filter { $0.text.localizedCaseInsensitiveContains(phrase) }
    }
}

enum DocumentExtractor {
    struct Extracted { var kind: String; var pages: [String] }

    static func extract(_ url: URL, progress: @Sendable (Double) -> Void) throws -> Extracted {
        let type = UTType(filenameExtension: url.pathExtension.lowercased()) ?? .data
        if type.conforms(to: .pdf) {
            guard let pdf = PDFDocument(url: url) else { throw NexusError.generic("Unreadable PDF") }
            if pdf.isLocked { throw NexusError.generic("This PDF is password-protected.") }
            var pages: [String] = []
            for i in 0..<pdf.pageCount {
                guard let page = pdf.page(at: i) else { pages.append(""); continue }
                var text = page.string ?? ""
                if text.trimmed.count < 25 {
                    // Scanned page: OCR a rendered image of it.
                    let bounds = page.bounds(for: .mediaBox)
                    let scale = min(2.5, 2200 / max(bounds.width, bounds.height))
                    let img = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                    if let cg = img.cgImage { text = VisionAnalyzer.ocr(cg) }
                }
                pages.append(text)
                progress(Double(i + 1) / Double(max(1, pdf.pageCount)))
            }
            return Extracted(kind: "PDF", pages: pages)
        }
        if type.conforms(to: .image) {
            guard let cg = VisionAnalyzer.loadImage(at: url) else { throw NexusError.generic("Unreadable image") }
            return Extracted(kind: "Image (OCR)", pages: [VisionAnalyzer.ocr(cg)])
        }
        if type.conforms(to: .rtf) {
            let attr = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            return Extracted(kind: "RTF", pages: paginate(attr.string))
        }
        if type.conforms(to: .html) {
            let html = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return Extracted(kind: "HTML", pages: paginate(HTMLText.strip(html)))
        }
        var enc = String.Encoding.utf8
        let text = (try? String(contentsOf: url, usedEncoding: &enc)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
        guard !text.isEmpty else { throw NexusError.generic("Unsupported or empty file: \(url.lastPathComponent)") }
        return Extracted(kind: url.pathExtension.uppercased(), pages: paginate(text))
    }

    /// Splits long plain text into ~3000-character pseudo-pages so citations stay meaningful.
    static func paginate(_ text: String) -> [String] {
        var pages: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if current.count + line.count > 3000 && !current.isEmpty { pages.append(current); current = "" }
            current += line + "\n"
        }
        if !current.trimmed.isEmpty { pages.append(current) }
        return pages
    }

    struct Piece { var page: Int; var text: String }

    /// Paragraph-aware chunking (~900 chars, 150-char overlap).
    static func chunk(pages: [String], size: Int = 900, overlap: Int = 150) -> [Piece] {
        var out: [Piece] = []
        for (pi, page) in pages.enumerated() {
            let paragraphs = page.components(separatedBy: "\n\n").map(\.trimmed).filter { !$0.isEmpty }
            var buf = ""
            func flush() {
                let t = buf.trimmed
                if t.count > 20 { out.append(Piece(page: pi + 1, text: t)) }
                buf = String(buf.suffix(overlap))
            }
            for p in paragraphs {
                if p.count > size {
                    var rest = Substring(p)
                    while !rest.isEmpty {
                        let take = rest.prefix(size)
                        buf += String(take)
                        flush()
                        rest = rest.dropFirst(take.count)
                    }
                } else {
                    if buf.count + p.count > size { flush() }
                    buf += p + "\n\n"
                }
            }
            if buf.trimmed.count > overlap || out.last?.page != pi + 1 { flush() }
        }
        return out
    }
}

enum HTMLText {
    static func strip(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "form"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>|</h[1-6]>|</tr>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&apos;": "'"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "&#\\d+;", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return s.trimmed
    }
}
