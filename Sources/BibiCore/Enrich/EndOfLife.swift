import Foundation

/// Support status from endoflife.date. Sends only the product name (python, nodejs, go, ruby, macos...).
public enum EndOfLife {
    public struct Cycle: Sendable, Codable {
        public var cycle: String
        public var eol: JSONValue?  // date string or bool
        public var latest: String?
        public var lts: JSONValue?

        public var eolDate: Date? {
            guard let s = eol?.string else { return nil }
            return ISO8601DateFormatter.date(s)
        }

        /// True if past end of life (a past date or `true`).
        public func isEOL(now: Date = Date()) -> Bool {
            if let b = eol?.bool { return b }
            return eolDate.map { $0 < now } ?? false
        }
    }

    public static func cycles(_ product: String, fetcher: Fetcher) async throws -> [Cycle] {
        let data = try await fetcher.get("https://endoflife.date/api/\(product).json")
        return try JSON.decoder.decode([Cycle].self, from: data)
    }

    /// The cycle a version belongs to: the longest cycle id that prefixes it ("3.11.4" -> "3.11", "20.1.0" -> "20").
    public static func match(_ version: String, in cycles: [Cycle]) -> Cycle? {
        cycles.filter { version == $0.cycle || version.hasPrefix($0.cycle + ".") }.max { $0.cycle.count < $1.cycle.count }
    }
}

extension ISO8601DateFormatter {
    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }
}
