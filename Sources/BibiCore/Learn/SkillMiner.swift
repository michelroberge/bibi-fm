import Foundation

/// Notices requests that keep coming back and drafts a skill for them, which the user can accept.
///
/// Every request that ran successfully is an `intent` node with the steps that ran and their signature
/// (tools and programs). Intents with the same signature and a similar phrasing form a cluster; once a cluster has
/// `minOccurrences` members and no skill covers it, the steps are generalized (arguments that differ become
/// `{param}` slots) into a `candidate` skill.
public struct SkillMiner: Sendable {
    let graph: GraphStore
    let model: any LanguageModel
    let prompts: PromptBook
    public static let minOccurrences = 3
    public static let similarity = 0.65

    public init(graph: GraphStore, model: any LanguageModel, prompts: PromptBook) {
        self.graph = graph; self.model = model; self.prompts = prompts
    }

    static let draftInstructions = """
    You name a reusable skill that bibi, a Mac assistant, learned because the user asked for the same thing several times.
    name: two to four lowercase words, like "check free disk space".
    help: one sentence saying what the skill does, starting with a verb.
    """

    public static func steps(_ n: GraphNode) -> [PlannedStep] {
        n.props["steps"].flatMap { try? JSON.decode([PlannedStep].self, from: JSON.string($0)) } ?? []
    }

    /// The intents that ran successfully with the same signature as `intent` and similar wording.
    public func cluster(for intent: GraphNode) -> [GraphNode] {
        guard let sig = intent.props["signature"]?.string else { return [] }
        let v = graph.vector(intent.id)
        return graph.nodes(kind: "intent").filter { n in
            n.props["outcome"]?.string == "ok" && n.props["seed"] == nil && n.props["signature"]?.string == sig
                && (n.id == intent.id || Similarity.score(intent.name, v, n.name, graph.vector(n.id)) >= Self.similarity)
        }
    }

    /// Call after a request ran successfully. Returns a new candidate skill, if one was drafted.
    public func observe(_ intentID: String) async -> GraphNode? {
        guard let intent = graph.node(intentID), let sig = intent.props["signature"]?.string else { return nil }
        let members = cluster(for: intent)
        guard members.count >= Self.minOccurrences else { return nil }

        // Already covered: a skill with this signature that is active, proposed, or dismissed at this size.
        for s in graph.nodes(kind: "skill") where s.props["signature"]?.string == sig {
            let examples = Set(s.props["examples"]?.strings ?? [])
            let overlaps = members.contains { examples.contains($0.id) }
                || Similarity.jaccard(s.props["intent"]?.string ?? "", intent.name) >= 0.3
            guard overlaps else { continue }
            if s.status == "dismissed" && members.count < 2 * Int(s.props["size"]?.int ?? 0) { return nil }
            if s.status != "dismissed" {
                for m in members { graph.link(s.id, m.id, "example") }
                return nil
            }
        }

        guard let (steps, params) = Self.generalize(members.map(Self.steps)) else { return nil }
        let phrase = intent.props["intent"]?.string ?? intent.name
        var name = phrase, help = "Learned from your requests: \(phrase)."
        let prompt = "Requests:\n" + members.prefix(5).map { "- " + ($0.props["question"]?.string ?? $0.name) }.joined(separator: "\n")
            + "\nSteps:\n" + steps.map { "- \($0.tool) \(Shell.join($0.args))" }.joined(separator: "\n")
        if let r = try? await model.respond(prompt, instructions: prompts.text("learn.draft", default: Self.draftInstructions),
                                            schema: Schema("SkillDraft", [.init("name", .string, "two to four words"),
                                                                          .init("help", .string, "one sentence")])) {
            name = r["name"]?.string?.ifEmpty(name) ?? name
            help = r["help"]?.string?.ifEmpty(help) ?? help
        }
        var slug = "learned." + Text.slug(name)
        var n = 2
        while graph.node(GraphSync.skillID(slug)) != nil { slug = "learned." + Text.slug(name) + "-\(n)"; n += 1 }

        let node = GraphNode(id: GraphSync.skillID(slug), kind: "skill", name: slug,
                             text: help + "\n" + members.prefix(5).map { $0.props["question"]?.string ?? $0.name }.joined(separator: "\n"),
                             props: ["source": .string("learned"), "help": .string(help), "signature": .string(sig),
                                     "intent": .string(phrase), "params": .strings(params),
                                     "steps": (try? JSON.decode(JSONValue.self, from: JSON.string(steps))) ?? .array([]),
                                     "examples": .strings(members.map(\.id)), "size": .number(Double(members.count))],
                             status: "candidate")
        graph.upsert(node)
        graph.link(node.id, GraphSync.skillID("learned"), "child_of")
        for m in members { graph.link(node.id, m.id, "example") }
        graph.record("candidate", node: node.id, payload: .number(Double(members.count)))
        return node
    }

    /// Merges step lists that share a signature: equal arguments stay, differing ones become `{param}` slots
    /// (the same values in several places become the same slot). nil if the lists can't be aligned.
    public static func generalize(_ runs: [[PlannedStep]]) -> ([PlannedStep], [String])? {
        guard let first = runs.first, !first.isEmpty else { return nil }
        let length = first.map(\.args.count)
        let runs = runs.filter { $0.count == first.count && $0.map(\.args.count) == length }
        guard runs.count >= 2 else { return nil }
        var slots: [[String]: String] = [:], names: [String] = []
        func slot(_ values: [String], key: String?) -> String {
            if let s = slots[values] { return s }
            var base = key ?? (values.allSatisfy { $0.hasPrefix("/") || $0.hasPrefix("~") } ? "path"
                : values.allSatisfy { Int($0) != nil } ? "number" : "value")
            base = Text.slug(base, maxWords: 2).replacingOccurrences(of: "-", with: "_")
            var name = base, n = 2
            while names.contains(name) { name = base + "\(n)"; n += 1 }
            names.append(name)
            slots[values] = name
            return name
        }
        var out: [PlannedStep] = []
        for (i, step) in first.enumerated() {
            var s = step
            s.purpose = step.purpose
            for j in 0..<step.args.count {
                let values = runs.map { $0[i].args[j] }
                if Set(values).count == 1 { continue }
                // key=value parameters keep their key.
                let keys = Set(values.map { $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "" })
                if keys.count == 1, let key = keys.first, values.allSatisfy({ $0.contains("=") }) {
                    s.args[j] = key + "={" + slot(values.map { String($0.dropFirst(key.count + 1)) }, key: key) + "}"
                } else if j == 0 && step.tool == "command" {
                    return nil  // a different program is a different skill
                } else {
                    s.args[j] = "{" + slot(values, key: nil) + "}"
                }
            }
            out.append(s)
        }
        return (out, names)
    }
}
