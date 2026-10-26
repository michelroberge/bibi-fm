import Foundation

public struct FactChange: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case added, removed, changed }
    public var key: String
    public var kind: Kind
    public var item: String?
    public var from: JSONValue?
    public var to: JSONValue?

    public init(key: String, kind: Kind, item: String? = nil, from: JSONValue? = nil, to: JSONValue? = nil) {
        self.key = key; self.kind = kind; self.item = item; self.from = from; self.to = to
    }

    /// "listeners: added node:3000 (all interfaces)"
    public var text: String {
        let what = item.map { " \($0)" } ?? ""
        switch kind {
        case .added: return "\(key):\(what) is new" + (to.map { " (\(Self.show($0)))" } ?? "")
        case .removed: return "\(key):\(what) is gone" + (from.map { " (was \(Self.show($0)))" } ?? "")
        case .changed: return "\(key):\(what) changed from \(Self.show(from)) to \(Self.show(to))"
        }
    }

    static func show(_ v: JSONValue?) -> String {
        switch v {
        case .number(let n)? where n >= 1_048_576: return human(n)
        case .number(let n)? where n == n.rounded(): return String(Int(n))
        case .number(let n)?: return String(format: "%.1f", n)
        case .string(let s)?: return s
        case .bool(let b)?: return b ? "yes" : "no"
        case nil, .null?: return "nothing"
        default: return JSON.string(v)
        }
    }
}

public struct FactDiff: Codable, Sendable {
    public var baselineRun: String
    public var baselineDate: Date
    public var changes: [FactChange]
}

/// Thresholds so normal noise (a cache growing 3%) isn't reported as a change.
public struct FactsSpec: Sendable {
    public struct Threshold: Sendable {
        public var relative: Double
        public var absolute: Double
        public init(relative: Double = 0.2, absolute: Double = 0) { self.relative = relative; self.absolute = absolute }
    }
    public var thresholds: [String: Threshold]
    public init(_ thresholds: [String: Threshold] = [:]) { self.thresholds = thresholds }

    public static let bytes = Threshold(relative: 0.2, absolute: 100 * 1024 * 1024)
}

public enum Baseline {
    /// Compares two fact snapshots generically: string arrays as sets, numbers against thresholds,
    /// objects key by key, everything else by equality. Keys present on only one side are ignored
    /// (a new bibi version may add facts).
    public static func diff(old: [String: JSONValue], new: [String: JSONValue], spec: FactsSpec = FactsSpec()) -> [FactChange] {
        var out: [FactChange] = []
        for key in new.keys.sorted() {
            guard let a = old[key], let b = new[key] else { continue }
            let t = spec.thresholds[key] ?? FactsSpec.Threshold()
            out += compare(key, item: nil, a, b, t)
        }
        return out
    }

    static func compare(_ key: String, item: String?, _ a: JSONValue, _ b: JSONValue, _ t: FactsSpec.Threshold) -> [FactChange] {
        switch (a, b) {
        case (.array(let x), .array(let y)) where (x + y).allSatisfy({ $0.string != nil }):
            let sx = Set(x.compactMap(\.string)), sy = Set(y.compactMap(\.string))
            return sy.subtracting(sx).sorted().map { FactChange(key: key, kind: .added, item: $0) }
                + sx.subtracting(sy).sorted().map { FactChange(key: key, kind: .removed, item: $0) }
        case (.number(let x), .number(let y)):
            let delta = abs(y - x)
            guard delta > t.absolute, delta >= t.relative * max(abs(x), 1e-9) else { return [] }
            return [FactChange(key: key, kind: .changed, item: item, from: a, to: b)]
        case (.object(let x), .object(let y)):
            var out: [FactChange] = []
            for k in Set(x.keys).union(y.keys).sorted() {
                switch (x[k], y[k]) {
                case (nil, let v?): out.append(FactChange(key: key, kind: .added, item: k, to: v))
                case (let v?, nil): out.append(FactChange(key: key, kind: .removed, item: k, from: v))
                case (let v?, let w?): out += compare(key, item: k, v, w, t)
                default: break
                }
            }
            return out
        default:
            return a == b ? [] : [FactChange(key: key, kind: .changed, item: item, from: a, to: b)]
        }
    }
}
