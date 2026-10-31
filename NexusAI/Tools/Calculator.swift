import Foundation

/// Exact arithmetic evaluator (recursive-descent parser). Used by the Reasoning agent to verify
/// numbers instead of trusting a small model's mental math.
struct Calculator {
    enum CalcError: LocalizedError {
        case syntax(String), domain(String)
        var errorDescription: String? {
            switch self {
            case .syntax(let s): return "Syntax error: \(s)"
            case .domain(let s): return "Math error: \(s)"
            }
        }
    }

    private var chars: [Character] = []
    private var pos = 0

    static func evaluate(_ expression: String) throws -> Double {
        var c = Calculator()
        c.chars = Array(normalize(expression))
        let v = try c.parseExpression()
        c.skipSpaces()
        guard c.pos == c.chars.count else { throw CalcError.syntax("unexpected '\(c.chars[c.pos])'") }
        guard v.isFinite else { throw CalcError.domain("result is not finite") }
        return v
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(format: "%.0f", v) }
        let s = String(format: "%.10g", v)
        return s
    }

    /// Handles natural phrasings: "15% of 240", "×", "÷", "^", thousands separators.
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "**", with: "^")
            .replacingOccurrences(of: "π", with: "pi")
        t = t.replacingOccurrences(of: "(\\d),(\\d{3})", with: "$1$2", options: .regularExpression)
        t = t.replacingOccurrences(of: "([\\d.]+)\\s*%\\s*of\\s*", with: "($1/100)*", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\bsquare root of\\b", with: "sqrt", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\btimes\\b", with: "*", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\bdivided by\\b", with: "/", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\bplus\\b", with: "+", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\bminus\\b", with: "-", options: .regularExpression)
        t = t.replacingOccurrences(of: "=\\s*$", with: "", options: .regularExpression)
        return t
    }

    private mutating func skipSpaces() { while pos < chars.count && chars[pos].isWhitespace { pos += 1 } }

    private mutating func peek() -> Character? { skipSpaces(); return pos < chars.count ? chars[pos] : nil }

    private mutating func parseExpression() throws -> Double {
        var v = try parseTerm()
        while let c = peek(), c == "+" || c == "-" {
            pos += 1
            let r = try parseTerm()
            v = c == "+" ? v + r : v - r
        }
        return v
    }

    private mutating func parseTerm() throws -> Double {
        var v = try parseUnary()
        while let c = peek() {
            if c == "*" || c == "/" || c == "%" {
                pos += 1
                let r = try parseUnary()
                if c == "*" { v *= r }
                else if c == "/" { guard r != 0 else { throw CalcError.domain("division by zero") }; v /= r }
                else { guard r != 0 else { throw CalcError.domain("modulo by zero") }; v = v.truncatingRemainder(dividingBy: r) }
            } else if c == "(" || c.isLetter {
                // Implicit multiplication: 2(3+4), 2pi
                let r = try parseUnary()
                v *= r
            } else { break }
        }
        return v
    }

    private mutating func parseUnary() throws -> Double {
        if let c = peek(), c == "-" || c == "+" {
            pos += 1
            let v = try parseUnary()
            return c == "-" ? -v : v
        }
        return try parsePower()
    }

    private mutating func parsePower() throws -> Double {
        let base = try parsePostfix()
        if peek() == "^" {
            pos += 1
            let exp = try parseUnary()   // right-associative
            return pow(base, exp)
        }
        return base
    }

    private mutating func parsePostfix() throws -> Double {
        var v = try parsePrimary()
        while peek() == "!" {
            pos += 1
            guard v >= 0, v == v.rounded(), v <= 170 else { throw CalcError.domain("factorial needs an integer 0…170") }
            v = (1...max(1, Int(v))).reduce(1.0) { $0 * Double($1) }
        }
        return v
    }

    private mutating func parsePrimary() throws -> Double {
        guard let c = peek() else { throw CalcError.syntax("unexpected end") }
        if c == "(" {
            pos += 1
            let v = try parseExpression()
            guard peek() == ")" else { throw CalcError.syntax("missing ')'") }
            pos += 1
            return v
        }
        if c.isNumber || c == "." {
            let start = pos
            while pos < chars.count && (chars[pos].isNumber || chars[pos] == ".") { pos += 1 }
            if pos < chars.count && chars[pos] == "e", pos + 1 < chars.count,
               chars[pos + 1].isNumber || chars[pos + 1] == "-" || chars[pos + 1] == "+" {
                pos += 1
                if chars[pos] == "-" || chars[pos] == "+" { pos += 1 }
                while pos < chars.count && chars[pos].isNumber { pos += 1 }
            }
            guard let v = Double(String(chars[start..<pos])) else { throw CalcError.syntax("bad number") }
            return v
        }
        if c.isLetter {
            let start = pos
            while pos < chars.count && (chars[pos].isLetter || chars[pos].isNumber) { pos += 1 }
            let name = String(chars[start..<pos])
            switch name {
            case "pi": return Double.pi
            case "e": return M_E
            case "tau": return 2 * Double.pi
            default: break
            }
            guard peek() == "(" else { throw CalcError.syntax("unknown name '\(name)'") }
            pos += 1
            var args = [try parseExpression()]
            while peek() == "," { pos += 1; args.append(try parseExpression()) }
            guard peek() == ")" else { throw CalcError.syntax("missing ')' after \(name)") }
            pos += 1
            let x = args[0]
            switch name {
            case "sqrt": guard x >= 0 else { throw CalcError.domain("sqrt of negative") }; return sqrt(x)
            case "cbrt": return cbrt(x)
            case "sin": return sin(x)
            case "cos": return cos(x)
            case "tan": return tan(x)
            case "asin": return asin(x)
            case "acos": return acos(x)
            case "atan": return args.count == 2 ? atan2(x, args[1]) : atan(x)
            case "sinh": return sinh(x)
            case "cosh": return cosh(x)
            case "tanh": return tanh(x)
            case "ln": guard x > 0 else { throw CalcError.domain("ln of non-positive") }; return log(x)
            case "log", "log10": guard x > 0 else { throw CalcError.domain("log of non-positive") }; return args.count == 2 ? log(x) / log(args[1]) : log10(x)
            case "log2": guard x > 0 else { throw CalcError.domain("log2 of non-positive") }; return log2(x)
            case "exp": return exp(x)
            case "abs": return abs(x)
            case "round": return args.count == 2 ? (x * pow(10, args[1])).rounded() / pow(10, args[1]) : x.rounded()
            case "floor": return floor(x)
            case "ceil": return ceil(x)
            case "min": return args.min() ?? x
            case "max": return args.max() ?? x
            case "pow": return pow(x, args.count > 1 ? args[1] : 1)
            case "deg": return x * 180 / .pi
            case "rad": return x * .pi / 180
            case "mod": return args.count == 2 ? x.truncatingRemainder(dividingBy: args[1]) : x
            case "gcd", "lcm":
                guard args.count == 2 else { throw CalcError.syntax("\(name) needs 2 arguments") }
                var a = Int(abs(x)), b = Int(abs(args[1]))
                let (oa, ob) = (a, b)
                while b != 0 { (a, b) = (b, a % b) }
                return name == "gcd" ? Double(a) : Double(oa / max(a, 1) * ob)
            case "ncr", "choose", "npr":
                guard args.count == 2 else { throw CalcError.syntax("\(name) needs 2 arguments") }
                let n = Int(x), k = Int(args[1])
                guard n >= 0, k >= 0, k <= n else { throw CalcError.domain("invalid n, k") }
                var r = 1.0
                for i in 0..<k { r *= Double(n - i) }
                if name != "npr" { for i in 1...max(1, k) where k > 0 { r /= Double(i) } }
                return r
            default: throw CalcError.syntax("unknown function '\(name)'")
            }
        }
        throw CalcError.syntax("unexpected '\(c)'")
    }

    /// Extracts the most plausible arithmetic expression from a natural-language question, if any.
    static func extractExpression(from text: String) -> String? {
        let t = normalize(text)
        let pattern = "[-+]?[\\d.(][\\d\\s.+\\-*/^%()!,a-z]*[\\d)!]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = t as NSString
        let candidates = regex.matches(in: t, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).trimmed }
        for cand in candidates.sorted(by: { $0.count > $1.count }) {
            let opCount = cand.filter { "+-*/^%!".contains($0) }.count + (cand.contains("sqrt") ? 1 : 0)
            guard opCount >= 1, cand.contains(where: \.isNumber) else { continue }
            if (try? evaluate(cand)) != nil { return cand }
        }
        return nil
    }
}
