import Foundation

/// One step the model proposed (or a learned skill stores): a tool and its arguments.
///  - `command`: args are the program and its arguments.
///  - `action:<id>`: args are `key=value` parameters of a registry action.
///  - `skill:<name>`: args are the skill's command-line options.
public struct PlannedStep: Codable, Sendable, Equatable {
    public var tool: String
    public var args: [String]
    public var purpose: String

    public init(tool: String, args: [String], purpose: String = "") {
        self.tool = tool; self.args = args; self.purpose = purpose
    }

    /// What kind of step this is, for recognizing repeated requests: the tool plus the program for commands.
    public var signature: String {
        tool == "command" ? "command:" + Paths.name(args.first == "sudo" ? (args.dropFirst().first ?? "") : (args.first ?? "")) : tool
    }

    /// The step an approved action corresponds to (what actually ran, for learning).
    public static func from(_ a: BoundAction) -> PlannedStep {
        switch a.call.spec {
        case "run_command", "run_command_admin":
            let argv = CommandPolicy.decode(a.call.params["argv"] ?? "[]") ?? []
            return PlannedStep(tool: "command", args: (a.call.spec == "run_command_admin" ? ["sudo"] : []) + argv, purpose: a.title)
        case "run_skill":
            return PlannedStep(tool: "skill:" + (a.call.params["skill"] ?? ""),
                               args: CommandPolicy.decode(a.call.params["argv"] ?? "[]") ?? [], purpose: a.title)
        case "run_app_call":
            let c = (try? JSON.decode(AppCall.self, from: a.call.params["call"] ?? "")) ?? AppCall(op: "command", term: "")
            let args = ["\(c.op)=\(c.term)"] + c.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            return PlannedStep(tool: "app:" + a.target, args: args, purpose: a.title)
        default:
            return PlannedStep(tool: "action:" + a.call.spec, args: a.call.params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" },
                               purpose: a.title)
        }
    }
}

/// Turns proposed steps into approvable actions. bibi's rules decide the class, safety and privilege; the model's
/// own words are only used as the title.
public struct Planner: Sendable {
    let registry: ActionRegistry
    let env: ActionEnv
    let skill: @Sendable (String) -> (any Skill)?

    public init(registry: ActionRegistry, env: ActionEnv, skill: @escaping @Sendable (String) -> (any Skill)?) {
        self.registry = registry; self.env = env; self.skill = skill
    }

    public struct Result: Sendable {
        public var actions: [BoundAction] = []
        public var refusals: [String] = []
    }

    public func bind(_ steps: [PlannedStep]) -> Result {
        var r = Result()
        for s in steps {
            switch bind(s) {
            case .success(let a): r.actions += a
            case .failure(let e): r.refusals.append(e.description)
            }
        }
        return r
    }

    /// The parameter a bare value means for actions that take one ("~/x.zip" for trash_path is path=~/x.zip).
    static let mainParam = ["trash_path": "path", "reveal": "path", "open_url": "url", "open_settings_pane": "pane", "tool_cleanup": "tool"]
        .merging(Recipes.mainParam) { a, _ in a }

    /// Small models put a whole command line in one string, leave empty strings, or copy placeholders like
    /// "--top TOP": split, drop empties, and drop placeholder values (with their flag) before checking.
    public static func tidy(_ s: PlannedStep) -> PlannedStep {
        var s = s
        var args = s.args.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let quoted = args.contains { $0.contains("\"") || $0.contains("'") }
        if !quoted, s.tool.hasPrefix("skill:") || (s.tool == "command" && args.count == 1) {
            args = args.flatMap { $0.split(separator: " ").map(String.init) }
        }
        if s.tool.hasPrefix("skill:") {
            var out: [String] = []
            for a in args {
                let placeholder = a.count > 1 && a == a.uppercased() && a.allSatisfy { $0.isLetter || $0 == "_" }
                if placeholder {
                    if out.last?.hasPrefix("-") == true { out.removeLast() }
                    continue
                }
                out.append(a)
            }
            args = out
        }
        s.args = args
        return s
    }

    public func bind(_ s: PlannedStep) -> Swift.Result<[BoundAction], ActionError> {
        let s = Self.tidy(s)
        let purpose = Text.oneLine(s.purpose, max: 120)
        if s.tool == "command" {
            let v = CommandPolicy.classify(s.args, policy: env.policy)
            if let why = v.refusal { return .failure(ActionError("\(Shell.join(s.args)): \(why)")) }
            if !v.rewrite.isEmpty {
                return collect(v.rewrite.map { call in
                    (call, BoundAction(call, title: "Move \(Paths.short(call.params["path"] ?? "")) to the Trash", kind: "trash",
                                       target: call.params["path"] ?? "", safety: 7, confidence: 7,
                                       reason: purpose.ifEmpty("instead of rm, so it can be undone"),
                                       command: "move to Trash (instead of \(Shell.join(s.args)))", reversible: true))
                })
            }
            let admin = v.cls == .admin
            let call = RunCommand.call(v.argv, admin: admin)
            let safety = [CommandClass.readOnly: 10, .network: 8, .writes: 5, .admin: 4][v.cls]!
            let text = (admin ? "sudo " : "") + Shell.join(v.argv)
            return collect([(call, BoundAction(call, title: purpose.ifEmpty(Text.oneLine(text, max: 80)), kind: v.cls.rawValue,
                                               target: text, safety: safety, confidence: 7, reason: purpose, command: text,
                                               privilege: admin ? .admin : .user))])
        }
        if s.tool.hasPrefix("skill:") {
            let name = String(s.tool.dropFirst(6))
            guard let sk = skill(name) else { return .failure(ActionError("there is no skill \(name)")) }
            var argv = s.args
            if (try? Args.parse(argv, params: sk.params)) == nil {
                // Bad options from the model: the defaults are a safe, useful run.
                do { _ = try Args.parse([], params: sk.params); argv = [] } catch {
                    return .failure(ActionError("\(name) \(Shell.join(s.args)): \(error)"))
                }
            }
            let call = ActionCall("run_skill", ["skill": sk.name, "argv": CommandPolicy.encode(argv)])
            return collect([(call, BoundAction(call, title: purpose.ifEmpty("Run \(sk.name)"), kind: "skill", target: sk.name,
                                               safety: 10, confidence: 8, reason: sk.help,
                                               command: "bibi " + ([sk.name] + argv).map(Shell.quoteIfNeeded).joined(separator: " ")))])
        }
        if s.tool.hasPrefix("app:") {
            let name = String(s.tool.dropFirst(4))
            guard let app = env.apps.catalog.app(name) else { return .failure(ActionError("there is no scriptable app \(name) on this Mac")) }
            do {
                let c = AppScripts.normalize(try AppScripts.parse(s.args), app, home: env.policy.home)
                let script = try AppScripts.build(c, app)
                let call = RunAppCall.call(app, c)
                return collect([(call, BoundAction(call, title: purpose.ifEmpty(script.title), kind: script.risk.rawValue, target: app.name,
                                                   safety: script.risk.safety, confidence: 6, reason: purpose.ifEmpty(script.title),
                                                   command: script.steps.joined(separator: "; "), reversible: script.undoClass != nil))])
            } catch {
                return .failure(ActionError("\(name): \(error)"))
            }
        }
        if s.tool.hasPrefix("action:") {
            let id = String(s.tool.dropFirst(7))
            guard let spec = registry.spec(id), spec.selectable, !["run_command", "run_command_admin", "run_skill", "run_app_call"].contains(id) else {
                return .failure(ActionError("there is no action \(id)"))
            }
            var params: Params = [:]
            // One bare value means the main parameter; several (e.g. a copied list of choices) mean nothing.
            let bare = s.args.filter { !$0.contains("=") }
            for var a in s.args {
                if !a.contains("="), bare.count == 1, let key = Self.mainParam[id] { a = key + "=" + a }
                guard let eq = a.firstIndex(of: "=") else { return .failure(ActionError("\(id): expected key=value, got \(a)")) }
                let key = String(a[..<eq]), value = String(a[a.index(after: eq)...])
                params[key] = key == "path" ? Paths.standardize(CommandPolicy.expand(value, home: env.policy.home)) : value
            }
            let call = ActionCall(id, spec.normalize(params, env))
            let steps = registry.preview(call, env)
            if let e = steps.error { return .failure(ActionError(e)) }
            let safety = spec.kind == "read-only" ? 10 : spec.kind == "outbound" ? 3 : spec.reversible ? 8 : 6
            return collect([(call, BoundAction(call, title: purpose.ifEmpty(spec.summary), kind: spec.kind ?? id,
                                               target: call.params.values.sorted().joined(separator: " "),
                                               safety: safety, confidence: 7, reason: spec.summary,
                                               command: steps.steps.joined(separator: "; "), privilege: spec.privilege,
                                               reversible: spec.reversible))])
        }
        return .failure(ActionError("unknown tool \(s.tool)"))
    }

    /// Checks each call with the registry before offering it.
    func collect(_ items: [(ActionCall, BoundAction)]) -> Swift.Result<[BoundAction], ActionError> {
        for (call, _) in items where call.spec != "run_skill" {
            if let e = registry.preview(call, env).error { return .failure(ActionError(e)) }
        }
        return .success(items.map(\.1))
    }
}
