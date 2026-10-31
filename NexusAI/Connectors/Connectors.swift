import Foundation

struct ConnectorConfig: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case firecrawl = "Firecrawl"
        case tavily = "Tavily"
        case brave = "Brave Search"
        case mcp = "MCP server"

        var summary: String {
            switch self {
            case .firecrawl: return "Web search with full-page content, and clean page scraping to Markdown."
            case .tavily: return "Search API designed for AI agents, with extracted answers and snippets."
            case .brave: return "Independent web index search."
            case .mcp: return "Any Model Context Protocol server over Streamable HTTP. Its tools become available to NEXUS agents."
            }
        }
        var defaultURL: String {
            switch self {
            case .firecrawl: return "https://api.firecrawl.dev"
            case .tavily: return "https://api.tavily.com"
            case .brave: return "https://api.search.brave.com"
            case .mcp: return "https://"
            }
        }
        var keyRequired: Bool { self != .mcp }
    }

    var id = UUID()
    var kind: Kind
    var name: String
    var baseURL: String
    var enabled = true
    /// Tools discovered on an MCP server (cached for prompts; refreshed on "Test").
    var mcpTools: [MCPToolInfo] = []

    var keychainKey: String { "connector.\(id.uuidString)" }
    var apiKey: String? { Keychain.get(keychainKey) }
}

struct MCPToolInfo: Codable, Hashable, Sendable {
    var name: String
    var description: String
    var inputSchema: String       // JSON text
    var primaryArgument: String?  // single required string property, if any
}

/// Thread-safe snapshot of enabled connectors for non-UI code (search, tools).
final class ConnectorRegistry: @unchecked Sendable {
    static let shared = ConnectorRegistry()
    private let lock = NSLock()
    private var _connectors: [ConnectorConfig] = []

    var connectors: [ConnectorConfig] {
        get { lock.lock(); defer { lock.unlock() }; return _connectors }
        set { lock.lock(); _connectors = newValue; lock.unlock() }
    }

    func enabled(_ kind: ConnectorConfig.Kind) -> ConnectorConfig? {
        guard NetworkGate.shared.isAllowed(.connectors) else { return nil }
        return connectors.first { $0.kind == kind && $0.enabled && ($0.apiKey?.isEmpty == false || !kind.keyRequired) }
    }

    var enabledMCP: [ConnectorConfig] {
        guard NetworkGate.shared.isAllowed(.connectors) else { return [] }
        return connectors.filter { $0.kind == .mcp && $0.enabled }
    }
}

@MainActor
final class ConnectorStore: ObservableObject {
    @Published var connectors: [ConnectorConfig] { didSet { persist() } }

    init() {
        if let d = UserDefaults.standard.data(forKey: "connectors.v1"), let list = try? JSONDecoder().decode([ConnectorConfig].self, from: d) {
            connectors = list
        } else {
            connectors = []
        }
        // Migrate the earlier standalone Brave key.
        if let brave = Keychain.get("brave.key"), !brave.isEmpty, !connectors.contains(where: { $0.kind == .brave }) {
            let c = ConnectorConfig(kind: .brave, name: "Brave Search", baseURL: ConnectorConfig.Kind.brave.defaultURL)
            Keychain.set(brave, for: c.keychainKey)
            connectors.append(c)
        }
        ConnectorRegistry.shared.connectors = connectors
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(connectors) { UserDefaults.standard.set(d, forKey: "connectors.v1") }
        ConnectorRegistry.shared.connectors = connectors
    }

    func upsert(_ c: ConnectorConfig) {
        if let i = connectors.firstIndex(where: { $0.id == c.id }) { connectors[i] = c } else { connectors.append(c) }
    }

    func remove(_ c: ConnectorConfig) {
        Keychain.delete(c.keychainKey)
        connectors.removeAll { $0.id == c.id }
    }

    /// Makes a real request to verify credentials (and discovers MCP tools).
    func test(_ c: ConnectorConfig) async -> String {
        do {
            switch c.kind {
            case .firecrawl:
                let r = try await Firecrawl.search("NEXUS AI test", config: c, limit: 1, scrape: false)
                return "Connected · \(r.count) result(s)"
            case .tavily:
                let r = try await Tavily.search("NEXUS AI test", config: c, limit: 1)
                return "Connected · \(r.count) result(s)"
            case .brave:
                let r = try await BraveSearch.search("NEXUS AI test", config: c, limit: 1)
                return "Connected · \(r.count) result(s)"
            case .mcp:
                let client = MCPClient(config: c)
                let tools = try await client.listTools()
                var updated = c
                updated.mcpTools = tools
                upsert(updated)
                return "Connected · \(tools.count) tool(s): \(tools.prefix(6).map(\.name).joined(separator: ", "))"
            }
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Search connectors

private func connectorRequest(_ url: URL, config: ConnectorConfig, body: [String: Any]?, bearer: Bool = true) throws -> URLRequest {
    var r = URLRequest(url: url)
    r.httpMethod = body == nil ? "GET" : "POST"
    r.timeoutInterval = 60
    if let key = config.apiKey, !key.isEmpty, bearer { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    if let body {
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    return r
}

private func base(_ c: ConnectorConfig) -> String { c.baseURL.hasSuffix("/") ? String(c.baseURL.dropLast()) : c.baseURL }

enum Firecrawl {
    /// POST /v2/search. With `scrape`, each result includes Markdown page content.
    static func search(_ query: String, config: ConnectorConfig, limit: Int, scrape: Bool) async throws -> [SourceRef] {
        var body: [String: Any] = ["query": query, "limit": limit]
        if scrape { body["scrapeOptions"] = ["formats": ["markdown"], "onlyMainContent": true] }
        let r = try connectorRequest(URL(string: base(config) + "/v2/search")!, config: config, body: body)
        let (data, http) = try await NetworkGate.shared.data(for: r, feature: .connectors, summary: "Firecrawl search: \(query)")
        guard (200..<300).contains(http.statusCode), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NexusError.provider("Firecrawl returned HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.truncated(to: 200) ?? "")")
        }
        // v2: data.web[]; v1: data[]
        var items: [[String: Any]] = []
        if let d = json["data"] as? [String: Any] { items = (d["web"] as? [[String: Any]]) ?? [] }
        else if let d = json["data"] as? [[String: Any]] { items = d }
        return items.compactMap { i in
            guard let url = i["url"] as? String else { return nil }
            let md = (i["markdown"] as? String) ?? ""
            let snippet = md.isEmpty ? (i["description"] as? String ?? "") : String(md.prefix(3500))
            return SourceRef(title: (i["title"] as? String) ?? url, location: url, snippet: snippet)
        }
    }

    /// POST /v2/scrape → Markdown.
    static func scrape(_ url: String, config: ConnectorConfig, maxChars: Int) async throws -> WebResearch.Page {
        let r = try connectorRequest(URL(string: base(config) + "/v2/scrape")!, config: config,
                                     body: ["url": url, "formats": ["markdown"], "onlyMainContent": true])
        let (data, http) = try await NetworkGate.shared.data(for: r, feature: .connectors, summary: "Firecrawl scrape: \(url)")
        guard (200..<300).contains(http.statusCode), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any] else {
            throw NexusError.provider("Firecrawl scrape failed (HTTP \(http.statusCode))")
        }
        let title = ((d["metadata"] as? [String: Any])?["title"] as? String) ?? url
        return WebResearch.Page(title: title, text: String(((d["markdown"] as? String) ?? "").prefix(maxChars)))
    }
}

enum Tavily {
    static func search(_ query: String, config: ConnectorConfig, limit: Int) async throws -> [SourceRef] {
        let r = try connectorRequest(URL(string: base(config) + "/search")!, config: config,
                                     body: ["query": query, "max_results": limit, "include_answer": true])
        let (data, http) = try await NetworkGate.shared.data(for: r, feature: .connectors, summary: "Tavily search: \(query)")
        guard (200..<300).contains(http.statusCode), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NexusError.provider("Tavily returned HTTP \(http.statusCode)")
        }
        var out = ((json["results"] as? [[String: Any]]) ?? []).compactMap { i -> SourceRef? in
            guard let url = i["url"] as? String else { return nil }
            return SourceRef(title: (i["title"] as? String) ?? url, location: url, snippet: (i["content"] as? String) ?? "")
        }
        if let answer = json["answer"] as? String, !answer.isEmpty, !out.isEmpty {
            out[0].snippet = "Summary: \(answer)\n\(out[0].snippet)"
        }
        return out
    }
}

enum BraveSearch {
    static func search(_ query: String, config: ConnectorConfig, limit: Int) async throws -> [SourceRef] {
        var comps = URLComponents(string: base(config) + "/res/v1/web/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "\(limit)")]
        var r = try connectorRequest(comps.url!, config: config, body: nil, bearer: false)
        r.setValue(config.apiKey, forHTTPHeaderField: "X-Subscription-Token")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await NetworkGate.shared.data(for: r, feature: .connectors, summary: "Brave search: \(query)")
        guard http.statusCode == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = json["web"] as? [String: Any], let results = web["results"] as? [[String: Any]] else {
            throw NexusError.provider("Brave returned HTTP \(http.statusCode)")
        }
        return results.compactMap { r in
            guard let title = r["title"] as? String, let url = r["url"] as? String else { return nil }
            return SourceRef(title: HTMLText.strip(title), location: url, snippet: HTMLText.strip(r["description"] as? String ?? ""))
        }
    }
}

// MARK: - MCP (Streamable HTTP transport, JSON-RPC 2.0)

final class MCPClient: @unchecked Sendable {
    let config: ConnectorConfig
    private var sessionID: String?
    private var nextID = 1
    private var initialized = false
    private let lock = NSLock()

    init(config: ConnectorConfig) { self.config = config }

    private func send(_ method: String, params: [String: Any]?, notification: Bool = false) async throws -> [String: Any]? {
        guard let url = URL(string: config.baseURL) else { throw NexusError.provider("Invalid MCP URL") }
        lock.lock()
        let id = nextID
        nextID += 1
        let sid = sessionID
        lock.unlock()
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { body["params"] = params }
        if !notification { body["id"] = id }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 90
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let key = config.apiKey, !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let sid { r.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id") }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await NetworkGate.shared.data(for: r, feature: .connectors, summary: "MCP \(config.name): \(method)")
        if let newSID = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            lock.lock(); sessionID = newSID; lock.unlock()
        }
        if notification { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw NexusError.provider("MCP server returned HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.truncated(to: 200) ?? "")")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        // Response is either a JSON object or an SSE stream containing it.
        var candidates: [String] = []
        if (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") || text.hasPrefix("event:") || text.hasPrefix("data:") {
            candidates = text.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmed }
        } else {
            candidates = [text]
        }
        for c in candidates.reversed() {
            guard let d = c.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let err = obj["error"] as? [String: Any] { throw NexusError.provider("MCP error: \(err["message"] as? String ?? "unknown")") }
            if let result = obj["result"] as? [String: Any] { return result }
        }
        throw NexusError.provider("MCP server sent no result for \(method).")
    }

    private func ensureInitialized() async throws {
        if initialized { return }
        _ = try await send("initialize", params: ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
                                                   "clientInfo": ["name": "NEXUS AI", "version": "1.0"]])
        _ = try? await send("notifications/initialized", params: nil, notification: true)
        initialized = true
    }

    func listTools() async throws -> [MCPToolInfo] {
        try await ensureInitialized()
        let result = try await send("tools/list", params: [:]) ?? [:]
        return ((result["tools"] as? [[String: Any]]) ?? []).compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let schema = t["inputSchema"] as? [String: Any] ?? [:]
            let schemaText = (try? JSONSerialization.data(withJSONObject: schema)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            var primary: String?
            if let props = schema["properties"] as? [String: Any] {
                let required = schema["required"] as? [String] ?? []
                let stringProps = props.filter { (($0.value as? [String: Any])?["type"] as? String) == "string" }.map(\.key)
                primary = required.count == 1 ? required[0] : (stringProps.count == 1 ? stringProps[0] : nil)
            }
            return MCPToolInfo(name: name, description: (t["description"] as? String ?? "").truncated(to: 300), inputSchema: schemaText, primaryArgument: primary)
        }
    }

    /// Calls a tool. `input` may be a JSON object (arguments) or plain text mapped to the tool's primary argument.
    func call(_ tool: MCPToolInfo, input: String) async throws -> String {
        try await ensureInitialized()
        var args: [String: Any] = [:]
        if let d = input.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { args = obj }
        else if let p = tool.primaryArgument { args = [p: input] }
        let result = try await send("tools/call", params: ["name": tool.name, "arguments": args]) ?? [:]
        let content = (result["content"] as? [[String: Any]]) ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        if (result["isError"] as? Bool) == true { return "Tool error: \(text)" }
        return text.isEmpty ? "(no text content)" : text
    }
}

/// Exposes connector capabilities as agent tools.
enum ConnectorTools {
    static func tools() -> [AgentTool] {
        var out: [AgentTool] = []
        if let fc = ConnectorRegistry.shared.enabled(.firecrawl) {
            out.append(ConnectorTool(name: "firecrawl_search", summary: "Searches the web with Firecrawl and returns page content.",
                                     inputHint: "a search query") { q in
                let r = try await Firecrawl.search(q, config: fc, limit: 4, scrape: true)
                return ToolOutput(text: r.enumerated().map { "[\($0.offset + 1)] \($0.element.title) — \($0.element.location)\n\($0.element.snippet.truncated(to: 1500))" }.joined(separator: "\n\n"), sources: r)
            })
            out.append(ConnectorTool(name: "firecrawl_scrape", summary: "Scrapes a URL to clean Markdown with Firecrawl.",
                                     inputHint: "a full https:// URL") { u in
                let p = try await Firecrawl.scrape(u.trimmed, config: fc, maxChars: 6000)
                return ToolOutput(text: p.text, sources: [SourceRef(title: p.title, location: u.trimmed)])
            })
        }
        for server in ConnectorRegistry.shared.enabledMCP {
            let client = MCPClient(config: server)
            for t in server.mcpTools.prefix(12) {
                let safe = server.name.lowercased().filter { $0.isLetter || $0.isNumber }
                out.append(ConnectorTool(name: "mcp_\(safe)_\(t.name)", summary: "[\(server.name)] \(t.description)",
                                         inputHint: t.primaryArgument.map { "the \($0)" } ?? "JSON arguments matching \(t.inputSchema.truncated(to: 200))") { input in
                    ToolOutput(text: try await client.call(t, input: input))
                })
            }
        }
        return out
    }
}

struct ConnectorTool: AgentTool {
    let name: String
    let summary: String
    let inputHint: String
    let needsNetwork = true
    let body: @Sendable (String) async throws -> ToolOutput
    func run(_ input: String) async throws -> ToolOutput { try await body(input) }
}
