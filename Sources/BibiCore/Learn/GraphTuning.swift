import Foundation

/// Fine-tuning the graph behind the skills (web Settings → Skills): what chat matches a skill on, the example
/// requests it learns from, and the steps of learned skills. Built-in values stay the defaults; the user's edits
/// are overrides in `props.tuned` that sync leaves alone and that can be reset.
public struct GraphTuning: Sendable {
    public let graph: GraphStore
    public let harness: Harness

    public init(graph: GraphStore, harness: Harness) { self.graph = graph; self.harness = harness }

    public struct Example: Codable, Sendable {
        public var id: String
        public var text: String
        public var source: String  // seed, manual, learned
        public var status: String
        /// The `matched` edge from the example to this skill: frequently matched examples rank higher.
        public var weight: Double
        public var steps: [PlannedStep]
        public var tuned: [String]
    }

    public struct View: Codable, Sendable {
        public var skill: SkillLibrary.SkillView
        public var keywords: String
        public var defaultKeywords: String
        public var text: String
        public var defaultText: String
        public var tuned: [String]
        public var examples: [Example]
        /// Actions the skill's code declares (fixed) and ones linked here.
        public var codeActions: [String]
        public var actions: [String]
    }

    /// Changes that only make sense one way are refused with a reason the page shows.
    func skillNode(_ name: String) throws -> GraphNode {
        let id = name.hasPrefix("skill:") ? name : GraphSync.skillID(name)
        guard let n = graph.node(id), n.kind == "skill" else { throw ActionError("no skill \(name)") }
        return n
    }

    public func view(_ name: String) throws -> View {
        let n = try skillNode(name)
        let tuned = n.props["tuned"]?.object?.keys.sorted() ?? []
        return View(skill: SkillLibrary.view(n, graph: graph), keywords: GraphSync.keywords(n),
                    defaultKeywords: n.props["keywords"]?.string ?? "", text: GraphSync.text(n), defaultText: n.text, tuned: tuned,
                    examples: examples(of: n).map { example($0, skill: n.id) },
                    codeActions: n.props["actions"]?.strings ?? [],
                    actions: graph.edges(from: n.id, kind: "uses").map { String($0.dst.dropFirst("action:".count)) })
    }

    /// Intents linked to the skill, and seeds and manual examples whose steps belong to it, most matched first.
    func examples(of n: GraphNode, limit: Int = 60) -> [GraphNode] {
        var ids = Set(graph.edges(from: n.id, kind: "example").map(\.dst) + graph.edges(to: n.id, kind: "matched").map(\.src))
        for i in graph.nodes(kind: "intent") where i.props["seed"] != nil || i.props["source"]?.string == "manual" {
            if Self.owner(of: SkillMiner.steps(i), graph: graph) == n.id { ids.insert(i.id) }
        }
        return ids.compactMap { graph.node($0) }.filter { $0.kind == "intent" }
            .sorted { (weight($0.id, n.id), $0.updated) > (weight($1.id, n.id), $1.updated) }.prefix(limit).map { $0 }
    }

    func weight(_ intent: String, _ skill: String) -> Double {
        graph.edges(from: intent, kind: "matched").first { $0.dst == skill }?.weight ?? 0
    }

    func example(_ i: GraphNode, skill: String) -> Example {
        Example(id: i.id, text: GraphSync.text(i), source: Self.source(i), status: i.status, weight: weight(i.id, skill),
                steps: SkillMiner.steps(i), tuned: i.props["tuned"]?.object?.keys.sorted() ?? [])
    }

    static func source(_ i: GraphNode) -> String {
        i.props["seed"] != nil ? "seed" : i.props["source"]?.string == "manual" ? "manual" : "learned"
    }

    /// The skill node steps belong to: the skill they run, the skill owning their action, or generic.
    public static func owner(of steps: [PlannedStep], graph: GraphStore) -> String {
        for s in steps {
            if s.tool.hasPrefix("skill:") { return GraphSync.skillID(String(s.tool.dropFirst(6))) }
            if s.tool.hasPrefix("action:"), let src = graph.edges(to: "action:" + s.tool.dropFirst(7), kind: "uses").first?.src { return src }
        }
        return GraphSync.root
    }

    // MARK: overrides

    /// Sets (non-nil) or resets (empty) the keywords and description chat matches the skill on.
    @discardableResult
    public func override(_ name: String, keywords: String? = nil, text: String? = nil) throws -> View {
        let n = try skillNode(name)
        setTuned(n.id, ["keywords": keywords, "text": text])
        if text != nil { graph.dropVector(n.id) }
        return try view(name)
    }

    /// Writes override fields: empty or equal to the default removes the override.
    func setTuned(_ id: String, _ fields: [String: String?]) {
        graph.update(id) { n in
            var tuned = n.props["tuned"]?.object ?? [:]
            for case let (key, value?) in fields {
                let v = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
                let base = key == "text" ? n.text : n.props[key]?.string ?? ""
                tuned[key] = v.isEmpty || v == base ? nil : .string(v)
            }
            n.props["tuned"] = tuned.isEmpty ? nil : .object(tuned)
        }
        graph.record("tuned", node: id, payload: .strings(fields.compactMap { $0.value == nil ? nil : $0.key }.sorted()))
    }

    // MARK: examples

    /// A request that should be answered by these steps. It counts for retrieval like a learned one, never for mining.
    @discardableResult
    public func addExample(_ name: String, text: String, steps: [PlannedStep]) throws -> View {
        let n = try skillNode(name)
        let text = Text.oneLine(text, max: 300)
        guard !text.isEmpty else { throw ActionError("the example needs a request") }
        try check(steps)
        let id = "intent:manual-" + Hashing.short(text + UUID().uuidString)
        graph.upsert(GraphNode(id: id, kind: "intent", name: text, text: text,
                               props: ["question": .string(text), "intent": .string(text), "source": .string("manual"),
                                       "outcome": .string("ok"), "steps": Self.encode(steps),
                                       "signature": .string(steps.map(\.signature).joined(separator: ">"))]))
        graph.link(n.id, id, "example")
        graph.link(id, n.id, "matched")
        graph.record("tuned", node: id, payload: .string("added"))
        return try view(name)
    }

    /// Edits an example. A seed's text and steps become overrides (the code re-syncs seeds); others change in place.
    @discardableResult
    public func updateExample(_ name: String, id: String, text: String? = nil, steps: [PlannedStep]? = nil, weight: Double? = nil,
                              status: String? = nil) throws -> View {
        let n = try skillNode(name)
        guard let i = graph.node(id), i.kind == "intent" else { throw ActionError("no example \(id)") }
        if let steps { try check(steps) }
        if let status, !["active", "disabled"].contains(status) { throw ActionError("an example is active or disabled, not \(status)") }
        let text = text.map { Text.oneLine($0, max: 300) }
        if text?.isEmpty == true { throw ActionError("the example needs a request") }
        if i.props["seed"] != nil {
            if let text { setTuned(id, ["text": text]) }
            if let steps {
                graph.update(id) { n in
                    var tuned = n.props["tuned"]?.object ?? [:]
                    tuned["steps"] = steps == Self.decode(n.props["steps"]) ? nil : Self.encode(steps)
                    n.props["tuned"] = tuned.isEmpty ? nil : .object(tuned)
                }
            }
        } else if text != nil || steps != nil {
            graph.update(id) { n in
                if let text { n.name = text; n.text = text }
                if let steps {
                    n.props["steps"] = Self.encode(steps)
                    n.props["signature"] = .string(steps.map(\.signature).joined(separator: ">"))
                }
            }
        }
        if let status { graph.setStatus(id, status) }
        if let weight { graph.link(id, n.id, "matched", weight: max(0, min(1000, weight))) }
        graph.record("tuned", node: id, payload: .string("edited"))
        return try view(name)
    }

    /// A manual example is deleted, a learned one stops being this skill's example, a seed is disabled.
    @discardableResult
    public func removeExample(_ name: String, id: String) throws -> View {
        let n = try skillNode(name)
        guard let i = graph.node(id), i.kind == "intent" else { throw ActionError("no example \(id)") }
        switch Self.source(i) {
        case "manual": graph.delete(id)
        case "seed": graph.setStatus(id, "disabled")
        default:
            graph.unlink(n.id, id, "example")
            graph.unlink(id, n.id, "matched")
        }
        graph.record("tuned", node: id, payload: .string("removed"))
        return try view(name)
    }

    // MARK: actions and steps

    /// Links or unlinks a registry action. The actions a skill's code declares are re-linked at startup, so they stay.
    @discardableResult
    public func linkAction(_ name: String, action: String, linked: Bool) throws -> View {
        let n = try skillNode(name)
        guard harness.registry.spec(action) != nil, graph.node("action:" + action) != nil else { throw ActionError("no action \(action)") }
        if linked {
            graph.link(n.id, "action:" + action, "uses")
        } else {
            guard !(n.props["actions"]?.strings ?? []).contains(action) else { throw ActionError("\(n.name)'s code declares \(action)") }
            graph.unlink(n.id, "action:" + action, "uses")
        }
        graph.record("tuned", node: n.id, payload: .string((linked ? "linked " : "unlinked ") + action))
        return try view(name)
    }

    /// Replaces a learned skill's steps and parameters.
    @discardableResult
    public func setSteps(_ name: String, steps: [PlannedStep], params: [String]) throws -> View {
        let n = try skillNode(name)
        guard n.props["source"]?.string == "learned" else { throw ActionError("only a learned skill's steps can be edited") }
        guard !steps.isEmpty else { throw ActionError("a skill needs at least one step") }
        let params = params.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let bad = params.first(where: { !Re.test("^[a-z_][a-z0-9_]*$", $0) }) {
            throw ActionError("parameter \(bad): use lowercase letters, digits and _")
        }
        try check(steps, params: params)
        graph.update(n.id) { n in
            n.props["steps"] = Self.encode(steps)
            n.props["params"] = .strings(params)
            n.props["signature"] = .string(steps.map(\.signature).joined(separator: ">"))
        }
        graph.record("tuned", node: n.id, payload: .string("steps"))
        harness.reloadLearned()
        return try view(name)
    }

    func check(_ steps: [PlannedStep], params: [String] = []) throws {
        let problems = steps.compactMap { Self.problem($0, params: params, registry: harness.registry, policy: harness.policy, graph: graph) }
        if !problems.isEmpty { throw ActionError(problems.joined(separator: "; ")) }
    }

    /// Why a step can't be part of a skill or example, or nil if it can. `{param}` slots must be declared.
    public static func problem(_ s: PlannedStep, params: [String], registry: ActionRegistry, policy: SafetyPolicy,
                               graph: GraphStore) -> String? {
        let undeclared = s.args.flatMap { Re.all(#"\{([A-Za-z0-9_]+)\}"#, $0).compactMap(\.last) }.filter { !params.contains($0) }
        if let slot = undeclared.first { return "\(s.tool): {\(slot)} isn't a parameter" }
        switch s.tool {
        case "command":
            guard !s.args.isEmpty else { return "command: the program is missing" }
            // Slots hold a value when the skill runs; a stand-in lets the rest of the command be checked now.
            let argv = s.args.map { $0.replacingOccurrences(of: #"\{[A-Za-z0-9_]+\}"#, with: "x", options: .regularExpression) }
            return CommandPolicy.classify(argv, policy: policy).refusal.map { "\(Shell.join(s.args)): \($0)" }
        case let t where t.hasPrefix("action:"):
            return registry.spec(String(t.dropFirst(7))) == nil ? "\(t): no such action" : nil
        case let t where t.hasPrefix("skill:"):
            guard let n = graph.node(t), n.kind == "skill", n.status == "active" else { return "\(t): no such skill" }
            return nil
        case let t where t.hasPrefix("app:"):
            return t.count > 4 ? nil : "app: the app name is missing"
        default:
            return "\(s.tool): unknown tool (use command, action:, skill: or app:)"
        }
    }

    static func encode(_ steps: [PlannedStep]) -> JSONValue { (try? JSON.decode(JSONValue.self, from: JSON.string(steps))) ?? .array([]) }
    static func decode(_ v: JSONValue?) -> [PlannedStep] { v.flatMap { try? JSON.decode([PlannedStep].self, from: JSON.string($0)) } ?? [] }
}

// MARK: - advanced: any node or edge

extension GraphTuning {
    public struct NodeView: Codable, Sendable {
        public var node: GraphNode
        public var out: [GraphEdge]
        public var into: [GraphEdge]
        public var stats: [String: Int]
        /// Why name, text and props can't be edited here (bibi rewrites them), or nil.
        public var locked: String?
    }

    public static let edgeKinds: Set<String> = ["child_of", "uses", "contains", "matched", "example", "used", "has_version",
                                                "derived_from", "from"]
    public static let statuses: Set<String> = ["active", "candidate", "dismissed", "disabled", "retired"]

    /// Nodes bibi rewrites from its code or history: editing them here would be undone or bypass versioning.
    func locked(_ n: GraphNode) -> String? {
        if n.id == GraphSync.root { return "the generic skill is fixed" }
        if n.props["source"]?.string == "builtin" { return "a built-in skill: tune its keywords and description under Settings → Skills" }
        if n.props["seed"] != nil { return "a starter example: edit it under Settings → Examples" }
        switch n.kind {
        case "action", "namespace": return "bibi rebuilds \(n.kind)s from its code"
        case "prompt_version": return "a past version: edit the prompt itself to add a version"
        default: return nil
        }
    }

    public func kinds() -> [String: Int] { graph.kinds() }

    public func nodes(kind: String?, query: String, limit: Int = 200) -> [GraphNode] {
        let kind = kind?.isEmpty == false ? kind : nil
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return graph.search(query, kind: kind, limit: limit) }
        guard let kind else { return [] }
        return Array(graph.nodes(kind: kind).prefix(limit))
    }

    public func node(_ id: String) throws -> NodeView {
        guard let n = graph.node(id) else { throw ActionError("no node \(id)") }
        return NodeView(node: n, out: graph.edges(from: id), into: graph.edges(to: id), stats: graph.stats(id), locked: locked(n))
    }

    /// Edits a node. A prompt's new text becomes a new version (so it can be rolled back); id and kind never change.
    @discardableResult
    public func updateNode(_ id: String, name: String? = nil, text: String? = nil, status: String? = nil,
                           props: [String: JSONValue]? = nil) throws -> NodeView {
        guard let n = graph.node(id) else { throw ActionError("no node \(id)") }
        if name != nil || text != nil || props != nil, let why = locked(n) { throw ActionError(why) }
        if let status {
            guard id != GraphSync.root else { throw ActionError("the generic skill is fixed") }
            guard Self.statuses.contains(status) else { throw ActionError("unknown status \(status)") }
        }
        if n.kind == "prompt", let text {
            if let builtIn = harness.promptCatalog.first(where: { $0.id == n.name })?.builtIn {
                PromptBook(graph).override(n.name, text: String(text.prefix(4000)), builtIn: builtIn)
            } else {
                PromptBook(graph).revise(n.name, text: String(text.prefix(4000)), reason: "edited in Settings")
            }
        }
        graph.update(id) { n in
            if let name { n.name = Text.oneLine(name, max: 200) }
            if let text, n.kind != "prompt" { n.text = String(text.prefix(4000)) }
            if let status { n.status = status }
            if let props { n.props = props }
        }
        graph.record("tuned", node: id, payload: .string("edited"))
        if n.kind == "skill" { harness.reloadLearned() }
        return try node(id)
    }

    public func deleteNode(_ id: String) throws {
        guard let n = graph.node(id) else { throw ActionError("no node \(id)") }
        if let why = locked(n) { throw ActionError(why) }
        if n.kind == "prompt" { throw ActionError("prompts are versioned; edit the text instead") }
        graph.delete(id)
        graph.record("tuned", node: id, payload: .string("deleted"))
        if n.kind == "skill" { harness.reloadLearned() }
    }

    /// Adds an edge, changes its weight, or removes it.
    public func edge(_ src: String, _ dst: String, _ kind: String, weight: Double?, remove: Bool) throws {
        guard Self.edgeKinds.contains(kind) else { throw ActionError("unknown edge kind \(kind)") }
        guard graph.node(src) != nil, graph.node(dst) != nil else { throw ActionError("both ends must be existing nodes") }
        if remove {
            graph.unlink(src, dst, kind)
        } else {
            let old = graph.edges(from: src, kind: kind).first { $0.dst == dst }
            graph.link(src, dst, kind, weight: max(0, min(1000, weight ?? old?.weight ?? 1)), props: old?.props ?? [:])
        }
        graph.record("tuned", node: src, payload: .string("\(remove ? "unlinked" : "linked") \(kind) \(dst)"))
        if kind == "child_of" || kind == "uses" { harness.reloadLearned() }
    }
}
