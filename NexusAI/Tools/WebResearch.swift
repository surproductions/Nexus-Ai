import Foundation

/// Web search and page retrieval. Only the query / URL leaves the device, and only when Web Research is enabled.
enum WebResearch {
    struct Page: Sendable { var title: String; var text: String }

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    static func search(_ query: String, braveKey: String?, limit: Int = 6) async throws -> [SourceRef] {
        // User-added connectors take priority (Settings → Connectors).
        let registry = ConnectorRegistry.shared
        if let fc = registry.enabled(.firecrawl), let r = try? await Firecrawl.search(query, config: fc, limit: min(limit, 5), scrape: true), !r.isEmpty { return r }
        if let tv = registry.enabled(.tavily), let r = try? await Tavily.search(query, config: tv, limit: limit), !r.isEmpty { return r }
        if let br = registry.enabled(.brave), let r = try? await BraveSearch.search(query, config: br, limit: limit), !r.isEmpty { return r }
        if let key = braveKey, !key.isEmpty {
            if let r = try? await brave(query, key: key, limit: limit), !r.isEmpty { return r }
        }
        var results = (try? await duckDuckGo(query, limit: limit)) ?? []
        if results.count < 3 {
            results += (try? await wikipedia(query, limit: 3)) ?? []
        }
        guard !results.isEmpty else {
            try NetworkGate.shared.authorize(.webResearch)
            throw NexusError.provider("Search returned no results.")
        }
        return Array(results.prefix(limit))
    }

    private static func brave(_ q: String, key: String, limit: Int) async throws -> [SourceRef] {
        var comps = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "count", value: "\(limit)")]
        var req = URLRequest(url: comps.url!)
        req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await NetworkGate.shared.data(for: req, feature: .webResearch, summary: "Brave search: \(q)")
        guard http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = json["web"] as? [String: Any], let results = web["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let title = r["title"] as? String, let url = r["url"] as? String else { return nil }
            return SourceRef(title: HTMLText.strip(title), location: url, snippet: HTMLText.strip(r["description"] as? String ?? ""))
        }
    }

    private static func duckDuckGo(_ q: String, limit: Int) async throws -> [SourceRef] {
        var req = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q
        req.httpBody = "q=\(encoded)&kl=us-en".data(using: .utf8)
        let (data, http) = try await NetworkGate.shared.data(for: req, feature: .webResearch, summary: "DuckDuckGo search: \(q)")
        guard http.statusCode == 200, let html = String(data: data, encoding: .utf8) else { return [] }

        let linkRe = try NSRegularExpression(pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        let snipRe = try NSRegularExpression(pattern: #"class="result__snippet"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        let ns = html as NSString
        let links = linkRe.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let snippets = snipRe.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { HTMLText.strip(ns.substring(with: $0.range(at: 1))) }
        var out: [SourceRef] = []
        for (i, m) in links.enumerated() {
            var href = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            if let r = href.range(of: "uddg="), let decoded = String(href[r.upperBound...]).components(separatedBy: "&").first?.removingPercentEncoding {
                href = decoded
            }
            if href.hasPrefix("//") { href = "https:" + href }
            guard href.hasPrefix("http"), !href.contains("duckduckgo.com/y.js") else { continue }
            out.append(SourceRef(title: HTMLText.strip(ns.substring(with: m.range(at: 2))), location: href,
                                 snippet: i < snippets.count ? snippets[i] : ""))
            if out.count >= limit { break }
        }
        return out
    }

    private static func wikipedia(_ q: String, limit: Int) async throws -> [SourceRef] {
        var comps = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        comps.queryItems = [.init(name: "action", value: "query"), .init(name: "list", value: "search"),
                            .init(name: "srsearch", value: q), .init(name: "format", value: "json"),
                            .init(name: "srlimit", value: "\(limit)")]
        var req = URLRequest(url: comps.url!)
        req.setValue("NexusAI/1.0 (iOS; local-first assistant)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await NetworkGate.shared.data(for: req, feature: .webResearch, summary: "Wikipedia search: \(q)")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any], let list = query["search"] as? [[String: Any]] else { return [] }
        return list.compactMap { r in
            guard let title = r["title"] as? String else { return nil }
            let path = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
            return SourceRef(title: "\(title) — Wikipedia", location: "https://en.wikipedia.org/wiki/\(path)",
                             snippet: HTMLText.strip(r["snippet"] as? String ?? ""))
        }
    }

    static func fetch(_ urlString: String, maxChars: Int) async throws -> Page {
        if let fc = ConnectorRegistry.shared.enabled(.firecrawl), let page = try? await Firecrawl.scrape(urlString, config: fc, maxChars: maxChars),
           !page.text.isEmpty {
            return page
        }
        guard let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" else {
            throw NexusError.generic("Invalid URL: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, http) = try await NetworkGate.shared.data(for: req, feature: .webResearch, summary: "Fetch \(url.host ?? "")")
        guard (200..<400).contains(http.statusCode) else { throw NexusError.provider("HTTP \(http.statusCode) for \(url.host ?? "")") }
        let html = String(data: data.prefix(3_000_000), encoding: .utf8) ?? String(decoding: data.prefix(3_000_000), as: UTF8.self)
        var title = url.host ?? urlString
        if let r = html.range(of: "<title[^>]*>([\\s\\S]*?)</title>", options: [.regularExpression, .caseInsensitive]) {
            title = HTMLText.strip(String(html[r]))
        }
        // Prefer <article>/<main> when present.
        var body = html
        for tag in ["article", "main"] {
            if let r = html.range(of: "<\(tag)[\\s\\S]*?</\(tag)>", options: [.regularExpression, .caseInsensitive]) {
                body = String(html[r]); break
            }
        }
        let text = HTMLText.strip(body)
        return Page(title: title.truncated(to: 120), text: String(text.prefix(maxChars)))
    }
}
