import Foundation

/// Everything the web Settings page shows and changes, in one place: knobs, prompts, tools, apps, the command
/// policy, examples, memory, the database and backups. Built-in values ship in code; the user's changes are
/// overrides in bibi.db, and every list says which items are overridden so it is obvious what was fine-tuned.
public struct Settings: Sendable {
    public let graph: GraphStore
    public let harness: Harness

    public init(graph: GraphStore, harness: Harness) { self.graph = graph; self.harness = harness }

    var knobs: Knobs { Knobs(graph) }
    var prompts: PromptBook { PromptBook(graph) }
    var tuning: GraphTuning { GraphTuning(graph: graph, harness: harness) }

    // MARK: overview

    /// How many overrides each section has, and how many skills wait for a decision.
    public struct Overview: Codable, Sendable {
        public var knobs: Int
        public var prompts: Int
        public var stalePrompts: Int
        public var skills: Int
        public var examples: Int
        public var tools: Int
        public var policy: Int
        public var candidates: Int
        public var total: Int { knobs + prompts + skills + examples + tools + policy }
    }

    public func overview() -> Overview {
        let p = promptList()
        let tools = graph.nodes(kind: "action", status: "disabled").count + knobs.list(Knobs.appsDisabled).count
        let seeds = graph.nodes(kind: "intent").filter { $0.props["seed"] != nil && ($0.props["tuned"] != nil || $0.status == "disabled") }
        return Overview(knobs: Knob.all.filter { knobs.override($0) != nil }.count, prompts: p.filter(\.overridden).count,
                        stalePrompts: p.filter(\.stale).count,
                        skills: graph.nodes(kind: "skill").filter { $0.props["tuned"] != nil || $0.props["source"]?.string == "builtin" && $0.status == "disabled" }.count,
                        examples: seeds.count, tools: tools,
                        policy: knobs.list(Knobs.policyAllow).count + knobs.list(Knobs.policyBlock).count,
                        candidates: graph.nodes(kind: "skill", status: "candidate").count)
    }

    // MARK: knobs

    public struct KnobView: Codable, Sendable {
        public var knob: Knob
        public var value: Double
        public var overridden: Bool
    }

    public func knobList() -> [KnobView] {
        Knob.all.map { k in KnobView(knob: k, value: knobs[k], overridden: knobs.override(k) != nil) }
    }

    /// Sets a knob (nil = back to built-in). A value equal to the built-in removes the override.
    public func setKnob(_ id: String, _ value: Double?) throws {
        guard let k = Knob.named(id) else { throw ActionError("no setting \(id)") }
        knobs.set(k, value.flatMap { k.clamp($0) == k.builtIn ? nil : $0 })
        graph.record("tuned", node: "knob:" + id, payload: value.map { .number($0) } ?? .string("reset"))
    }

    // MARK: prompts

    public struct PromptView: Codable, Sendable {
        public var id: String
        public var title: String
        public var group: String
        public var purpose: String
        public var builtIn: String
        public var text: String
        public var overridden: Bool
        public var stale: Bool
        public var reason: String?
        /// Can be tried on its own (fragments are part of another call's prompt).
        public var tryable: Bool
        public var sample: String
        /// The schema's field descriptions: the model reads them too, but they stay in code.
        public var fields: [String]
        public var versions: [PromptBook.Version]?
    }

    func definition(_ id: String) throws -> PromptDefinition {
        guard let d = harness.promptCatalog.first(where: { $0.id == id }) else { throw ActionError("no prompt \(id)") }
        return d
    }

    func view(_ d: PromptDefinition, history: Bool = false) -> PromptView {
        let s = prompts.state(d.id, builtIn: d.builtIn)
        return PromptView(id: d.id, title: d.title, group: d.group, purpose: d.purpose, builtIn: d.builtIn, text: s.text,
                          overridden: s.overridden, stale: s.stale, reason: s.reason, tryable: d.schema != nil, sample: d.sample,
                          fields: d.schema.map { Self.fields($0) } ?? [], versions: history ? prompts.history(d.id) : nil)
    }

    static func fields(_ s: Schema, prefix: String = "") -> [String] {
        s.fields.flatMap { f -> [String] in
            let line = prefix + f.name + (f.description.map { ": " + $0 } ?? "")
            switch f.kind {
            case .object(let o), .array(.object(let o), _): return [line] + fields(o, prefix: prefix + f.name + ".")
            case .choice(let c): return [line + " (one of: " + c.prefix(8).joined(separator: ", ") + (c.count > 8 ? ", …" : "") + ")"]
            default: return [line]
            }
        }
    }

    public func promptList() -> [PromptView] { harness.promptCatalog.map { view($0) } }

    public func prompt(_ id: String) throws -> PromptView { view(try definition(id), history: true) }

    @discardableResult
    public func savePrompt(_ id: String, text: String) throws -> PromptView {
        let d = try definition(id)
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8000))
        guard !t.isEmpty || d.builtIn.isEmpty else { throw ActionError("the prompt can't be empty; revert it to use the built-in") }
        prompts.override(id, text: t, builtIn: d.builtIn)
        return try prompt(id)
    }

    @discardableResult
    public func revertPrompt(_ id: String) throws -> PromptView {
        let d = try definition(id)
        prompts.revert(id, builtIn: d.builtIn)
        return try prompt(id)
    }

    @discardableResult
    public func activatePrompt(_ id: String, version: String) throws -> PromptView {
        _ = try definition(id)
        try prompts.activate(id, version: version)
        return try prompt(id)
    }

    // MARK: tools

    public struct ActionView: Codable, Sendable {
        public var id: String
        public var summary: String
        public var privilege: String
        public var reversible: Bool
        public var kind: String?
        public var fields: [ActionField]
        /// How chat lists it and the words that make it relevant (nil: chat doesn't offer it by itself).
        public var hint: String?
        public var words: String?
        public var enabled: Bool
        /// Skills that use it.
        public var skills: [String]
    }

    public func actions() -> [ActionView] {
        harness.registry.all.filter(\.selectable).map { a in
            let node = graph.node("action:" + a.id)
            return ActionView(id: a.id, summary: a.summary, privilege: a.privilege.rawValue, reversible: a.reversible, kind: a.kind,
                              fields: a.fields, hint: ChatEngine.actionHints[a.id]?.hint, words: ChatEngine.actionHints[a.id]?.words,
                              enabled: node?.status != "disabled",
                              skills: graph.edges(to: "action:" + a.id, kind: "uses").compactMap { graph.node($0.src)?.name }.sorted())
        }
    }

    public func setAction(_ id: String, enabled: Bool) throws {
        guard harness.registry.spec(id) != nil, graph.node("action:" + id) != nil else { throw ActionError("no action \(id)") }
        graph.setStatus("action:" + id, enabled ? "active" : "disabled")
        graph.record("tuned", node: "action:" + id, payload: .string(enabled ? "enabled" : "disabled"))
    }

    /// What an action would do with these parameters; nothing runs.
    public func previewAction(_ id: String, params: [String: String]) throws -> Preview {
        guard harness.registry.spec(id) != nil else { throw ActionError("no action \(id)") }
        let env = harness.env(admin: NoAdminRunner(), reporter: SilentReporter())
        let spec = harness.registry.spec(id)!
        return harness.registry.preview(ActionCall(id, spec.normalize(params, env)), env)
    }

    public struct AppView: Codable, Sendable {
        public var bundleID: String
        public var name: String
        public var path: String
        public var commands: [String]
        public var classes: Int
        public var enabled: Bool
    }

    public func apps() -> [AppView] {
        let off = Set(knobs.list(Knobs.appsDisabled))
        return harness.apps.catalog.apps.sorted { $0.name.lowercased() < $1.name.lowercased() }.map { a in
            AppView(bundleID: a.bundleID, name: a.name, path: a.path, commands: a.commands.map(\.name), classes: a.classes.count,
                    enabled: !off.contains(a.bundleID))
        }
    }

    public func setApp(_ bundleID: String, enabled: Bool) {
        var off = knobs.list(Knobs.appsDisabled).filter { $0 != bundleID }
        if !enabled { off.append(bundleID) }
        knobs.setList(Knobs.appsDisabled, off)
        graph.record("tuned", node: "app:" + bundleID, payload: .string(enabled ? "enabled" : "disabled"))
    }

    public func rescanApps() -> Int {
        _ = harness.apps.catalog.scan()
        harness.apps.catalog.sync(graph)
        return harness.apps.catalog.apps.count
    }

    public struct Policy: Codable, Sendable {
        public var rules: [String: [String]]
        public var allow: [String]
        public var block: [String]
    }

    public func policy() -> Policy {
        Policy(rules: CommandPolicy.rules, allow: knobs.list(Knobs.policyAllow), block: knobs.list(Knobs.policyBlock))
    }

    /// Replaces the user's allow and block lists. Programs that run code, send mail or change files can't be allowed.
    @discardableResult
    public func setPolicy(allow: [String], block: [String]) throws -> Policy {
        let allow = allow.map { Paths.name($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
        if let bad = allow.first(where: { CommandPolicy.notAllowable($0) != nil }) {
            throw ActionError("\(bad) can't be allowed: \(CommandPolicy.notAllowable(bad)!)")
        }
        knobs.setList(Knobs.policyAllow, allow)
        knobs.setList(Knobs.policyBlock, block.map { Paths.name($0.trimmingCharacters(in: .whitespaces)) })
        graph.record("tuned", node: "policy", payload: .string("lists"))
        return policy()
    }

    public struct CommandCheck: Codable, Sendable {
        public var argv: [String]
        public var cls: String?
        public var refusal: String?
        public var rewrite: [String]
    }

    /// How bibi's rules would treat a command typed as a shell line (split like a shell would, without running it).
    public func checkCommand(_ line: String) -> CommandCheck {
        let argv = Shell.split(line)
        let v = CommandPolicy.classify(argv, policy: harness.policy)
        return CommandCheck(argv: v.argv, cls: v.refusal == nil ? v.cls.rawValue : nil, refusal: v.refusal,
                            rewrite: v.rewrite.map { "\($0.spec) \($0.params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))" })
    }

    // MARK: skills

    /// A learned skill written by hand: active at once (the user wrote it), or a candidate to decide on later.
    @discardableResult
    public func createSkill(name: String, help: String, keywords: String, params: [String], steps: [PlannedStep],
                            active: Bool = true) throws -> SkillLibrary.SkillView {
        let title = Text.oneLine(name, max: 60)
        guard !Text.slug(title).isEmpty else { throw ActionError("the skill needs a name") }
        let help = Text.oneLine(help, max: 300)
        guard !help.isEmpty else { throw ActionError("the skill needs a description") }
        guard !steps.isEmpty else { throw ActionError("a skill needs at least one step") }
        let params = params.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let bad = params.first(where: { !Re.test("^[a-z_][a-z0-9_]*$", $0) }) {
            throw ActionError("parameter \(bad): use lowercase letters, digits and _")
        }
        try tuning.check(steps, params: params)
        var slug = "learned." + Text.slug(title), n = 2
        while graph.node(GraphSync.skillID(slug)) != nil { slug = "learned." + Text.slug(title) + "-\(n)"; n += 1 }
        let node = GraphNode(id: GraphSync.skillID(slug), kind: "skill", name: slug, text: help,
                             props: ["source": .string("learned"), "origin": .string("manual"), "help": .string(help),
                                     "keywords": .string(Text.oneLine(keywords, max: 200)), "intent": .string(title),
                                     "params": .strings(params), "steps": GraphTuning.encode(steps),
                                     "signature": .string(steps.map(\.signature).joined(separator: ">")),
                                     "examples": .strings([]), "size": .number(0)],
                             status: active ? "active" : "candidate")
        graph.upsert(node)
        graph.link(node.id, GraphSync.skillID("learned"), "child_of")
        graph.record(active ? "accepted" : "candidate", node: node.id, payload: .string("manual"))
        harness.reloadLearned()
        return SkillLibrary.view(node, graph: graph)
    }

    /// Deletes a learned skill (built-in ones can only be hidden from chat).
    public func deleteSkill(_ name: String) throws {
        let id = name.hasPrefix("skill:") ? name : GraphSync.skillID(name)
        guard let n = graph.node(id), n.kind == "skill" else { throw ActionError("no skill \(name)") }
        guard n.props["source"]?.string == "learned" else { throw ActionError("\(n.name) is built in: hide it from chat instead") }
        graph.delete(id)
        graph.record("tuned", node: id, payload: .string("deleted"))
        harness.reloadLearned()
    }

    // MARK: examples

    public struct ExampleView: Codable, Sendable {
        public var id: String
        public var text: String
        public var builtIn: String
        public var source: String
        public var status: String
        public var skill: String
        public var steps: [PlannedStep]
        public var builtInSteps: [PlannedStep]
        public var overridden: Bool
        public var matched: Double
    }

    /// Requests that worked (seeds, ones added here, learned ones), newest first, filtered by words, source and skill.
    public func examples(query: String = "", source: String? = nil, skill: String? = nil, limit: Int = 300) -> [ExampleView] {
        let terms = Similarity.tokens(query)
        return graph.nodes(kind: "intent").filter { $0.props["outcome"]?.string == "ok" }.compactMap { i -> ExampleView? in
            let src = GraphTuning.source(i)
            if let source, !source.isEmpty, src != source { return nil }
            let owner = graph.node(GraphTuning.owner(of: SkillMiner.steps(i), graph: graph))?.name ?? "generic"
            if let skill, !skill.isEmpty, owner != skill { return nil }
            let text = GraphSync.text(i)
            if !terms.isEmpty, !terms.allSatisfy(text.lowercased().contains) { return nil }
            return ExampleView(id: i.id, text: text, builtIn: i.text, source: src, status: i.status, skill: owner, steps: SkillMiner.steps(i),
                               builtInSteps: GraphTuning.decode(i.props["steps"]),
                               overridden: src == "seed" && (i.props["tuned"] != nil || i.status == "disabled"),
                               matched: graph.edges(from: i.id, kind: "matched").reduce(0) { $0 + $1.weight })
        }
        .sorted { ($0.source == "seed" ? 1 : 0, $1.matched) < ($1.source == "seed" ? 1 : 0, $0.matched) }
        .prefix(limit).map { $0 }
    }

    /// A seed's overrides removed and the seed re-enabled.
    public func revertExample(_ id: String) throws {
        guard let i = graph.node(id), i.props["seed"] != nil else { throw ActionError("only a starter example has a built-in to go back to") }
        graph.update(id) { $0.props["tuned"] = nil; $0.status = "active" }
        graph.record("tuned", node: id, payload: .string("reverted"))
    }

    /// Deletes an example; a seed is disabled instead (it comes back with the code otherwise).
    public func deleteExample(_ id: String) throws {
        guard let i = graph.node(id), i.kind == "intent" else { throw ActionError("no example \(id)") }
        if i.props["seed"] != nil { graph.setStatus(id, "disabled") } else { graph.delete(id) }
        graph.record("tuned", node: id, payload: .string("deleted"))
    }

    // MARK: memory

    public struct FactView: Codable, Sendable {
        public var id: String
        public var subject: String
        public var statement: String
        public var updated: Date
        public var conversation: String?
    }

    public func facts(query: String = "") -> [FactView] {
        let nodes = query.trimmingCharacters(in: .whitespaces).isEmpty ? graph.nodes(kind: "fact") : graph.search(query, kind: "fact", limit: 200)
        return nodes.map { FactView(id: $0.id, subject: $0.name, statement: $0.text, updated: $0.updated, conversation: $0.props["conversation"]?.string) }
    }

    /// Adds a fact (no id) or edits one. Chat shows facts that relate to a request.
    @discardableResult
    public func saveFact(id: String?, subject: String, statement: String) throws -> FactView {
        let subject = Text.oneLine(subject, max: 80), statement = Text.oneLine(statement, max: 300)
        guard !subject.isEmpty, !statement.isEmpty else { throw ActionError("a fact needs a subject and a statement") }
        let fid = id ?? "fact:" + Hashing.short(Similarity.terms(subject).sorted().joined(separator: " ") + "manual")
        if let id, graph.node(id)?.kind != "fact" { throw ActionError("no fact \(id)") }
        var n = graph.node(fid) ?? GraphNode(id: fid, kind: "fact", name: subject, props: ["source": .string("manual")])
        n.name = subject
        n.text = statement
        graph.upsert(n)
        graph.dropVector(fid)
        return FactView(id: fid, subject: subject, statement: statement, updated: Date(), conversation: n.props["conversation"]?.string)
    }

    public func deleteFact(_ id: String) throws {
        guard graph.node(id)?.kind == "fact" else { throw ActionError("no fact \(id)") }
        graph.delete(id)
    }

    // MARK: data

    public struct DataView: Codable, Sendable {
        public var path: String
        public var bytes: Int64
        public var kinds: [String: Int]
        public var events: Int
        public var settings: Int
        public var runs: Int
        public var chats: Int
    }

    public func data() -> DataView {
        let runs = harness.store.list()
        return DataView(path: graph.path, bytes: graph.fileSize, kinds: graph.kinds(), events: graph.eventCount(),
                        settings: graph.settings().count, runs: runs.filter { $0.meta.skill != "chat" }.count,
                        chats: runs.filter { $0.meta.skill == "chat" }.count)
    }

    public func events(kind: String?, node: String?, limit: Int = 200) -> [GraphEvent] {
        graph.events(node: node?.isEmpty == false ? node : nil, kind: kind?.isEmpty == false ? kind : nil, limit: limit)
    }

    // MARK: backups

    public var backupDir: String { Paths.parent(graph.path) + "/backups" }

    public struct Backup: Codable, Sendable {
        public var name: String
        public var bytes: Int64
        public var created: Date
    }

    @discardableResult
    public func backup(label: String = "") throws -> Backup {
        let stamp = RunStore.stamp.string(from: Date())
        let name = "bibi-" + stamp + (label.isEmpty ? "" : "-" + Text.slug(label)) + ".db"
        var path = backupDir + "/" + name
        var n = 2
        while FileManager.default.fileExists(atPath: path) { path = backupDir + "/" + name.replacingOccurrences(of: ".db", with: "-\(n).db"); n += 1 }
        try graph.backup(to: path)
        return Backup(name: Paths.name(path), bytes: Self.size(path), created: Date())
    }

    static func size(_ path: String) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0 }

    public func backups() -> [Backup] {
        ((try? FileManager.default.contentsOfDirectory(atPath: backupDir)) ?? []).filter { $0.hasSuffix(".db") }.map { name in
            let p = backupDir + "/" + name
            let created = (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? Date.distantPast
            return Backup(name: name, bytes: Self.size(p), created: created)
        }.sorted { $0.created > $1.created }
    }

    /// Replaces bibi.db with a backup (after backing up the current one), then re-syncs built-ins.
    @discardableResult
    public func restore(_ name: String) throws -> Backup {
        guard !name.contains("/"), name.hasSuffix(".db"), FileManager.default.fileExists(atPath: backupDir + "/" + name) else {
            throw ActionError("no backup \(name)")
        }
        let safety = try backup(label: "before-restore")
        try graph.restore(from: backupDir + "/" + name)
        GraphSync.syncBuiltins(graph, skills: Array(harness.skills.values), registry: harness.registry)
        harness.reloadLearned()
        return safety
    }

    // MARK: export and import

    /// The user's fine-tuning as a file: overrides only (and, with `learned`, the skills, examples and facts bibi
    /// learned or you added). Built-in values are never exported, so importing it elsewhere keeps their code's.
    public func export(learned: Bool) -> JSONValue {
        var out: [String: JSONValue] = ["bibi": .string(Bibi.version), "exported": .string(ISO8601DateFormatter().string(from: Date()))]
        out["knobs"] = .object(Dictionary(uniqueKeysWithValues: Knob.all.compactMap { k in knobs.override(k).map { (k.id, .number($0)) } }))
        out["lists"] = .object(Dictionary(uniqueKeysWithValues: Knobs.lists.compactMap { key in
            let l = knobs.list(key)
            return l.isEmpty ? nil : (key, .strings(l))
        }))
        out["prompts"] = .object(Dictionary(uniqueKeysWithValues: promptList().filter(\.overridden).map { ($0.id, .string($0.text)) }))
        out["tuned"] = .object(Dictionary(uniqueKeysWithValues: (graph.nodes(kind: "skill") + graph.nodes(kind: "intent")).compactMap { n in
            n.props["tuned"].map { (n.id, $0) }
        }))
        out["disabled"] = .strings((graph.nodes(kind: "action", status: "disabled") + graph.nodes(kind: "skill", status: "disabled")
                                    + graph.nodes(kind: "intent", status: "disabled").filter { $0.props["seed"] != nil }).map(\.id))
        if learned {
            let skills = graph.nodes(kind: "skill").filter { $0.props["source"]?.string == "learned" }
            let examples = graph.nodes(kind: "intent").filter { $0.props["source"]?.string == "manual" }
            out["nodes"] = (try? JSON.decode(JSONValue.self, from: JSON.string(skills + examples + graph.nodes(kind: "fact")))) ?? .array([])
        }
        return .object(out)
    }

    public struct ImportReport: Codable, Sendable {
        public var knobs = 0, lists = 0, prompts = 0, tuned = 0, disabled = 0, nodes = 0
        public var skipped: [String] = []
    }

    /// Applies an export: its overrides win, its nodes are added when missing. Built-in values aren't touched.
    @discardableResult
    public func importOverrides(_ v: JSONValue) throws -> ImportReport {
        guard v["bibi"] != nil else { throw ActionError("not a bibi settings export") }
        var r = ImportReport()
        for (id, value) in v["knobs"]?.object ?? [:] {
            if let k = Knob.named(id), let x = value.number { knobs.set(k, x); r.knobs += 1 } else { r.skipped.append("knob " + id) }
        }
        for (key, value) in v["lists"]?.object ?? [:] where Knobs.lists.contains(key) {
            var items = value.strings ?? []
            if key == Knobs.policyAllow { items = items.filter { CommandPolicy.notAllowable($0) == nil } }
            knobs.setList(key, items)
            r.lists += 1
        }
        for (id, value) in v["prompts"]?.object ?? [:] {
            guard let d = harness.promptCatalog.first(where: { $0.id == id }), let text = value.string else { r.skipped.append("prompt " + id); continue }
            if prompts.state(id, builtIn: d.builtIn).text != text { prompts.override(id, text: text, builtIn: d.builtIn) }
            r.prompts += 1
        }
        if let nodes = v["nodes"], let list = try? JSON.decode([GraphNode].self, from: JSON.string(nodes)) {
            for n in list where ["skill", "intent", "fact"].contains(n.kind) {
                guard graph.node(n.id) == nil else { continue }
                graph.upsert(n)
                if n.kind == "skill" { graph.link(n.id, GraphSync.skillID("learned"), "child_of") }
                r.nodes += 1
            }
        }
        for (id, value) in v["tuned"]?.object ?? [:] {
            guard graph.node(id) != nil else { r.skipped.append("tuning of " + id); continue }
            graph.update(id) { $0.props["tuned"] = value }
            r.tuned += 1
        }
        for id in v["disabled"]?.strings ?? [] where graph.node(id) != nil {
            graph.setStatus(id, "disabled")
            r.disabled += 1
        }
        graph.record("tuned", node: "settings", payload: .string("imported"))
        harness.reloadLearned()
        return r
    }
}
