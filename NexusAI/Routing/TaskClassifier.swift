import Foundation

/// Fast, deterministic request classification (no model call). Runs in microseconds so Instant mode pays nothing.
struct TaskProfile: Sendable, Equatable {
    var category: TaskCategory
    var complexity: Double          // 0 … 1
    var needsCurrentInfo: Bool
    var hasImages: Bool
    var hasDocuments: Bool
    var mathExpression: String?
    var wantsDateTime: Bool
    var unitConversion: Bool
    var wantsCode: Bool
    var codeLanguage: String?
    var isAmbiguous: Bool
    var signals: [String]
}

enum TaskClassifier {
    private static func has(_ text: String, _ words: [String]) -> Bool {
        words.contains { text.contains($0) }
    }

    static func classify(_ raw: String, hasImages: Bool = false, hasDocuments: Bool = false) -> TaskProfile {
        let text = raw.lowercased()
        var signals: [String] = []
        let words = Embedder.tokens(raw).count

        let codeWords = ["code", "function", "bug", "debug", "compile", "error:", "stack trace", "refactor", "swift", "python",
                         "javascript", "typescript", "java ", "kotlin", "rust", "golang", "c++", "sql", "regex", "api",
                         "unit test", "algorithm", "implement", "class ", "struct ", "html", "css", "react", "script",
                         "exception", "segfault", "null pointer", "git ", "dockerfile", "bash"]
        let codeFence = raw.contains("```") || raw.contains("func ") || raw.contains("def ") || raw.contains("=>") || raw.contains("{\n")
        let mathWords = ["calculate", "compute", "solve", "equation", "integral", "derivative", "probability", "percent",
                         "how much", "how many", "average", "sum of", "product of", "square root", "factorial", "interest",
                         "convert", "ratio", "math", "prove", "theorem"]
        let researchWords = ["research", "compare", "comparison", "pros and cons", "sources", "evidence", "study",
                             "studies", "history of", "overview of", "explain the difference", "analysis of", "report on", "review of"]
        let currentWords = ["today", "latest", "news", "current", "currently", "right now", "this week", "this year",
                            "recent", "price of", "stock", "weather", "score", "election", "release date", "2026", "2027", "who won"]
        let planWords = ["plan", "schedule", "itinerary", "roadmap", "strategy", "step by step", "steps to", "organize",
                         "break down", "project", "timeline", "checklist"]
        let creativeWords = ["write a", "poem", "story", "essay", "email", "letter", "rewrite", "rephrase", "tone",
                             "draft", "caption", "slogan", "lyrics", "blog"]
        let reasonWords = ["why", "reason", "logic", "puzzle", "riddle", "think through", "trade-off", "tradeoff",
                           "implications", "evaluate", "should i", "which is better", "argue", "assume", "if then", "deduce"]
        let quickPrefixes = ["hi", "hello", "hey", "thanks", "thank you", "ok", "good morning", "what is", "who is",
                             "define", "translate", "synonym", "spell"]

        let expr = Calculator.extractExpression(from: raw)
        let wantsDate = has(text, ["what day", "what time", "today's date", "what date", "days until", "days between", "weekday"])
        let units = text.range(of: #"\d\s*(km|mi|miles|kg|lb|lbs|°?[cf]\b|celsius|fahrenheit|ml|liters?|gallons?|feet|ft|inches|cm|mph|km/h)\s+(to|in|into)\s+"#,
                               options: .regularExpression) != nil

        var scores: [TaskCategory: Double] = [:]
        if hasImages { scores[.vision, default: 0] += 5; signals.append("image attached") }
        if hasDocuments { scores[.document, default: 0] += 4; signals.append("document attached") }
        if has(text, codeWords) || codeFence { scores[.coding, default: 0] += codeFence ? 4 : 2.5; signals.append("code terms") }
        if has(text, mathWords) || expr != nil || units { scores[.math, default: 0] += expr != nil ? 3.5 : 2; signals.append("math") }
        if has(text, researchWords) { scores[.research, default: 0] += 2.5; signals.append("research terms") }
        if has(text, planWords) { scores[.planning, default: 0] += 2; signals.append("planning") }
        if has(text, creativeWords) { scores[.creative, default: 0] += 2; signals.append("writing") }
        if has(text, reasonWords) { scores[.reasoning, default: 0] += 1.8; signals.append("reasoning") }
        let needsCurrent = has(text, currentWords)
        if needsCurrent { scores[.research, default: 0] += 1.5; signals.append("current info") }

        var category: TaskCategory
        if let best = scores.max(by: { $0.value < $1.value }), best.value >= 1.5 {
            category = best.key
        } else if words <= 8 && (quickPrefixes.contains { text.hasPrefix($0) } || words <= 4) {
            category = .quick
        } else {
            category = .chat
        }

        // Complexity: length, multiple questions, constraints, multi-step language, domain.
        var complexity = min(1, Double(words) / 120)
        let questionMarks = raw.filter { $0 == "?" }.count
        if questionMarks > 1 { complexity += 0.1 * Double(min(questionMarks, 4)) }
        if has(text, ["step by step", "in detail", "thorough", "comprehensive", "explain why", "prove", "design", "architecture",
                      "optimize", "multiple", "compare", "trade-off", "edge cases", "and then", "first,", "finally"]) {
            complexity += 0.25; signals.append("multi-step")
        }
        if [.coding, .research, .planning, .reasoning].contains(category) { complexity += 0.15 }
        if category == .quick { complexity = min(complexity, 0.15) }
        if hasDocuments || hasImages { complexity += 0.1 }
        complexity = min(1, max(0, complexity))

        var lang: String?
        for l in ["swift", "python", "javascript", "typescript", "kotlin", "rust", "go", "java", "c++", "c#", "sql", "bash", "ruby", "php"] {
            if text.contains(l) { lang = l; break }
        }
        let ambiguous = words <= 3 && category != .quick && !hasImages && !hasDocuments

        return TaskProfile(category: category, complexity: complexity, needsCurrentInfo: needsCurrent, hasImages: hasImages,
                           hasDocuments: hasDocuments, mathExpression: expr, wantsDateTime: wantsDate, unitConversion: units,
                           wantsCode: category == .coding, codeLanguage: lang, isAmbiguous: ambiguous, signals: signals)
    }
}
