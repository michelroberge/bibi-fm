import Foundation

/// Every instruction bibi gives the model, stored as versioned prompt nodes so it can be tuned.
///
/// `prompt:<id>` is the head node (props.active = the active version id); versions are `prompt:<id>@<n>`, each linked
/// to the previous one with `derived_from`. The code's text is the default: it seeds version 1 and replaces the active
/// version when the code changes, unless someone (the user or bibi's tuning) revised it since.
/// Without a graph, `text` simply returns the default.
public struct PromptBook: Sendable {
    public let graph: GraphStore?

    public init(_ graph: GraphStore? = nil) { self.graph = graph }

    public static func head(_ id: String) -> String { "prompt:" + id }

    /// The active version's id and text.
    public func active(_ id: String, default text: String) -> (version: String, text: String) {
        guard let graph else { return ("", text) }
        let headID = Self.head(id)
        if let head = graph.node(headID), let v = head.props["active"]?.string, let node = graph.node(v) {
            if node.props["reason"]?.string == "default" && node.text != text {
                let nv = revise(id, text: text, reason: "default")
                return (nv, text)
            }
            return (v, node.text)
        }
        return (revise(id, text: text, reason: "default"), text)
    }

    public func text(_ id: String, default text: String) -> String { active(id, default: text).text }

    /// Adds a new version and makes it active. Returns its id.
    @discardableResult
    public func revise(_ id: String, text: String, reason: String) -> String {
        guard let graph else { return "" }
        let headID = Self.head(id)
        var head = graph.node(headID) ?? GraphNode(id: headID, kind: "prompt", name: id)
        let n = (head.props["versions"]?.int ?? 0) + 1
        let vid = "\(headID)@\(n)"
        graph.upsert(GraphNode(id: vid, kind: "prompt_version", name: "\(id) v\(n)", text: text,
                               props: ["reason": .string(reason), "n": .number(Double(n))]))
        if let prev = head.props["active"]?.string { graph.link(vid, prev, "derived_from") }
        graph.link(headID, vid, "has_version")
        head.props["versions"] = .number(Double(n))
        head.props["active"] = .string(vid)
        head.text = text
        graph.upsert(head)
        graph.record("revised", node: vid, payload: .string(reason))
        return vid
    }

    /// Appends an "Avoid:" note (keeping the newest `keep`) as a new version. Used when the user skips a proposal
    /// and says why.
    @discardableResult
    public func addAvoid(_ id: String, default base: String, note: String, keep: Int = 5) -> String {
        let current = text(id, default: base)
        let lines = current.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var body = lines.filter { !$0.hasPrefix("Avoid: ") }
        while body.last?.isEmpty == true { body.removeLast() }
        let avoids = Array((lines.filter { $0.hasPrefix("Avoid: ") } + ["Avoid: " + Text.oneLine(note, max: 160)]).suffix(keep))
        return revise(id, text: (body + avoids).joined(separator: "\n"), reason: "user skipped: " + Text.oneLine(note, max: 80))
    }

    public func versions(_ id: String) -> [GraphNode] {
        graph?.neighbors(Self.head(id), kind: "has_version").sorted { ($0.props["n"]?.int ?? 0) > ($1.props["n"]?.int ?? 0) } ?? []
    }

    /// Rolls back to the previous version when the active one, after enough decisions, is approved clearly less often.
    /// Returns the version that is active afterwards if a rollback happened.
    @discardableResult
    public func evaluate(_ id: String, minDecisions: Int = 10, margin: Double = 0.1) -> String? {
        guard let graph, let head = graph.node(Self.head(id)), let cur = head.props["active"]?.string,
              let prev = graph.edges(from: cur, kind: "derived_from").first?.dst else { return nil }
        let decided = { (s: [String: Int]) in s["approved", default: 0] + s["skipped", default: 0] }
        guard decided(graph.stats(cur)) >= minDecisions, decided(graph.stats(prev)) >= minDecisions / 2,
              graph.approvalRate(cur) < graph.approvalRate(prev) - margin else { return nil }
        graph.setStatus(cur, "rolled-back")
        graph.update(head.id) {
            $0.props["active"] = .string(prev)
            $0.text = graph.node(prev)?.text ?? $0.text
        }
        graph.record("rollback", node: cur, payload: .string(prev))
        return prev
    }
}
