import Foundation

var failures = 0
var passes = 0

func check(_ cond: Bool, _ name: String, file: String = #file, line: Int = #line) {
    if cond { passes += 1 } else { failures += 1; print("FAIL [\(line)]: \(name)") }
}

func approx(_ a: Double?, _ b: Double, _ eps: Double = 1e-9) -> Bool { a.map { abs($0 - b) <= eps } ?? false }

// MARK: Calculator
let calcCases: [(String, Double)] = [
    ("2+3*4", 14), ("(2+3)*4", 20), ("2^10", 1024), ("-3^2", -9), ("17% of 2,340", 397.8),
    ("sqrt(16)+ln(e)", 5), ("5!", 120), ("10/4", 2.5), ("2(3+4)", 14), ("ncr(5,2)", 10),
    ("gcd(12,18)", 6), ("lcm(4,6)", 12), ("1e3+1", 1001), ("2 × 3 ÷ 4", 1.5), ("round(3.14159, 2)", 3.14),
    ("10 % 3", 1), ("2^3^2", 512), ("abs(-7)", 7), ("pi*2", 2 * Double.pi), ("log(1000)", 3),
]
for (expr, expected) in calcCases {
    check(approx(try? Calculator.evaluate(expr), expected, 1e-9), "Calculator \(expr) = \(expected) (got \(String(describing: try? Calculator.evaluate(expr))))")
}
check((try? Calculator.evaluate("1/0")) == nil, "Division by zero throws")
check((try? Calculator.evaluate("2+")) == nil, "Incomplete expression throws")
check((try? Calculator.evaluate("foo(2)")) == nil, "Unknown function throws")
check(Calculator.format(397.8) == "397.8", "Format decimal")
check(Calculator.format(20100) == "20100", "Format integer")
let extracted = Calculator.extractExpression(from: "What is 17% of 2,340?")
check(extracted != nil && approx(try? Calculator.evaluate(extracted!), 397.8), "Extract percentage expression (got \(extracted ?? "nil"))")
let extracted2 = Calculator.extractExpression(from: "How much is 12 * 7 apples?")
check(extracted2 != nil && approx(try? Calculator.evaluate(extracted2!), 84), "Extract product (got \(extracted2 ?? "nil"))")
check(Calculator.extractExpression(from: "Tell me about the year 2026") == nil, "No expression in plain text")

// MARK: Stream parser
func run(_ format: PromptFormat, thinking: Bool, _ chunks: [String], stops: [String] = []) -> (String, String) {
    var p = OutputStreamParser(format: format, thinkingEnabled: thinking, extraStops: stops)
    var text = "", think = ""
    for c in chunks {
        for e in p.feed(c) { if case .text(let t) = e { text += t } else if case .thinking(let t) = e { think += t } }
    }
    for e in p.finish() { if case .text(let t) = e { text += t } else if case .thinking(let t) = e { think += t } }
    return (text, think)
}
var r = run(.qwen35, thinking: true, ["Let me th", "ink</th", "ink>\n\nThe answer is 4<|im_end|>junk"])
check(r.0 == "The answer is 4", "Qwen thinking split marker + stop in same chunk (text='\(r.0)')")
check(r.1 == "Let me think", "Qwen thinking content (think='\(r.1)')")
r = run(.qwen35, thinking: false, ["Hello", " world<|im_", "end|>ignored"])
check(r.0 == "Hello world" && r.1.isEmpty, "Qwen no-think stop split across chunks (text='\(r.0)')")
r = run(.gemma4, thinking: true, ["<|channel>thought\nhmm", "m<channel|>Hi there", "<turn|>"])
check(r.0 == "Hi there" && r.1.contains("hmmm"), "Gemma thinking channel (text='\(r.0)', think='\(r.1)')")
r = run(.llama3, thinking: false, ["Sure", "! <tool_call>{\"name\":\"calculator\"}", "</tool_call>"], stops: ["</tool_call>"])
check(r.0 == "Sure! <tool_call>{\"name\":\"calculator\"}", "Tool-call stop sequence (text='\(r.0)')")
r = run(.phi4, thinking: false, ["a<", "b"])
check(r.0 == "a<b", "Partial marker hold-back released (text='\(r.0)')")

// MARK: UTF-8 accumulator
var acc = UTF8Accumulator()
check(acc.append([0xC3]) == "", "Hold incomplete 2-byte sequence")
check(acc.append([0xA9]) == "é", "Complete 2-byte sequence")
let emoji = Array("🧠".utf8)
check(acc.append(Array(emoji[0..<2])) == "", "Hold incomplete 4-byte sequence")
check(acc.append(Array(emoji[2..<4]) + Array("ok".utf8)) == "🧠ok", "Complete 4-byte sequence")

// MARK: Prompt formats
let msgs = [PromptMessage(role: .user, content: "Hi")]
let q = PromptFormat.qwen35.render(system: "S", messages: msgs, thinking: true, imageMarker: "<m>")!
check(q.hasSuffix("<|im_start|>assistant\n<think>\n"), "Qwen thinking generation prompt")
let qn = PromptFormat.qwen35.render(system: "S", messages: msgs, thinking: false, imageMarker: "<m>")!
check(qn.hasSuffix("<think>\n\n</think>\n\n"), "Qwen non-thinking generation prompt")
let g = PromptFormat.gemma4.render(system: "S", messages: [PromptMessage(role: .assistant, content: "A"), PromptMessage(role: .user, content: "B")], thinking: false, imageMarker: "<m>")!
check(g.contains("<|turn>model\nA<turn|>") && g.hasSuffix("<|turn>model\n<|channel>thought\n<channel|>"), "Gemma 4 roles and non-thinking prefill")
let l = PromptFormat.llama3.render(system: "S", messages: msgs, thinking: false, imageMarker: "<m>")!
check(l.hasSuffix("<|start_header_id|>assistant<|end_header_id|>\n\n"), "Llama 3 generation prompt")
check(PromptFormat.auto.render(system: "", messages: msgs, thinking: false, imageMarker: "") == nil, "Auto format defers to embedded template")

// MARK: Task classifier
check(TaskClassifier.classify("Write a Swift function to reverse a linked list").category == .coding, "Classify coding")
let mathP = TaskClassifier.classify("What is 17% of 2340?")
check(mathP.category == .math && mathP.mathExpression != nil, "Classify math with expression")
check(TaskClassifier.classify("hi").category == .quick, "Classify greeting as quick")
check(TaskClassifier.classify("What's the latest news on the election?").needsCurrentInfo, "Detect current-info need")
check(TaskClassifier.classify("Describe this", hasImages: true).category == .vision, "Classify image request")
check(TaskClassifier.classify("Convert 72 fahrenheit to celsius").unitConversion, "Detect unit conversion")
check(TaskClassifier.classify("Compare the pros and cons of solar vs wind energy in detail, step by step").complexity > 0.4, "Complex research request")

// MARK: Plan parser
let plan = PlanParser.parse("- [coding] write the parser\n- [research] find the RFC\n1. [Reasoning] check edge cases\nignored line\n- [verification] nope")
check(plan.count == 3 && plan[0].agent == .coding && plan[2].agent == .reasoning, "Parse plan lines (got \(plan.map { $0.agent.rawValue }))")

// MARK: Registry integrity
let ids = ModelRegistry.catalog.map(\.id)
check(Set(ids).count == ids.count, "Unique model IDs")
for e in ModelRegistry.catalog {
    check(e.file.sha256?.count == 64 && e.file.sha256!.allSatisfy(\.isHexDigit), "\(e.id) has SHA-256")
    check(e.file.sizeBytes > 100_000_000, "\(e.id) has a size")
    check(e.file.url.host == "huggingface.co" && e.file.url.path.contains(e.sourceRepo), "\(e.id) URL matches repo")
    if let p = e.visionProjector { check(p.sha256?.count == 64, "\(e.id) projector SHA-256") }
    check(e.estimatedMemory(context: 4096, withVision: false) > UInt64(e.file.sizeBytes), "\(e.id) memory estimate exceeds weights")
}

// MARK: Embedder
let a = Embedder.shared.embed("The cat sat on the mat")
let b = Embedder.shared.embed("A cat was sitting on a mat")
let c = Embedder.shared.embed("Quarterly revenue grew by twelve percent")
check(a.count == Embedder.shared.dimension, "Embedding dimension")
check(Embedder.cosine(a, b) > Embedder.cosine(a, c), "Semantic similarity ordering (\(Embedder.cosine(a, b)) vs \(Embedder.cosine(a, c)))")
check(abs(Embedder.cosine(a, a) - 1) < 1e-3, "Self-similarity ≈ 1")
check(Embedder.decode(Embedder.encode(a)) == a, "Embedding round-trip encoding")

print("Logic tests: \(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
