import Foundation

/// Every instruction bibi gives the model, stored as versioned prompt nodes so it can be tuned.
///
/// `prompt:<id>` is the head node (props.active = the active version id); versions are `prompt:<id>@<n>`, each linked
/// to the previous one with `derived_from`. The code's text is the default: it seeds version 1 and replaces the active
/// version when the code changes, unless someone (the user or bibi's tuning) revised it since. Such a revision is an
/// override (Settings shows it as one): it keeps its text when the built-in changes, and records the built-in text it
/// was made from (`basedOn`), so Settings can say when the built-in moved underneath it.
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
    public func revise(_ id: String, text: String, reason: String, basedOn: String? = nil) -> String {
        guard let graph else { return "" }
        let headID = Self.head(id)
        var head = graph.node(headID) ?? GraphNode(id: headID, kind: "prompt", name: id)
        let n = (head.props["versions"]?.int ?? 0) + 1
        let vid = "\(headID)@\(n)"
        graph.upsert(GraphNode(id: vid, kind: "prompt_version", name: "\(id) v\(n)", text: text,
                               props: ["reason": .string(reason), "n": .number(Double(n))]
                                   .merging(basedOn.map { ["basedOn": .string($0)] } ?? [:]) { a, _ in a }))
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
    public func addAvoid(_ id: String, default base: String, note: String, keep: Int? = nil) -> String {
        let keep = keep ?? Knobs(graph).int(.avoidKeep)
        let current = text(id, default: base)
        let lines = current.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var body = lines.filter { !$0.hasPrefix("Avoid: ") }
        while body.last?.isEmpty == true { body.removeLast() }
        let avoids = Array((lines.filter { $0.hasPrefix("Avoid: ") } + ["Avoid: " + Text.oneLine(note, max: 160)]).suffix(keep))
        return revise(id, text: (body + avoids).joined(separator: "\n"), reason: "user skipped: " + Text.oneLine(note, max: 80),
                      basedOn: base)
    }

    public func versions(_ id: String) -> [GraphNode] {
        graph?.neighbors(Self.head(id), kind: "has_version").sorted { ($0.props["n"]?.int ?? 0) > ($1.props["n"]?.int ?? 0) } ?? []
    }

    /// Rolls back to the previous version when the active one, after enough decisions, is approved clearly less often.
    /// Returns the version that is active afterwards if a rollback happened.
    @discardableResult
    public func evaluate(_ id: String, minDecisions: Int? = nil, margin: Double? = nil) -> String? {
        let minDecisions = minDecisions ?? Knobs(graph).int(.rollbackDecisions), margin = margin ?? Knobs(graph)[.rollbackMargin]
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

    // MARK: Settings

    /// A prompt as Settings shows it, read without creating anything.
    public struct State: Codable, Sendable {
        public var text: String
        /// nil = never used yet (the built-in applies).
        public var version: String?
        public var reason: String?
        /// The active text was written by the user or bibi's tuning, not taken from the code.
        public var overridden: Bool
        /// Overridden, and the built-in text changed since the override was made.
        public var stale: Bool
    }

    public func state(_ id: String, builtIn: String) -> State {
        guard let graph, let head = graph.node(Self.head(id)), let v = head.props["active"]?.string, let node = graph.node(v) else {
            return State(text: builtIn, version: nil, reason: nil, overridden: false, stale: false)
        }
        let reason = node.props["reason"]?.string ?? ""
        guard reason != "default" else { return State(text: builtIn, version: v, reason: reason, overridden: false, stale: false) }
        let based = node.props["basedOn"]?.string
        return State(text: node.text, version: v, reason: reason, overridden: true, stale: based != nil && based != builtIn)
    }

    /// Saves the user's text as the active version (an override), or reverts when it equals the built-in.
    @discardableResult
    public func override(_ id: String, text: String, builtIn: String) -> String {
        text == builtIn ? revert(id, builtIn: builtIn) ?? "" : revise(id, text: text, reason: "edited in Settings", basedOn: builtIn)
    }

    /// Back to the built-in text (which then follows the code again). Returns the new version, nil if not overridden.
    @discardableResult
    public func revert(_ id: String, builtIn: String) -> String? {
        guard state(id, builtIn: builtIn).overridden else { return nil }
        return revise(id, text: builtIn, reason: "default")
    }

    /// Makes an earlier version active again.
    public func activate(_ id: String, version: String) throws {
        guard let graph, let node = graph.node(version), node.kind == "prompt_version",
              graph.edges(from: Self.head(id), kind: "has_version").contains(where: { $0.dst == version }) else {
            throw ActionError("\(version) is not a version of \(id)")
        }
        graph.update(Self.head(id)) { $0.props["active"] = .string(version); $0.text = node.text }
        if node.status != "active" { graph.setStatus(version, "active") }
        graph.record("activated", node: version)
    }

    /// One version with how its proposals fared.
    public struct Version: Codable, Sendable {
        public var id: String
        public var n: Int
        public var text: String
        public var reason: String
        public var status: String
        public var created: Date
        public var stats: [String: Int]
        public var approvalRate: Double
        public var active: Bool
    }

    public func history(_ id: String) -> [Version] {
        guard let graph else { return [] }
        let active = graph.node(Self.head(id))?.props["active"]?.string
        return versions(id).map { v in
            Version(id: v.id, n: v.props["n"]?.int ?? 0, text: v.text, reason: v.props["reason"]?.string ?? "", status: v.status,
                    created: v.created, stats: graph.stats(v.id), approvalRate: graph.approvalRate(v.id), active: v.id == active)
        }
    }

    /// Deletes every version but the active one. Returns how many went.
    @discardableResult
    public func prune(_ id: String, dryRun: Bool = false) -> Int {
        guard let graph else { return 0 }
        let active = graph.node(Self.head(id))?.props["active"]?.string
        let old = versions(id).filter { $0.id != active }
        if !dryRun { for v in old { graph.delete(v.id) } }
        return old.count
    }
}
