import Foundation

/// The skill tree as the user sees it (web Skills page, `bibi skills`), and the user's decisions on learned skills.
public enum SkillLibrary {
    public struct SkillView: Codable, Sendable {
        public var id: String
        public var name: String
        public var help: String
        public var source: String  // builtin, learned
        public var status: String
        public var namespace: String
        public var stats: [String: Int]
        public var approvalRate: Double
        public var steps: [PlannedStep]?
        public var params: [String]?
        public var examples: [String]?
        public var guidance: String?
        public var guidanceVersions: Int?
    }

    public static func view(_ n: GraphNode, graph: GraphStore) -> SkillView {
        let book = PromptBook(graph)
        let learned = n.props["source"]?.string == "learned"
        let help = n.props["help"]?.string ?? String(n.text.split(separator: "\n").first ?? "")
        let guidance = book.versions("skill." + n.name)
        return SkillView(id: n.id, name: n.name, help: help, source: n.props["source"]?.string ?? "builtin", status: n.status,
                         namespace: n.id == GraphSync.root ? "" : String(n.name.split(separator: ".").first ?? ""),
                         stats: graph.stats(n.id), approvalRate: graph.approvalRate(n.id),
                         steps: learned ? SkillMiner.steps(n) : nil, params: learned ? n.props["params"]?.strings : nil,
                         examples: learned ? (n.props["examples"]?.strings ?? []).compactMap { graph.node($0)?.text }.prefix(5).map { $0 } : nil,
                         guidance: guidance.first?.text, guidanceVersions: guidance.isEmpty ? nil : guidance.count)
    }

    /// Every skill node except retired ones, generic first.
    public static func all(_ graph: GraphStore) -> [SkillView] {
        graph.nodes(kind: "skill").filter { $0.status != "retired" }
            .sorted { ($0.id == GraphSync.root ? "" : $0.name) < ($1.id == GraphSync.root ? "" : $1.name) }
            .map { view($0, graph: graph) }
    }

    /// accept (candidate → active), dismiss (candidate → dismissed), disable, enable. Reloads the harness's learned skills.
    @discardableResult
    public static func decide(_ id: String, _ verb: String, graph: GraphStore, harness: Harness) throws -> SkillView {
        let id = id.hasPrefix("skill:") ? id : GraphSync.skillID(id)
        guard let n = graph.node(id), n.kind == "skill" else { throw ActionError("no skill \(id)") }
        let next: String
        switch (verb, n.status) {
        case ("accept", "candidate"), ("accept", "dismissed"): next = "active"
        case ("dismiss", "candidate"): next = "dismissed"
        case ("disable", "active"): next = "disabled"
        case ("enable", "disabled"): next = "active"
        default: throw ActionError("can't \(verb) a skill that is \(n.status)")
        }
        if id == GraphSync.root { throw ActionError("the generic skill can't be changed") }
        graph.setStatus(id, next)
        graph.record(verb == "accept" ? "accepted" : verb == "dismiss" ? "dismissed" : verb + "d", node: id)
        harness.reloadLearned()
        return view(graph.node(id)!, graph: graph)
    }
}
