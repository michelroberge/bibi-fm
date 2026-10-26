import Foundation

public enum WebSearch {
    /// Top result snippets from DuckDuckGo's HTML endpoint (no API key; best effort). Callers must send only
    /// generic terms (vendor and product names), never the user's hostnames or addresses.
    public static func search(_ query: String, fetcher: Fetcher, limit: Int = 3) async -> [String] {
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        let body = Data((comps.percentEncodedQuery ?? "").utf8)
        guard let data = try? await fetcher.post("https://html.duckduckgo.com/html/", body: body,
                                                 contentType: "application/x-www-form-urlencoded", sentSummary: "q=\(query)") else {
            return []
        }
        let page = String(decoding: data.prefix(300_000), as: UTF8.self)
        let titles = Re.all("class=\"result__a\"[^>]*>(.*?)</a>", page).map { $0[1] }
        let snippets = Re.all("class=\"result__snippet\"[^>]*>(.*?)</a>", page).map { $0[1] }
        return zip(titles, snippets).prefix(limit).map { "\(HTML.text($0)): \(HTML.text($1).prefix(200))" }
    }
}
