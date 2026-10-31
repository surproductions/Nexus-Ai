import Foundation

/// Specialised agents. Each has one responsibility, a focused system prompt and a restricted tool set.
/// Agents share condensed "working notes" rather than full conversation histories.
enum AgentRole: String, CaseIterable, Codable, Sendable {
    case orchestrator, reasoning, coding, research, vision, document, verification

    var displayName: String {
        switch self {
        case .orchestrator: return "Orchestrator"
        case .reasoning: return "Reasoning agent"
        case .coding: return "Coding agent"
        case .research: return "Research agent"
        case .vision: return "Vision agent"
        case .document: return "Document agent"
        case .verification: return "Verification agent"
        }
    }

    var symbol: String {
        switch self {
        case .orchestrator: return "point.3.connected.trianglepath.dotted"
        case .reasoning: return "function"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .research: return "globe"
        case .vision: return "eye"
        case .document: return "doc.text.magnifyingglass"
        case .verification: return "checkmark.shield"
        }
    }

    var category: TaskCategory {
        switch self {
        case .orchestrator: return .planning
        case .reasoning: return .reasoning
        case .coding: return .coding
        case .research: return .research
        case .vision: return .vision
        case .document: return .document
        case .verification: return .reasoning
        }
    }

    var toolNames: [String] {
        switch self {
        case .orchestrator: return []
        case .reasoning: return ["calculator", "convert_units", "date_time", "search_memory"]
        case .coding: return ["javascript", "calculator"]
        case .research: return ["web_search", "fetch_page", "search_documents", "search_memory"]
        case .vision: return []
        case .document: return ["search_documents", "calculator"]
        case .verification: return ["calculator", "javascript"]
        }
    }

    var instructions: String {
        switch self {
        case .orchestrator:
            return """
            You are the planning component of an assistant. Decompose the user's request into 2–4 concrete sub-tasks, each \
            assigned to one agent: reasoning (logic, math, analysis), coding (write/debug/review code), research (find and \
            synthesise information), document (answer from the user's documents), vision (interpret attached images). \
            Output ONLY lines in the form:
            - [agent] sub-task description
            If the request is simple, output a single line. Do not answer the request yourself.
            """
        case .reasoning:
            return "You are a careful reasoning specialist. Work step by step, state assumptions, check each step, and use the calculator for any non-trivial arithmetic. End with a clearly marked conclusion."
        case .coding:
            return "You are a senior software engineer. Write correct, idiomatic, well-structured code with brief explanations. Handle edge cases, prefer clarity, and include a minimal usage example or test when helpful. Put code in fenced blocks with a language tag."
        case .research:
            return "You are a research specialist. Gather relevant facts, prefer primary and recent sources, note disagreements, and cite sources inline as [n] using the numbered source list. Never invent sources or facts; say clearly when information is missing."
        case .vision:
            return "You are a vision specialist. Describe what is actually visible, read text exactly, and separate observation from inference. If something is unclear, say so."
        case .document:
            return "You answer strictly from the provided document excerpts and cite them as (Document, p. N). If the excerpts do not contain the answer, say so instead of guessing."
        case .verification:
            return """
            You are an independent verifier. Check the draft answer against the request and the working notes. Look for: \
            calculation errors, logical errors, factual claims not supported by the notes or sources, missed parts of the \
            request, and code bugs. Reply with exactly one first line, either "VERDICT: PASS" or "VERDICT: REVISE", then up \
            to 5 short bullet points listing concrete problems (none for PASS).
            """
        }
    }

    static func parse(_ s: String) -> AgentRole? {
        switch s.lowercased().trimmed {
        case "reasoning", "reason", "math", "analysis", "logic": return .reasoning
        case "coding", "code", "programming", "developer": return .coding
        case "research", "researcher", "search", "web": return .research
        case "vision", "image", "visual": return .vision
        case "document", "documents", "doc", "docs": return .document
        case "verification", "verify", "verifier": return .verification
        default: return nil
        }
    }
}

struct PlanStep: Sendable {
    var agent: AgentRole
    var task: String
}

enum PlanParser {
    static func parse(_ text: String, maxSteps: Int = 4) -> [PlanStep] {
        let re = try? NSRegularExpression(pattern: #"^\s*(?:[-*•]|\d+[.)])?\s*\[([A-Za-z ]+)\]\s*[:\-–]?\s*(.+)$"#)
        var steps: [PlanStep] = []
        for line in text.components(separatedBy: "\n") {
            let l = line.trimmed
            guard let re, let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
                  let r1 = Range(m.range(at: 1), in: l), let r2 = Range(m.range(at: 2), in: l),
                  let role = AgentRole.parse(String(l[r1])), role != .verification, role != .orchestrator else { continue }
            steps.append(PlanStep(agent: role, task: String(l[r2]).trimmed))
            if steps.count >= maxSteps { break }
        }
        return steps
    }
}

/// Explicit resource limits per mode. Prevents runaway self-reflection loops and unbounded agent calls.
struct Budget: Sendable {
    var maxModelCalls: Int
    var maxToolCalls: Int
    var maxTokensPerCall: Int
    var deadline: Date
    var modelCalls = 0
    var toolCalls = 0

    static func `for`(_ mode: IntelligenceMode) -> Budget {
        switch mode {
        case .instant: return Budget(maxModelCalls: 1, maxToolCalls: 0, maxTokensPerCall: 768, deadline: Date().addingTimeInterval(60))
        case .thinking: return Budget(maxModelCalls: 5, maxToolCalls: 3, maxTokensPerCall: 2048, deadline: Date().addingTimeInterval(180))
        case .max: return Budget(maxModelCalls: 10, maxToolCalls: 8, maxTokensPerCall: 3072, deadline: Date().addingTimeInterval(420))
        }
    }

    var expired: Bool { Date() > deadline }
    var canCallModel: Bool { modelCalls < maxModelCalls && !expired }
    var canCallTool: Bool { toolCalls < maxToolCalls && !expired }
    var secondsLeft: Int { max(0, Int(deadline.timeIntervalSinceNow)) }
}
