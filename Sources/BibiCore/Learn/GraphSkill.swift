import Foundation

/// A skill bibi learned from repeated chat requests and the user accepted. Its logic is data in the graph:
/// steps whose arguments may contain `{param}` slots. Read-only commands run and become evidence; anything that
/// changes the Mac comes back as a recommendation, so it still needs approval.
public struct GraphSkill: Skill {
    public let name: String
    public let help: String
    public let params: [Param]
    public let steps: [PlannedStep]
    public let nodeID: String
    let registry: ActionRegistry

    public init(node: GraphNode, registry: ActionRegistry = ActionRegistry(Builtins.all)) {
        self.registry = registry
        nodeID = node.id
        name = node.name
        help = node.props["help"]?.string ?? String(node.text.split(separator: "\n").first ?? "")
        steps = SkillMiner.steps(node)
        params = (node.props["params"]?.strings ?? []).map { key in
            Param(key: key, flags: ["--" + key], kind: .string, help: "value for {\(key)}", defaultValue: nil,
                  metavar: key.uppercased(), required: true)
        }
    }

    public static func active(in graph: GraphStore, registry: ActionRegistry) -> [GraphSkill] {
        graph.nodes(kind: "skill", status: "active").filter { $0.props["source"]?.string == "learned" }
            .map { GraphSkill(node: $0, registry: registry) }.filter { !$0.steps.isEmpty }
    }

    /// The steps with `{param}` slots filled in.
    public func filled(_ args: Args) -> [PlannedStep] {
        steps.map { s in
            var s = s
            s.args = s.args.map { a in
                params.reduce(a) { acc, p in acc.replacingOccurrences(of: "{\(p.key)}", with: args.string(p.key) ?? "") }
            }
            return s
        }
    }

    static let summarySchema = Schema("Summary", [.init("summary", .string, "two or three sentences")])

    static let summaryInstructions = """
    You summarize the output of commands that ran on the user's Mac, for the user, in two or three plain sentences.
    Only use facts from the output. Mention the numbers that answer the request.
    """

    public func run(_ args: Args, _ ctx: SkillContext) async throws -> SkillResult {
        let ev = Evidence()
        var actions: [BoundAction] = [], notes: [String] = [], cites: [String] = []
        let planner = Planner(registry: registry, env: ActionEnv(policy: ctx.policy, admin: NoAdminRunner()),
                              skill: { _ in nil })
        for s in filled(args) {
            if s.tool == "command" {
                let v = CommandPolicy.classify(s.args, policy: ctx.policy)
                if v.refusal == nil, v.rewrite.isEmpty, v.cls == .readOnly {
                    if ctx.dryRun {
                        notes.append("dry run: would run " + Shell.join(v.argv))
                        continue
                    }
                    ctx.reporter.progress("Running " + Shell.join(v.argv))
                    let out = await Command.run(v.argv, timeout: 120)
                    let text = (out.stdout + (out.stderr.isEmpty ? "" : "\n" + out.stderr)).trimmingCharacters(in: .whitespacesAndNewlines)
                    cites.append(ev.observe(out, Text.clip(text.ifEmpty(out.ok ? "(no output)" : "exit \(out.status)"), max: 4000)))
                    continue
                }
            }
            switch planner.bind(s) {
            case .success(let a): actions += a
            case .failure(let e): notes.append("skipped a step: \(e)")
            }
        }
        var summary = help
        if !cites.isEmpty {
            let obs = ev.allObservations
            let prompt = "Request: \(help)\n" + obs.map { "$ \($0.source)\n\(Text.clip($0.text, max: 1200))" }.joined(separator: "\n")
            if let r = try? await ctx.model.respond(prompt, instructions: ctx.prompts.text("learned.summary", default: Self.summaryInstructions),
                                                    schema: Self.summarySchema),
               let s = r["summary"]?.string, !s.isEmpty {
                summary = s
            } else {
                summary = obs.map { "\($0.source): " + Text.oneLine($0.text, max: 160) }.joined(separator: "\n")
            }
        }
        ev.find("learned", help, severity: .info, cites: cites, confidence: 70, explanation: summary, actions: actions)
        return SkillResult(summary: summary, observations: ev.allObservations, findings: ev.allFindings, notes: notes)
    }
}

/// For planning only: refuses to run anything as admin.
struct NoAdminRunner: AdminRunner {
    func run(_ argv: [String]) async throws -> String { throw ActionError("administrator actions are not available here") }
}
