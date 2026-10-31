import Foundation
import UIKit

/// Reproducible evaluation suite. Every case has a deterministic, automatic grader; no LLM-as-judge.
struct EvalCase: Identifiable, Sendable {
    enum Group: String, Codable, CaseIterable, Sendable {
        case reasoning = "Reasoning", coding = "Coding", general = "General", multimodal = "Multimodal"
    }
    enum Grader: Sendable {
        case numeric(Double, tolerance: Double)
        case containsAll([String])
        case containsAny([String])
        case javascript(tests: String)
        case jsonKeys([String: String])
        case bullets(Int, mustContain: [String])
        case lowercase(mustContain: String)
        case maxWords(Int, mustContainAny: [String])
        case uncertainty
        case asksClarification
        case regexCount(String, atLeast: Int)
    }
    enum Media: Sendable { case none, invoiceScreenshot, redCircle }

    var id: String
    var group: Group
    var category: TaskCategory
    var title: String
    var turns: [String]          // previous user turns (context retention); the last element is the graded prompt
    var grader: Grader
    var media: Media = .none
    var measures: String          // what this case tests (shown in the dashboard)

    var prompt: String { turns.last ?? "" }
}

enum EvalSuite {
    static let version = "nexus-eval-1.0"

    static let cases: [EvalCase] = [
        // Reasoning & math
        EvalCase(id: "r1", group: .reasoning, category: .math, title: "Time arithmetic",
                 turns: ["A train leaves at 14:35 and arrives at 18:10 the same day. How long is the journey in minutes? Answer with just the number."],
                 grader: .numeric(215, tolerance: 0), measures: "Multi-step arithmetic"),
        EvalCase(id: "r2", group: .reasoning, category: .math, title: "Unit pricing",
                 turns: ["If 3 pencils cost $1.35, how much do 11 pencils cost in dollars?"],
                 grader: .numeric(4.95, tolerance: 0.001), measures: "Proportional reasoning"),
        EvalCase(id: "r3", group: .reasoning, category: .math, title: "Percentage",
                 turns: ["What is 17% of 2,340?"], grader: .numeric(397.8, tolerance: 0.001), measures: "Tool use (calculator)"),
        EvalCase(id: "r4", group: .reasoning, category: .math, title: "Linear equation",
                 turns: ["Solve for x: 3x + 7 = 46. Give only the value of x."], grader: .numeric(13, tolerance: 0), measures: "Algebra"),
        EvalCase(id: "r5", group: .reasoning, category: .math, title: "Geometry word problem",
                 turns: ["A rectangle has a perimeter of 54 cm and its length is twice its width. What is its area in square centimetres?"],
                 grader: .numeric(162, tolerance: 0), measures: "Multi-step word problem"),
        EvalCase(id: "r6", group: .reasoning, category: .reasoning, title: "Ordering logic",
                 turns: ["Alice is older than Bob. Bob is older than Carol. Dave is younger than Carol. Who is the youngest? Answer with one name."],
                 grader: .containsAll(["dave"]), measures: "Transitive logic"),
        EvalCase(id: "r7", group: .reasoning, category: .math, title: "Counting primes",
                 turns: ["How many prime numbers are there between 1 and 50?"], grader: .numeric(15, tolerance: 0), measures: "Enumeration"),
        EvalCase(id: "r8", group: .reasoning, category: .math, title: "Series sum",
                 turns: ["What is the sum of all integers from 1 to 200?"], grader: .numeric(20100, tolerance: 0), measures: "Formula recall"),
        EvalCase(id: "r9", group: .reasoning, category: .planning, title: "Schedule planning",
                 turns: ["I have meetings at 9:00 (1 hour), 11:30 (30 minutes) and 15:00 (45 minutes). Between 9:00 and 17:00, what is my longest uninterrupted free block, in minutes?"],
                 grader: .numeric(180, tolerance: 0), measures: "Planning over constraints"),
        EvalCase(id: "r10", group: .reasoning, category: .reasoning, title: "Ambiguous instruction",
                 turns: ["Book it."], grader: .asksClarification, measures: "Handles ambiguity by asking"),

        // Coding (graded by executing tests in a JavaScript sandbox)
        EvalCase(id: "c1", group: .coding, category: .coding, title: "Palindrome function",
                 turns: ["Write a JavaScript function isPalindrome(s) that returns true if the string is a palindrome, ignoring case and non-alphanumeric characters. Reply with only the code."],
                 grader: .javascript(tests: #"isPalindrome("A man, a plan, a canal: Panama") === true && isPalindrome("race a car") === false && isPalindrome("") === true"#),
                 measures: "Code generation"),
        EvalCase(id: "c2", group: .coding, category: .coding, title: "FizzBuzz array",
                 turns: ["Write a JavaScript function fizzbuzz(n) that returns an array of strings for 1..n using the standard FizzBuzz rules. Reply with only the code."],
                 grader: .javascript(tests: #"JSON.stringify(fizzbuzz(15)) === '["1","2","Fizz","4","Buzz","Fizz","7","8","Fizz","Buzz","11","Fizz","13","14","FizzBuzz"]'"#),
                 measures: "Code generation"),
        EvalCase(id: "c3", group: .coding, category: .coding, title: "Debugging",
                 turns: ["This JavaScript function should return the maximum of a non-empty array but has bugs. Fix it and reply with only the corrected function.\n```js\nfunction maxOf(arr) {\n  let m = 0;\n  for (let i = 1; i < arr.length; i++) { if (arr[i] > m) m = arr[i]; }\n  return m;\n}\n```"],
                 grader: .javascript(tests: "maxOf([-5,-2,-9]) === -2 && maxOf([3,8,1]) === 8 && maxOf([7]) === 7"),
                 measures: "Debugging"),
        EvalCase(id: "c4", group: .coding, category: .coding, title: "Numeric sort pitfall",
                 turns: ["Write a JavaScript function uniqueSorted(arr) that returns the unique numbers of arr sorted in ascending numeric order. Reply with only the code."],
                 grader: .javascript(tests: #"JSON.stringify(uniqueSorted([3,1,3,2,1])) === "[1,2,3]" && JSON.stringify(uniqueSorted([10,2,33])) === "[2,10,33]""#),
                 measures: "Correctness on edge cases"),
        EvalCase(id: "c5", group: .coding, category: .coding, title: "Test creation",
                 turns: ["Write at least three JavaScript test assertions using console.assert for a function add(a, b) that adds two numbers."],
                 grader: .regexCount("console\\.assert\\s*\\(", atLeast: 3), measures: "Test creation"),
        EvalCase(id: "c6", group: .coding, category: .coding, title: "Code review",
                 turns: ["Review this Node.js line and name the security vulnerability in one sentence:\ndb.query(\"SELECT * FROM users WHERE name = '\" + req.query.name + \"'\")"],
                 grader: .containsAny(["sql injection", "sql-injection", "injection"]), measures: "Code review"),

        // General intelligence & instruction following
        EvalCase(id: "g1", group: .general, category: .chat, title: "Exact list format",
                 turns: ["List exactly three primary colors of light as a bulleted list, and nothing else."],
                 grader: .bullets(3, mustContain: ["red", "green", "blue"]), measures: "Instruction following"),
        EvalCase(id: "g2", group: .general, category: .chat, title: "Lowercase constraint",
                 turns: ["Reply using only lowercase letters: what is the capital of France?"],
                 grader: .lowercase(mustContain: "paris"), measures: "Instruction following"),
        EvalCase(id: "g3", group: .general, category: .chat, title: "Structured output",
                 turns: ["Return a JSON object with keys \"name\" and \"age\" for a person named Ada who is 36. Output only the JSON."],
                 grader: .jsonKeys(["name": "Ada", "age": "36"]), measures: "Structured output"),
        EvalCase(id: "g4", group: .general, category: .creative, title: "Length limit",
                 turns: ["Explain photosynthesis in no more than 40 words."],
                 grader: .maxWords(40, mustContainAny: ["light", "sun"]), measures: "Instruction following"),
        EvalCase(id: "g5", group: .general, category: .quick, title: "Knowledge: chemistry",
                 turns: ["What is the chemical symbol for gold?"], grader: .containsAll(["au"]), measures: "Knowledge"),
        EvalCase(id: "g6", group: .general, category: .quick, title: "Knowledge: literature",
                 turns: ["Who wrote the novel Pride and Prejudice?"], grader: .containsAll(["austen"]), measures: "Knowledge"),
        EvalCase(id: "g7", group: .general, category: .chat, title: "Complex explanation",
                 turns: ["Explain why the sky is blue."], grader: .containsAny(["rayleigh", "scatter"]), measures: "Explanation quality"),
        EvalCase(id: "g8", group: .general, category: .chat, title: "Context retention",
                 turns: ["My project codename is BLUEHERON and it launches on March 3rd. Just acknowledge.",
                         "What is my project codename and when does it launch?"],
                 grader: .containsAll(["blueheron", "march"]), measures: "Context retention across turns"),
        EvalCase(id: "g9", group: .general, category: .research, title: "Hallucination probe (fictional book)",
                 turns: ["Summarize the plot of the 2019 Nobel Prize–winning novel “The Glass Orchard of Velmira” by Tobias Krenn."],
                 grader: .uncertainty, measures: "Refuses to invent facts"),
        EvalCase(id: "g10", group: .general, category: .research, title: "Hallucination probe (fictional treaty)",
                 turns: ["What did the 1987 Treaty of Lisbonne between Canada and Mongolia establish?"],
                 grader: .uncertainty, measures: "Refuses to invent facts"),

        // Multimodal
        EvalCase(id: "m1", group: .multimodal, category: .vision, title: "Screenshot reading",
                 turns: ["What is the total amount on this invoice screenshot?"], grader: .containsAll(["86.20"]),
                 media: .invoiceScreenshot, measures: "Screenshot interpretation / OCR"),
        EvalCase(id: "m2", group: .multimodal, category: .vision, title: "Visual question",
                 turns: ["What shape is shown in this image, and what color is it?"], grader: .containsAll(["red", "circle"]),
                 media: .redCircle, measures: "Image understanding (needs a vision model)"),
        EvalCase(id: "m3", group: .multimodal, category: .document, title: "Document question",
                 turns: ["Here is a policy document:\n<document>\nPolicy 12.4 — Vacation carry-over. Employees may carry over at most 5 unused vacation days into the next calendar year. Carried-over days expire on March 31. Requests must be approved by a manager.\n</document>\nAccording to the document, how many vacation days can be carried over, and when do they expire?"],
                 grader: .containsAll(["5", "march 31"]), measures: "Document understanding"),
    ]

    static let uncertaintyPhrases = ["not aware", "no information", "not familiar", "doesn't exist", "does not exist",
        "couldn't find", "could not find", "fictional", "fictitious", "not sure", "unable to find", "no record", "don't have",
        "do not have", "not a real", "no such", "cannot find", "can't find", "unable to verify", "not able to verify",
        "no known", "i'm not able", "cannot confirm", "can't confirm", "no evidence", "doesn't appear", "does not appear",
        "not aware of", "made up", "not exist", "unknown to me", "may not exist", "might not exist", "no reliable"]

    // MARK: Grading

    static func grade(_ c: EvalCase, output raw: String) -> (Bool, String) {
        let out = raw.trimmed
        let lower = out.lowercased()
        switch c.grader {
        case let .numeric(expected, tol):
            let nums = numbers(in: out)
            let ok = nums.contains { abs($0 - expected) <= max(tol, 1e-9) }
            return (ok, ok ? "Found \(Calculator.format(expected))" : "Expected \(Calculator.format(expected)); found \(nums.prefix(5).map(Calculator.format))")
        case .containsAll(let words):
            let missing = words.filter { !lower.contains($0.lowercased()) }
            return (missing.isEmpty, missing.isEmpty ? "All required terms present" : "Missing: \(missing.joined(separator: ", "))")
        case .containsAny(let words):
            let ok = words.contains { lower.contains($0.lowercased()) }
            return (ok, ok ? "Required concept present" : "None of: \(words.joined(separator: ", "))")
        case .javascript(let tests):
            let code = CodeBlocks.extract(out).first(where: { ["", "js", "javascript"].contains($0.language) })?.code ?? out
            let result = JavaScriptSandbox.evaluate(code + "\n;(" + tests + ")", timeout: 3)
            if let e = result.error { return (false, "Runtime/syntax error: \(e.truncated(to: 120))") }
            return (result.value == "true", "Tests returned \(result.value ?? "nil")")
        case .jsonKeys(let expected):
            let candidate = CodeBlocks.extract(out).first?.code ?? out
            guard let start = candidate.firstIndex(of: "{"), let end = candidate.lastIndex(of: "}"),
                  let data = String(candidate[start...end]).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (false, "No valid JSON object") }
            for (k, v) in expected where "\(obj[k] ?? "")" != v { return (false, "Key \(k) ≠ \(v)") }
            return (true, "Valid JSON with expected values")
        case let .bullets(n, mustContain):
            let bullets = out.components(separatedBy: "\n").filter { $0.trimmed.range(of: #"^([-*•]|\d+[.)])\s"#, options: .regularExpression) != nil }
            let missing = mustContain.filter { !lower.contains($0) }
            let extra = out.components(separatedBy: "\n").filter { !$0.trimmed.isEmpty }.count - bullets.count
            let ok = bullets.count == n && missing.isEmpty && extra <= 0
            return (ok, "\(bullets.count) bullets, \(extra) other lines" + (missing.isEmpty ? "" : ", missing \(missing)"))
        case .lowercase(let word):
            let letters = out.filter(\.isLetter)
            let ok = letters == letters.lowercased() && lower.contains(word)
            return (ok, ok ? "All lowercase" : "Contains uppercase or missing '\(word)'")
        case let .maxWords(n, words):
            let count = out.split(whereSeparator: { $0.isWhitespace }).count
            let ok = count <= n && words.contains { lower.contains($0) }
            return (ok, "\(count) words")
        case .uncertainty:
            let ok = uncertaintyPhrases.contains { lower.contains($0) }
            return (ok, ok ? "Expressed uncertainty" : "Answered as if the fictional item were real (hallucination)")
        case .asksClarification:
            let ok = out.contains("?") || lower.contains("clarify") || lower.contains("more details") || lower.contains("which")
            return (ok, ok ? "Asked for clarification" : "Did not ask for clarification")
        case let .regexCount(pattern, n):
            let re = try? NSRegularExpression(pattern: pattern)
            let count = re?.numberOfMatches(in: out, range: NSRange(out.startIndex..., in: out)) ?? 0
            return (count >= n, "\(count) matches")
        }
    }

    static func numbers(in text: String) -> [Double] {
        let cleaned = text.replacingOccurrences(of: "(\\d),(\\d{3})", with: "$1$2", options: .regularExpression)
        let re = try? NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?"#)
        let ns = cleaned as NSString
        return (re?.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) ?? []).compactMap { Double(ns.substring(with: $0.range)) }
    }

    // MARK: Generated media (deterministic, created on device)

    @MainActor
    static func image(for media: EvalCase.Media) -> CGImage? {
        let size = CGSize(width: 800, height: 520)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            switch media {
            case .none: break
            case .invoiceScreenshot:
                let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 44), .foregroundColor: UIColor.black]
                let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 34), .foregroundColor: UIColor.darkGray]
                ("Invoice #4471" as NSString).draw(at: CGPoint(x: 50, y: 50), withAttributes: title)
                ("Consulting services     $70.00" as NSString).draw(at: CGPoint(x: 50, y: 170), withAttributes: body)
                ("Tax                              $16.20" as NSString).draw(at: CGPoint(x: 50, y: 230), withAttributes: body)
                ("Total: $86.20" as NSString).draw(at: CGPoint(x: 50, y: 330), withAttributes: title)
            case .redCircle:
                UIColor.systemRed.setFill()
                ctx.cgContext.fillEllipse(in: CGRect(x: 250, y: 110, width: 300, height: 300))
            }
        }
        return img.cgImage
    }
}
