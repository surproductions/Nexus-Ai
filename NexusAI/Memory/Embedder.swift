import Foundation
import NaturalLanguage
import Accelerate

/// On-device text embeddings for semantic memory and document retrieval.
/// Primary: Apple's NaturalLanguage sentence embedding (512-d, runs locally, no download).
/// Fallback: feature-hashed bag of words + character trigrams (deterministic, language-agnostic).
final class Embedder: @unchecked Sendable {
    static let shared = Embedder()

    private let lock = NSLock()
    private let sentence: NLEmbedding?
    let dimension: Int
    let method: String

    private init() {
        sentence = NLEmbedding.sentenceEmbedding(for: .english)
        if let s = sentence {
            dimension = s.dimension
            method = "Apple NLEmbedding (sentence, \(s.dimension)-d)"
        } else {
            dimension = 512
            method = "Hashed lexical embedding (512-d)"
        }
    }

    func embed(_ text: String) -> [Float] {
        let clean = String(text.trimmed.prefix(2000))
        guard !clean.isEmpty else { return [Float](repeating: 0, count: dimension) }
        if let sentence {
            lock.lock()
            let v = sentence.vector(for: clean)
            lock.unlock()
            if let v, v.count == dimension { return Self.normalize(v.map { Float($0) }) }
        }
        return hashed(clean)
    }

    private func hashed(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        let words = Self.tokens(text)
        for w in words {
            v[Self.bucket(w, dimension)] += 1
            let chars = Array(w)
            if chars.count > 3 {
                for i in 0...(chars.count - 3) {
                    v[Self.bucket(String(chars[i..<i + 3]), dimension)] += 0.35
                }
            }
        }
        return Self.normalize(v)
    }

    private static func bucket(_ s: String, _ n: Int) -> Int {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Int(h % UInt64(n))
    }

    static func normalize(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }

    static let stopwords: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "is", "are", "was",
        "were", "be", "it", "that", "this", "with", "as", "at", "by", "from", "i", "you", "me", "my", "your", "we", "our",
        "what", "how", "do", "does", "did", "can", "could", "would", "should", "about", "please", "tell", "into", "if", "so"]

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopwords.contains($0) }
    }

    /// Keyword overlap score in [0, 1] (query-term coverage).
    static func keywordScore(query: String, text: String) -> Float {
        let q = Set(tokens(query))
        guard !q.isEmpty else { return 0 }
        let t = Set(tokens(text))
        return Float(q.intersection(t).count) / Float(q.count)
    }

    static func encode(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

    static func decode(_ d: Data) -> [Float] {
        guard d.count % MemoryLayout<Float>.size == 0 else { return [] }
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
