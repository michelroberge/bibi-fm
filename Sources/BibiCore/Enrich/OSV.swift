import Foundation

/// Known vulnerabilities from OSV.dev. Sends ecosystem, package name and version only.
public enum OSV {
    public struct Package: Sendable, Hashable {
        public var ecosystem: String  // npm, PyPI, Go, crates.io, RubyGems, Maven
        public var name: String
        public var version: String
        public init(_ ecosystem: String, _ name: String, _ version: String) {
            self.ecosystem = ecosystem; self.name = name; self.version = version
        }
    }

    public struct Vuln: Sendable, Codable {
        public var id: String
        public var summary: String
    }

    struct BatchResponse: Decodable {
        struct Result: Decodable {
            struct V: Decodable { var id: String }
            var vulns: [V]?
        }
        var results: [Result]
    }

    struct Detail: Decodable {
        var id: String
        var summary: String?
        var details: String?
    }

    /// Vulnerability ids per package (only packages with at least one). Summaries are fetched for up to `detail` ids.
    public static func query(_ packages: [Package], fetcher: Fetcher, detail: Int = 15) async throws -> [Package: [Vuln]] {
        var out: [Package: [Vuln]] = [:]
        var detailed = 0
        for start in stride(from: 0, to: packages.count, by: 500) {
            let chunk = Array(packages[start..<min(start + 500, packages.count)])
            let body: [String: JSONValue] = ["queries": .array(chunk.map {
                .object(["package": .object(["name": .string($0.name), "ecosystem": .string($0.ecosystem)]), "version": .string($0.version)])
            })]
            let data = try await fetcher.post("https://api.osv.dev/v1/querybatch", body: JSON.encoder.encode(body),
                                              contentType: "application/json",
                                              sentSummary: "\(chunk.count) packages: " + chunk.prefix(5).map { "\($0.ecosystem)/\($0.name)@\($0.version)" }.joined(separator: ", "))
            let r = try JSON.decoder.decode(BatchResponse.self, from: data)
            for (pkg, result) in zip(chunk, r.results) {
                guard let vulns = result.vulns, !vulns.isEmpty else { continue }
                var list: [Vuln] = []
                for v in vulns {
                    var summary = ""
                    if detailed < detail, let d = try? await fetcher.get("https://api.osv.dev/v1/vulns/" + v.id),
                       let det = try? JSON.decoder.decode(Detail.self, from: d) {
                        summary = det.summary ?? String((det.details ?? "").prefix(160))
                        detailed += 1
                    }
                    list.append(Vuln(id: v.id, summary: summary))
                }
                out[pkg] = list
            }
        }
        return out
    }
}
