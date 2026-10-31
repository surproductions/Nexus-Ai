import Foundation
import JavaScriptCore

struct ToolOutput: Sendable {
    var text: String
    var sources: [SourceRef] = []
}

/// A capability an agent can invoke. Tools run locally unless `needsNetwork` is true, in which case they
/// pass through `NetworkGate`.
protocol AgentTool: Sendable {
    var name: String { get }
    var summary: String { get }
    var inputHint: String { get }
    var needsNetwork: Bool { get }
    func run(_ input: String) async throws -> ToolOutput
}

struct CalculatorTool: AgentTool {
    let name = "calculator"
    let summary = "Exact arithmetic: + - * / ^ % !, sqrt, ln, log, sin/cos/tan, nCr, gcd, percentages."
    let inputHint = "an arithmetic expression, e.g. (17.5*12)/3 + sqrt(2)"
    let needsNetwork = false

    func run(_ input: String) async throws -> ToolOutput {
        let v = try Calculator.evaluate(input)
        return ToolOutput(text: "\(input.trimmed) = \(Calculator.format(v))")
    }
}

struct UnitConverterTool: AgentTool {
    let name = "convert_units"
    let summary = "Converts measurements (length, mass, volume, temperature, speed, area, energy, data)."
    let inputHint = "\"<value> <unit> to <unit>\", e.g. 72 fahrenheit to celsius"
    let needsNetwork = false

    private static let units: [String: Dimension] = [
        "m": UnitLength.meters, "meter": UnitLength.meters, "meters": UnitLength.meters, "km": UnitLength.kilometers,
        "kilometers": UnitLength.kilometers, "cm": UnitLength.centimeters, "mm": UnitLength.millimeters,
        "mi": UnitLength.miles, "mile": UnitLength.miles, "miles": UnitLength.miles, "ft": UnitLength.feet, "feet": UnitLength.feet,
        "foot": UnitLength.feet, "in": UnitLength.inches, "inch": UnitLength.inches, "inches": UnitLength.inches,
        "yd": UnitLength.yards, "yards": UnitLength.yards, "nmi": UnitLength.nauticalMiles,
        "kg": UnitMass.kilograms, "kilograms": UnitMass.kilograms, "g": UnitMass.grams, "grams": UnitMass.grams,
        "mg": UnitMass.milligrams, "lb": UnitMass.pounds, "lbs": UnitMass.pounds, "pounds": UnitMass.pounds,
        "oz": UnitMass.ounces, "ounces": UnitMass.ounces, "stone": UnitMass.stones, "ton": UnitMass.metricTons,
        "l": UnitVolume.liters, "liter": UnitVolume.liters, "liters": UnitVolume.liters, "ml": UnitVolume.milliliters,
        "gallon": UnitVolume.gallons, "gallons": UnitVolume.gallons, "gal": UnitVolume.gallons, "cup": UnitVolume.cups,
        "cups": UnitVolume.cups, "floz": UnitVolume.fluidOunces, "tbsp": UnitVolume.tablespoons, "tsp": UnitVolume.teaspoons,
        "c": UnitTemperature.celsius, "celsius": UnitTemperature.celsius, "f": UnitTemperature.fahrenheit,
        "fahrenheit": UnitTemperature.fahrenheit, "k": UnitTemperature.kelvin, "kelvin": UnitTemperature.kelvin,
        "kmh": UnitSpeed.kilometersPerHour, "km/h": UnitSpeed.kilometersPerHour, "mph": UnitSpeed.milesPerHour,
        "m/s": UnitSpeed.metersPerSecond, "knots": UnitSpeed.knots,
        "m2": UnitArea.squareMeters, "sqm": UnitArea.squareMeters, "ft2": UnitArea.squareFeet, "sqft": UnitArea.squareFeet,
        "acre": UnitArea.acres, "acres": UnitArea.acres, "hectare": UnitArea.hectares, "hectares": UnitArea.hectares,
        "j": UnitEnergy.joules, "kj": UnitEnergy.kilojoules, "kcal": UnitEnergy.kilocalories, "kwh": UnitEnergy.kilowattHours,
        "cal": UnitEnergy.calories, "b": UnitInformationStorage.bytes, "kb": UnitInformationStorage.kilobytes,
        "mb": UnitInformationStorage.megabytes, "gb": UnitInformationStorage.gigabytes, "tb": UnitInformationStorage.terabytes,
    ]

    func run(_ input: String) async throws -> ToolOutput {
        let t = input.lowercased().replacingOccurrences(of: "°", with: "").replacingOccurrences(of: "degrees ", with: "")
        let regex = try NSRegularExpression(pattern: "(-?[\\d.,]+)\\s*([a-z/0-9]+)\\s+(?:to|in|into)\\s+([a-z/0-9]+)")
        guard let m = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let r1 = Range(m.range(at: 1), in: t), let r2 = Range(m.range(at: 2), in: t), let r3 = Range(m.range(at: 3), in: t),
              let value = Double(t[r1].replacingOccurrences(of: ",", with: "")) else {
            throw NexusError.generic("Use the form: 10 km to miles")
        }
        guard let from = Self.units[String(t[r2])], let to = Self.units[String(t[r3])],
              ObjectIdentifier(type(of: from)) == ObjectIdentifier(type(of: to)) else {
            throw NexusError.generic("Unsupported or incompatible units: \(t[r2]) → \(t[r3])")
        }
        let result = Measurement<Dimension>(value: value, unit: from).converted(to: to).value
        return ToolOutput(text: "\(Calculator.format(value)) \(t[r2]) = \(String(format: "%.6g", result)) \(t[r3])")
    }
}

struct DateTool: AgentTool {
    let name = "date_time"
    let summary = "Current date/time, weekday of a date, and days between dates (ISO yyyy-mm-dd)."
    let inputHint = "\"now\", \"weekday 2027-03-14\", or \"days 2026-01-01 2026-12-25\""
    let needsNetwork = false

    func run(_ input: String) async throws -> ToolOutput {
        let parts = input.lowercased().split(separator: " ").map(String.init)
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.locale = Locale(identifier: "en_US_POSIX")
        let full = DateFormatter()
        full.dateStyle = .full
        full.timeStyle = .short
        if parts.first == "days", parts.count >= 3, let a = iso.date(from: parts[1]), let b = iso.date(from: parts[2]) {
            let d = Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0
            return ToolOutput(text: "\(d) days from \(parts[1]) to \(parts[2])")
        }
        if parts.first == "weekday", parts.count >= 2, let a = iso.date(from: parts[1]) {
            let f = DateFormatter()
            f.dateFormat = "EEEE"
            return ToolOutput(text: "\(parts[1]) is a \(f.string(from: a))")
        }
        return ToolOutput(text: "Now: \(full.string(from: Date())) (\(TimeZone.current.identifier))")
    }
}

/// Syntax-checks or runs JavaScript in an isolated JavaScriptCore context (no network, no file access).
struct JavaScriptTool: AgentTool {
    let name = "javascript"
    let summary = "Runs a short JavaScript snippet in an isolated sandbox and returns the value of the last expression."
    let inputHint = "JavaScript code; the last expression is returned"
    let needsNetwork = false

    func run(_ input: String) async throws -> ToolOutput {
        let result = JavaScriptSandbox.evaluate(input, timeout: 3)
        return ToolOutput(text: result.error.map { "Error: \($0)" } ?? "Result: \(result.value ?? "undefined")\(result.logs.isEmpty ? "" : "\nConsole: " + result.logs.joined(separator: "\n"))")
    }
}

enum JavaScriptSandbox {
    struct Result: Sendable { var value: String?; var error: String?; var logs: [String] }

    /// Parses without executing (for code verification).
    static func syntaxCheck(_ code: String) -> String? {
        let ctx = JSContext()!
        var err: String?
        ctx.exceptionHandler = { _, ex in err = ex?.toString() }
        ctx.setObject(code, forKeyedSubscript: "__src" as NSString)
        ctx.evaluateScript("new Function(__src);")
        return err
    }

    /// Executes on a dedicated thread; gives up waiting after `timeout` seconds.
    static func evaluate(_ code: String, timeout: TimeInterval) -> Result {
        final class Box: @unchecked Sendable { var result = Result(value: nil, error: "Timed out after \(Int(3))s (possible infinite loop)", logs: []) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let ctx = JSContext()!
            var logs: [String] = []
            var err: String?
            ctx.exceptionHandler = { _, ex in err = ex?.toString() }
            let log: @convention(block) (String) -> Void = { logs.append($0) }
            ctx.setObject(log, forKeyedSubscript: "__log" as NSString)
            ctx.evaluateScript("var console = { log: function() { __log(Array.prototype.map.call(arguments, String).join(' ')); } };")
            let v = ctx.evaluateScript(code)
            box.result = Result(value: err == nil ? v?.toString() : nil, error: err, logs: Array(logs.prefix(50)))
            done.signal()
        }
        thread.stackSize = 4 << 20
        thread.start()
        _ = done.wait(timeout: .now() + timeout)
        return box.result
    }
}

struct WebSearchTool: AgentTool {
    let name = "web_search"
    let summary = "Searches the web for current information. Returns titles, URLs and snippets."
    let inputHint = "a concise search query"
    let needsNetwork = true
    var braveKey: String?

    func run(_ input: String) async throws -> ToolOutput {
        let results = try await WebResearch.search(input, braveKey: braveKey)
        guard !results.isEmpty else { return ToolOutput(text: "No results.") }
        let text = results.enumerated().map { "[\($0.offset + 1)] \($0.element.title)\n\($0.element.location)\n\($0.element.snippet)" }
            .joined(separator: "\n\n")
        return ToolOutput(text: text, sources: results)
    }
}

struct FetchPageTool: AgentTool {
    let name = "fetch_page"
    let summary = "Downloads a web page and returns its readable text."
    let inputHint = "a full https:// URL"
    let needsNetwork = true

    func run(_ input: String) async throws -> ToolOutput {
        let page = try await WebResearch.fetch(input.trimmed, maxChars: 6000)
        return ToolOutput(text: page.text, sources: [SourceRef(title: page.title, location: input.trimmed, snippet: String(page.text.prefix(200)))])
    }
}

/// Closure-backed tools for local stores (memory, documents) so tools stay `Sendable`.
struct ClosureTool: AgentTool {
    let name: String
    let summary: String
    let inputHint: String
    let needsNetwork = false
    let body: @Sendable (String) async -> ToolOutput

    func run(_ input: String) async throws -> ToolOutput { await body(input) }
}

/// Parses `<tool_call>{"name": ..., "arguments"/"input": ...}</tool_call>` (Qwen/Hermes style) or
/// `ACTION: name` / `INPUT: ...` lines emitted by local models.
enum ToolCallParser {
    struct Call: Sendable { var name: String; var input: String }

    static let openTag = "<tool_call>"
    static let closeTag = "</tool_call>"

    static func parse(_ text: String) -> Call? {
        if let open = text.range(of: openTag) {
            let after = text[open.upperBound...]
            let body = after.range(of: closeTag).map { String(after[..<$0.lowerBound]) } ?? String(after)
            return parseJSON(body.trimmed)
        }
        let lines = text.components(separatedBy: "\n")
        if let a = lines.firstIndex(where: { $0.uppercased().hasPrefix("ACTION:") }) {
            let name = lines[a].dropFirst(7).trimmed.lowercased()
            let input = lines.dropFirst(a + 1).first(where: { $0.uppercased().hasPrefix("INPUT:") }).map { String($0.dropFirst(6)).trimmed } ?? ""
            return name.isEmpty ? nil : Call(name: name, input: input)
        }
        return nil
    }

    private static func parseJSON(_ body: String) -> Call? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String else {
            // Tolerate slightly malformed JSON: name":"x" ... "input":"y"
            let n = firstMatch(#""name"\s*:\s*"([^"]+)""#, body)
            let i = firstMatch(#""(?:input|query|expression|code|url)"\s*:\s*"((?:[^"\\]|\\.)*)""#, body)
            return n.map { Call(name: $0, input: i?.replacingOccurrences(of: "\\\"", with: "\"") ?? "") }
        }
        var input = ""
        let args = obj["arguments"] ?? obj["parameters"] ?? obj["input"]
        if let s = args as? String { input = s }
        else if let d = args as? [String: Any] {
            for key in ["input", "query", "expression", "code", "url", "text"] {
                if let v = d[key] as? String { input = v; break }
            }
            if input.isEmpty, let v = d.values.first { input = "\(v)" }
        }
        return Call(name: name, input: input)
    }

    private static func firstMatch(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func describe(_ tools: [AgentTool]) -> String {
        let list = tools.map { "- \($0.name): \($0.summary) Input: \($0.inputHint)." }.joined(separator: "\n")
        return """
        You can call tools when they would make your answer more accurate. To call one, output only:
        <tool_call>{"name": "TOOL_NAME", "arguments": {"input": "..."}}</tool_call>
        and stop. The result will be returned to you in <tool_response> tags. Call at most one tool at a time, then continue.
        Available tools:
        \(list)
        """
    }
}
