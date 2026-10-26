import Foundation

public struct OfflineError: Error, CustomStringConvertible {
    public let what: String
    public var description: String { "\(what) needs --online" }
}

/// The only way skills reach the internet. Refuses when offline and logs every request to the run's audit trail.
public struct Fetcher: Sendable {
    public let online: Bool
    let record: @Sendable (NetworkEntry) -> Void
    static let userAgent = "Mozilla/5.0 (Macintosh) bibi/\(Bibi.version)"

    public init(online: Bool, record: @escaping @Sendable (NetworkEntry) -> Void = { _ in }) {
        self.online = online; self.record = record
    }

    public func get(_ url: String, timeout: Double = 10) async throws -> Data {
        try await request("GET", url, body: nil, contentType: nil, timeout: timeout)
    }

    public func post(_ url: String, body: Data, contentType: String, sentSummary: String? = nil, timeout: Double = 15) async throws -> Data {
        try await request("POST", url, body: body, contentType: contentType, timeout: timeout, sentSummary: sentSummary)
    }

    func request(_ method: String, _ url: String, body: Data?, contentType: String?, timeout: Double,
                 sentSummary: String? = nil) async throws -> Data {
        let sent = sentSummary ?? body.map { String(decoding: $0.prefix(500), as: UTF8.self) }
        guard online else {
            record(NetworkEntry(time: Date(), method: method, url: url, sent: sent, status: nil, error: "blocked: offline"))
            throw OfflineError(what: url)
        }
        guard let u = URL(string: url) else { throw ActionError("bad URL \(url)") }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            record(NetworkEntry(time: Date(), method: method, url: url, sent: sent, status: status, error: nil))
            guard (200..<300).contains(status) else { throw ActionError("\(u.host ?? url) answered HTTP \(status)") }
            return data
        } catch let e as ActionError {
            throw e
        } catch {
            record(NetworkEntry(time: Date(), method: method, url: url, sent: sent, status: nil, error: "\(error.localizedDescription)"))
            throw error
        }
    }

    /// For commands that contact the network themselves (brew outdated, softwareupdate -l): gate and log them.
    public func command(_ argv: [String], timeout: Double = 120) async throws -> CommandOutput {
        let source = Shell.join(argv)
        guard online else {
            record(NetworkEntry(time: Date(), method: "EXEC", url: source, sent: nil, status: nil, error: "blocked: offline"))
            throw OfflineError(what: source)
        }
        let out = await Command.run(argv, timeout: timeout)
        record(NetworkEntry(time: Date(), method: "EXEC", url: source, sent: nil, status: Int(out.status),
                            error: out.ok ? nil : String(out.stderr.prefix(200))))
        return out
    }
}
