import Foundation

/// Small regex helpers over NSRegularExpression (patterns are cached).
public enum Re {
    private static let cache = Mutex<[String: NSRegularExpression]>([:])

    static func compile(_ pattern: String, _ ci: Bool) -> NSRegularExpression? {
        let key = (ci ? "i:" : "s:") + pattern
        if let r = cache.withLock({ $0[key] }) { return r }
        var opts: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        if ci { opts.insert(.caseInsensitive) }
        guard let r = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        cache.withLock { $0[key] = r }
        return r
    }

    public static func test(_ pattern: String, _ text: String, ci: Bool = false) -> Bool {
        compile(pattern, ci)?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Groups of the first match (index 0 = whole match); missing groups are "".
    public static func first(_ pattern: String, _ text: String, ci: Bool = false) -> [String]? {
        guard let r = compile(pattern, ci), let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return groups(m, text)
    }

    public static func all(_ pattern: String, _ text: String, ci: Bool = false) -> [[String]] {
        guard let r = compile(pattern, ci) else { return [] }
        return r.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { groups($0, text) }
    }

    public static func replace(_ pattern: String, _ text: String, with template: String, ci: Bool = false) -> String {
        guard let r = compile(pattern, ci) else { return text }
        return r.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func groups(_ m: NSTextCheckingResult, _ text: String) -> [String] {
        (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }
}

public enum HTML {
    public static func unescape(_ s: String) -> String {
        var out = s
        for (k, v) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return Re.replace("&#(\\d+);", out, with: "") // drop remaining numeric entities
    }

    public static func text(_ s: String) -> String {
        Re.replace("\\s+", unescape(Re.replace("<[^>]+>", s, with: "")), with: " ").trimmingCharacters(in: .whitespaces)
    }
}

public enum IPv4 {
    public static func parse(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let n = UInt32(p), n <= 255, !p.isEmpty, p.count <= 3 else { return nil }
            v = v << 8 | n
        }
        return v
    }

    public static func format(_ v: UInt32) -> String { "\(v >> 24).\(v >> 16 & 255).\(v >> 8 & 255).\(v & 255)" }

    public static func isIP(_ s: String) -> Bool { parse(s) != nil || s.contains(":") && inet_pton(AF_INET6, s, nil) == 1 }

    public static func prefixLength(mask: String) -> Int? { parse(mask).map { $0.nonzeroBitCount } }

    public static func isPrivate(_ s: String) -> Bool {
        guard let v = parse(s) else { return false }
        return v >> 24 == 10 || v >> 20 == 0xAC1 || v >> 16 == 0xC0A8 || v >> 16 == 0xA9FE || v >> 24 == 127
    }
}

public enum Text {
    /// Collapses whitespace and cuts to `max` characters with an ellipsis.
    public static func oneLine(_ s: String, max: Int) -> String {
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    /// Keeps the start and end of long output (where commands usually put headers and totals).
    public static func clip(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let head = s.prefix(max * 2 / 3), tail = s.suffix(max / 3)
        return head + "\n… (\(s.count - max) characters cut) …\n" + tail
    }

    /// Keeps the first of lines that differ only in numbers (timestamps, pids), noting how often each repeated.
    /// Log output is mostly repetition; this leaves room for the lines that differ.
    public static func collapseRepeats(_ s: String) -> String {
        var order: [String] = [], first: [String: String] = [:], count: [String: Int] = [:]
        for line in s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let key = String(line.filter { !$0.isNumber })
            if first[key] == nil { order.append(key); first[key] = line }
            count[key, default: 0] += 1
        }
        return order.map { k in count[k]! > 1 ? first[k]! + "  (×\(count[k]!))" : first[k]! }.joined(separator: "\n")
    }

    /// Lowercase words joined by dashes, for ids and names.
    public static func slug(_ s: String, maxWords: Int = 4) -> String {
        Similarity.tokens(s).filter { !Similarity.stopwords.contains($0) }.prefix(maxWords).joined(separator: "-").ifEmpty("skill")
    }
}
