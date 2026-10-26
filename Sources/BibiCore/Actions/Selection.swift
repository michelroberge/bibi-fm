import Foundation

public enum Selection {
    /// Parses "1,2,5", "1-3", "all" or "none" into 0-based indices.
    public static func parse(_ text: String, count: Int) throws -> [Int] {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if ["", "none", "n", "no", "q"].contains(t) { return [] }
        if ["all", "a"].contains(t) { return Array(0..<count) }
        var picked: [Int] = []
        for part in t.replacingOccurrences(of: " ", with: ",").split(separator: ",") {
            let bounds = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard let lo = Int(bounds[0]), bounds.count == 1 || Int(bounds[1]) != nil else {
                throw ArgError("not a number: '\(part)'")
            }
            let hi = bounds.count == 2 ? Int(bounds[1])! : lo
            for n in lo...max(lo, hi) {
                guard (1...count).contains(n) else { throw ArgError("\(n) is out of range 1-\(count)") }
                if !picked.contains(n - 1) { picked.append(n - 1) }
            }
        }
        return picked
    }
}
