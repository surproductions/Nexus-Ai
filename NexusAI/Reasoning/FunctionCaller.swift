import Foundation

/// Uses FunctionGemma (270M) to map a request onto NEXUS's tools. Its output is a proposal: every call is
/// validated (known tool, sensible arguments, consistent with the deterministic classifier) before execution.
struct FunctionDeclaration {
    var name: String
    var description: String
    var argument: String
    var argumentDescription: String

    /// FunctionGemma declaration syntax (Gemma function-calling format with <escape> string delimiters).
    var rendered: String {
        "<start_function_declaration>declaration:\(name){description:<escape>\(description)<escape>,parameters:{properties:{\(argument):{description:<escape>\(argumentDescription)<escape>,type:<escape>STRING<escape>}},required:[<escape>\(argument)<escape>],type:<escape>OBJECT<escape>}}<end_function_declaration>"
    }
}

struct ProposedCall: Equatable, Sendable {
    var name: String
    var arguments: [String: String]
    var primaryArgument: String { arguments.values.first ?? "" }
}

enum FunctionCallParser {
    /// Parses `<start_function_call>call:name{key:<escape>value<escape>,…}<end_function_call>`.
    static func parse(_ text: String) -> ProposedCall? {
        guard let callRange = text.range(of: #"call:([A-Za-z_][A-Za-z0-9_]*)\{"#, options: .regularExpression) else { return nil }
        let header = String(text[callRange])
        let name = String(header.dropFirst(5).dropLast())
        var body = String(text[callRange.upperBound...])
        if let end = body.range(of: "<end_function_call>") { body = String(body[..<end.lowerBound]) }
        if body.hasSuffix("}") { body.removeLast() }
        var args: [String: String] = [:]
        let pattern = #"([A-Za-z_][A-Za-z0-9_]*):<escape>([\s\S]*?)<escape>"#
        if let re = try? NSRegularExpression(pattern: pattern) {
            for m in re.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                if let k = Range(m.range(at: 1), in: body), let v = Range(m.range(at: 2), in: body) {
                    args[String(body[k])] = String(body[v])
                }
            }
        }
        if args.isEmpty, let re = try? NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_]*):([^,}]+)"#) {
            for m in re.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                if let k = Range(m.range(at: 1), in: body), let v = Range(m.range(at: 2), in: body) {
                    args[String(body[k])] = String(body[v]).trimmed
                }
            }
        }
        return ProposedCall(name: name, arguments: args)
    }

    static func prompt(declarations: [FunctionDeclaration], request: String) -> String {
        "<start_of_turn>developer\nYou are a model that can do function calling with the following functions" +
            declarations.map(\.rendered).joined() +
            "<end_of_turn>\n<start_of_turn>user\n\(request)<end_of_turn>\n<start_of_turn>model\n"
    }

    static let declarations: [FunctionDeclaration] = [
        FunctionDeclaration(name: "calculator", description: "Evaluates an arithmetic expression exactly.", argument: "expression", argumentDescription: "Arithmetic expression, e.g. (12*7)/3"),
        FunctionDeclaration(name: "convert_units", description: "Converts a measurement between units.", argument: "query", argumentDescription: "e.g. 10 km to miles"),
        FunctionDeclaration(name: "date_time", description: "Gets the current date and time.", argument: "query", argumentDescription: "Use now"),
        FunctionDeclaration(name: "web_search", description: "Searches the web for current information.", argument: "query", argumentDescription: "Search query"),
        FunctionDeclaration(name: "search_documents", description: "Searches the user's documents.", argument: "query", argumentDescription: "What to look for"),
        FunctionDeclaration(name: "search_memory", description: "Searches facts the user asked to remember.", argument: "query", argumentDescription: "What to look for"),
        FunctionDeclaration(name: "generate_image", description: "Creates a new image from a description.", argument: "prompt", argumentDescription: "Description of the image"),
        FunctionDeclaration(name: "generate_video", description: "Creates a short video from a description.", argument: "prompt", argumentDescription: "Description of the video"),
    ]

    /// Accepts a proposal only when it is well-formed and consistent with the deterministic task profile.
    static func validate(_ call: ProposedCall, profile: TaskProfile, webAllowed: Bool) -> Bool {
        let arg = call.primaryArgument.trimmed
        switch call.name {
        case "calculator": return (try? Calculator.evaluate(arg)) != nil
        case "convert_units": return arg.range(of: #"\d.*\s(to|in|into)\s"#, options: .regularExpression) != nil
        case "date_time": return profile.wantsDateTime
        case "web_search": return webAllowed && !arg.isEmpty && (profile.needsCurrentInfo || profile.category == .research)
        case "search_documents": return !arg.isEmpty && profile.hasDocuments
        case "search_memory": return !arg.isEmpty
        case "generate_image": return profile.creativeIntent == .image && arg.count > 3
        case "generate_video": return profile.creativeIntent == .video && arg.count > 3
        default: return false
        }
    }
}
