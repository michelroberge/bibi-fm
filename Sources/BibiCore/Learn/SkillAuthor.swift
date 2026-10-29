import Foundation

/// `skills.create`: drafts a learned skill from the user's description ("show free space and the biggest files in
/// ~/Downloads"). The model writes it with the tools chat has; bibi keeps only steps its rules accept and saves the
/// draft as a candidate, so nothing runs until the user accepts it under Settings → Skills (and fine-tunes it there).
public struct SkillAuthor: Skill {
    public let name = "skills.create"
    public let help = "Drafts a new skill from your description of what it should do; you review it under Settings → Skills before it can run"
    public var keywords: String { "create make new build write teach skill automate routine shortcut" }
    public var params: [Param] {
        [Param(key: "request", flags: [], kind: .list, help: "what the skill should do, in your words", defaultValue: nil,
               metavar: "description", required: true),
         .option("name", "--name", metavar: "NAME", help: "the skill's name (bibi picks one otherwise)")]
    }

    let graph: GraphStore
    let registry: ActionRegistry

    public init(graph: GraphStore, registry: ActionRegistry) { self.graph = graph; self.registry = registry }

    static let instructions = """
    You write a reusable skill for bibi, an assistant on the user's Mac, from the user's description of what it should do.
    name: two to four lowercase words, like "check free disk space".
    help: one sentence saying what the skill does, starting with a verb.
    keywords: words a user would say when they want this skill, separated by spaces.
    params: names (lowercase, like path or count) for the values that change from one use to the next. Empty if none.
    steps: the steps that do it, at most 6, using only the listed tools. Put {name} in an argument where a parameter's value goes.
    For a command, args is the program and then each argument separately, like ["du", "-sh", "{path}"]. There is no shell: no pipes, redirections, ; or &&. Prefer read-only commands; anything that changes the Mac is shown to the user for approval each time.
    """

    static func schema(_ tools: [String]) -> Schema {
        Schema("SkillDraft", [
            .init("name", .string, "two to four words"),
            .init("help", .string, "one sentence"),
            .init("keywords", .string, "words that ask for this skill"),
            .init("params", .array(.string, max: 4), "parameter names"),
            .init("steps", .array(.object(Schema("Step", [
                .init("tool", .choice(tools)),
                .init("args", .array(.string, max: 16), "command: the program, then each argument; action: key=value; skill: its options"),
                .init("purpose", .string, "a few words: why this step"),
            ])), max: 6)),
        ])
    }

    /// The tools a skill can use: any command, the registry's chat actions, and the other active skills.
    func tools() -> (ids: [String], text: String) {
        var ids = ["command"]
        var lines = [#"- command: any program; args = the program, then each argument. Examples: ["df", "-h", "/"] free disk space; ["du", "-sh", "{path}"] folder size; ["ls", "-lS", "{path}"] files by size"#]
        for (id, a) in ChatEngine.actionHints.sorted(by: { $0.key < $1.key }) {
            guard let spec = registry.spec(id) else { continue }
            ids.append("action:" + id)
            lines.append("- action:\(id) \(a.hint): \(spec.summary)")
        }
        for n in graph.nodes(kind: "skill", status: "active") where n.id != GraphSync.root && n.name != name {
            ids.append("skill:" + n.name)
            lines.append("- skill:\(n.name): \(Text.oneLine(n.props["help"]?.string ?? GraphSync.text(n), max: 160))")
        }
        return (ids, lines.joined(separator: "\n"))
    }

    public func run(_ args: Args, _ ctx: SkillContext) async throws -> SkillResult {
        let request = args.list("request").joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { throw SkillError("describe what the skill should do") }
        let tools = tools()
        ctx.reporter.progress("Drafting a skill")
        let draft = try await ctx.model.respond("Tools:\n\(tools.text)\n\nThe user wants a skill that: \(request)",
                                                instructions: ctx.prompts.text("learn.create", default: Self.instructions),
                                                schema: Self.schema(tools.ids))
        let params = (draft["params"]?.array ?? []).compactMap(\.string)
            .map { Text.slug($0, maxWords: 2).replacingOccurrences(of: "-", with: "_") }.filter { $0 != "skill" }
        var notes: [String] = [], steps: [PlannedStep] = []
        for v in draft["steps"]?.array ?? [] {
            guard let s = try? JSON.decode(PlannedStep.self, from: JSON.string(v)) else { continue }
            let step = Planner.tidy(s)
            if let problem = GraphTuning.problem(step, params: params, registry: registry, policy: ctx.policy, graph: graph) {
                notes.append("left out a step: \(problem)")
            } else {
                steps.append(step)
            }
        }
        let used = Set(steps.flatMap { $0.args.flatMap { Re.all(#"\{([A-Za-z0-9_]+)\}"#, $0).compactMap(\.last) } })
        let kept = params.filter(used.contains)
        let title = args.string("name") ?? draft["name"]?.string?.ifEmpty(request) ?? request
        let help = draft["help"]?.string?.ifEmpty(request) ?? request
        let listing = steps.enumerated().map { "\($0.offset + 1). \($0.element.tool) \(Shell.join($0.element.args))" }.joined(separator: "\n")

        let ev = Evidence()
        let cite = ev.observe("draft of \"\(title)\"", listing.ifEmpty("(no usable steps)"))
        guard !steps.isEmpty else {
            ev.find("skill", "No skill drafted", severity: .info, cites: [cite], confidence: 50,
                    explanation: "None of the drafted steps passed bibi's rules. Describe it again more concretely, or write the skill by hand under Settings → Skills.")
            return SkillResult(summary: "No skill drafted: none of the steps passed bibi's rules.", observations: ev.allObservations,
                               findings: ev.allFindings, notes: notes)
        }

        var facts: [String: JSONValue] = [:]
        var summary = "Drafted \"\(title)\": \(help)"
        if ctx.dryRun {
            notes.append("dry run: the draft wasn't saved")
        } else {
            let node = save(title: title, help: help, keywords: draft["keywords"]?.string ?? "", request: request, steps: steps, params: kept)
            facts["candidate"] = .string(node.id)
            summary += " Keep it under Settings → Skills to use it as bibi \(node.name)."
        }
        ev.find("skill", "Drafted skill: \(title)", severity: .info, cites: [cite], confidence: 60,
                explanation: help + "\n" + listing + (kept.isEmpty ? "" : "\nParameters: " + kept.joined(separator: ", ")))
        return SkillResult(summary: summary, observations: ev.allObservations, findings: ev.allFindings, facts: facts, notes: notes)
    }

    /// Saves the draft as a candidate learned skill, like one drafted from repeated requests.
    func save(title: String, help: String, keywords: String, request: String, steps: [PlannedStep], params: [String]) -> GraphNode {
        var slug = "learned." + Text.slug(title), n = 2
        while graph.node(GraphSync.skillID(slug)) != nil { slug = "learned." + Text.slug(title) + "-\(n)"; n += 1 }
        let node = GraphNode(id: GraphSync.skillID(slug), kind: "skill", name: slug, text: help + "\n" + request,
                             props: ["source": .string("learned"), "origin": .string("described"), "help": .string(help),
                                     "keywords": .string(Text.oneLine(keywords, max: 200)), "request": .string(request),
                                     "intent": .string(request), "params": .strings(params), "steps": GraphTuning.encode(steps),
                                     "signature": .string(steps.map(\.signature).joined(separator: ">")),
                                     "examples": .strings([]), "size": .number(0)],
                             status: "candidate")
        graph.upsert(node)
        graph.link(node.id, GraphSync.skillID("learned"), "child_of")
        graph.record("candidate", node: node.id, payload: .string("described"))
        return node
    }
}
