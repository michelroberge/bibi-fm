import Foundation

public struct RunOptions: Sendable {
    /// nil = the skill's default.
    public var online: Bool?
    public var dryRun: Bool
    public var verbose: Bool
    public var since: String?
    public init(online: Bool? = nil, dryRun: Bool = false, verbose: Bool = false, since: String? = nil) {
        self.online = online; self.dryRun = dryRun; self.verbose = verbose; self.since = since
    }
}

/// The result of executing (or dry-running) one action.
public struct ExecResult: Codable, Sendable {
    public var actionID: String
    public var title: String
    public var ok: Bool
    public var message: String
    public var reversible: Bool
    public var output: String?
}

/// Runs skills, saves history, previews, executes and undoes actions. Shared by the terminal and the web UI
/// so both enforce the same rules and write the same audit trail.
public final class Harness: Sendable {
    public let skills: [String: any Skill]
    public let registry: ActionRegistry
    public let store: RunStore
    public let policy: SafetyPolicy
    let makeModel: @Sendable () -> any LanguageModel

    public init(skills: [any Skill], store: RunStore = RunStore(), policy: SafetyPolicy = SafetyPolicy(),
                model: @escaping @Sendable () -> any LanguageModel) {
        var d: [String: any Skill] = [:]
        for s in skills { d[s.name] = s }
        self.skills = d
        self.registry = ActionRegistry(Builtins.all + skills.flatMap(\.actionSpecs))
        self.store = store
        self.policy = policy
        self.makeModel = model
    }

    public func skill(named name: String) -> (any Skill)? {
        skills[name] ?? skills.values.first { $0.aliases.contains(name) }
    }

    public var sortedSkills: [any Skill] { skills.values.sorted { $0.name < $1.name } }

    /// Runs a skill and saves the run. Errors are saved in the run's meta too.
    public func run(_ skill: any Skill, argv: [String], reporter: any Reporter, options: RunOptions = RunOptions(),
                    onCreate: (@Sendable (RunRecord) -> Void)? = nil) async throws -> (RunRecord, SkillResult) {
        let args = try Args.parse(argv, params: skill.params)
        let online = options.online ?? skill.onlineByDefault
        let record = try store.create(skill: skill.name, args: argv, online: online, version: Bibi.version)
        onCreate?(record)
        var baseline: BaselineInfo?
        if let b = store.baseline(skill: skill.name, since: options.since, excluding: record.id), let report = b.report() {
            baseline = BaselineInfo(runID: b.id, date: b.meta.started, facts: report.facts)
        }
        let ctx = SkillContext(model: RecordingModel(makeModel(), record: { record.model($0) }), reporter: reporter,
                               fetcher: Fetcher(online: online, record: { record.network($0) }), policy: policy,
                               baseline: baseline, verbose: options.verbose, dryRun: options.dryRun)
        do {
            var result = try await skill.run(args, ctx)
            if result.diff == nil, let b = baseline, skill.comparable(b.facts, result.facts),
               let d = ctx.diff(result.facts, spec: skill.factsSpec) {
                result.diff = d
            }
            record.save(result)
            return (record, result)
        } catch {
            record.updateMeta { $0.finished = Date(); $0.error = "\(error)" }
            throw error
        }
    }

    public func env(admin: any AdminRunner, reporter: any Reporter) -> ActionEnv {
        ActionEnv(policy: policy, admin: admin, reporter: reporter)
    }

    public func preview(_ actions: [BoundAction], env: ActionEnv, run: RunRecord? = nil) -> [Preview] {
        actions.map { a in
            let p = registry.preview(a.call, env)
            run?.journal(JournalEntry(.previewed, actionID: a.id, title: a.title, call: a.call, error: p.error))
            return p
        }
    }

    /// Executes the chosen actions in order, journaling each one. Admin actions run only if adminConfirmed
    /// (each still asks for the password through env.admin). Diagnostic output is added to the report as evidence.
    public func execute(_ actions: [BoundAction], run: RunRecord, env: ActionEnv, adminConfirmed: Bool,
                        dryRun: Bool, frontend: String) async -> [ExecResult] {
        var results: [ExecResult] = []
        var report = run.report()
        for a in actions {
            run.journal(JournalEntry(.selected, actionID: a.id, title: a.title, call: a.call, frontend: frontend))
            if dryRun {
                let p = registry.preview(a.call, env)
                let msg = p.error.map { "would fail: \($0)" } ?? p.steps.joined(separator: "; ")
                run.journal(JournalEntry(.dryRun, actionID: a.id, title: a.title, call: a.call, message: msg, frontend: frontend))
                results.append(ExecResult(actionID: a.id, title: a.title, ok: p.error == nil, message: "[dry-run] " + msg,
                                          reversible: p.reversible, output: nil))
                continue
            }
            env.reporter.info("Running: \(a.title)")
            do {
                let o = try await registry.execute(a.call, env, adminConfirmed: adminConfirmed)
                run.journal(JournalEntry(.executed, actionID: a.id, title: a.title, call: a.call, message: o.message,
                                         undo: o.undo, frontend: frontend))
                if let output = o.output, report != nil {
                    let id = "o\(report!.observations.count + 1)"
                    report!.observations.append(Observation(id: id, source: a.command, text: String(output.prefix(4000))))
                    if let i = report!.findings.firstIndex(where: { $0.id == a.findingID }) {
                        report!.findings[i].observationIDs.append(id)
                    }
                }
                env.reporter.ok("  \(o.message)")
                results.append(ExecResult(actionID: a.id, title: a.title, ok: true, message: o.message,
                                          reversible: o.undo != nil, output: o.output))
            } catch {
                run.journal(JournalEntry(.failed, actionID: a.id, title: a.title, call: a.call, error: "\(error)", frontend: frontend))
                env.reporter.error("  failed: \(error)")
                results.append(ExecResult(actionID: a.id, title: a.title, ok: false, message: "\(error)", reversible: false, output: nil))
            }
        }
        if let report, results.contains(where: { $0.output != nil }) { run.save(report) }
        return results
    }

    /// Reverses executed actions of a run, newest first. `only` limits it to some action ids.
    public func undo(_ run: RunRecord, only: Set<String>? = nil, env: ActionEnv, adminConfirmed: Bool,
                     frontend: String) async -> [ExecResult] {
        var results: [ExecResult] = []
        for e in run.undoable where only == nil || only!.contains(e.actionID ?? "") {
            guard let call = e.undo else { continue }
            let title = "Undo: \(e.title ?? call.spec)"
            env.reporter.info(title)
            do {
                let o = try await registry.execute(call, env, adminConfirmed: adminConfirmed, allowInternal: true)
                run.journal(JournalEntry(.undone, actionID: e.actionID, title: e.title, call: call, message: o.message, frontend: frontend))
                env.reporter.ok("  \(o.message)")
                results.append(ExecResult(actionID: e.actionID ?? "", title: title, ok: true, message: o.message, reversible: false))
            } catch {
                run.journal(JournalEntry(.undoFailed, actionID: e.actionID, title: e.title, call: call, error: "\(error)", frontend: frontend))
                env.reporter.error("  failed: \(error)")
                results.append(ExecResult(actionID: e.actionID ?? "", title: title, ok: false, message: "\(error)", reversible: false))
            }
        }
        return results
    }

    /// Whether undoing needs admin rights (so front ends can ask first).
    public func undoNeedsAdmin(_ run: RunRecord) -> Bool {
        run.undoable.contains { e in e.undo.flatMap { registry.spec($0.spec) }?.privilege == .admin }
    }
}
