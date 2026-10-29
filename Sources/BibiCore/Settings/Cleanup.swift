import Foundation

/// Settings → Cleanup: put things back to their built-in values, or forget what bibi learned. Every operation can
/// run dry (Settings shows the count before you confirm), and the web layer backs up bibi.db before a real run.
public enum CleanupOp: String, CaseIterable, Codable, Sendable {
    case prompts, promptHistory, knobs, skillTuning, seedExamples, tools, policy
    case learnedSkills, candidates, learnedExamples, facts
    case statistics, chats, runs
    case housekeeping, factory

    public var group: String {
        switch self {
        case .prompts, .promptHistory, .knobs, .skillTuning, .seedExamples, .tools, .policy: return "Back to built-in"
        case .learnedSkills, .candidates, .learnedExamples, .facts: return "Forget what bibi learned"
        case .statistics, .chats, .runs: return "History"
        case .housekeeping, .factory: return "Database"
        }
    }

    public var title: String {
        switch self {
        case .prompts: return "Revert all prompt overrides"
        case .promptHistory: return "Delete old prompt versions"
        case .knobs: return "Reset all model and context settings"
        case .skillTuning: return "Revert skill keywords and descriptions"
        case .seedExamples: return "Revert starter examples"
        case .tools: return "Turn all actions and apps back on"
        case .policy: return "Clear your command allow and block lists"
        case .learnedSkills: return "Delete learned skills"
        case .candidates: return "Delete proposed and dismissed skills"
        case .learnedExamples: return "Delete learned and added examples"
        case .facts: return "Forget remembered facts"
        case .statistics: return "Clear statistics"
        case .chats: return "Delete chats"
        case .runs: return "Delete skill runs"
        case .housekeeping: return "Tidy the database"
        case .factory: return "Factory reset"
        }
    }

    public var detail: String {
        switch self {
        case .prompts: return "Every edited prompt and skill guidance goes back to its built-in text, which then follows bibi's code again. Old versions stay in the history."
        case .promptHistory: return "Keeps only each prompt's active version. Approval statistics of old versions go with them."
        case .knobs: return "Every number under Model & context goes back to its built-in value."
        case .skillTuning: return "Keywords and descriptions you changed go back to the built-in ones, and hidden built-in skills come back."
        case .seedExamples: return "Starter examples you edited or disabled go back to how bibi ships them."
        case .tools: return "Actions and apps you turned off are offered in chat again."
        case .policy: return "Programs you allowed or blocked follow bibi's built-in rules again."
        case .learnedSkills: return "Skills learned from your requests or written by you, accepted or hidden."
        case .candidates: return "Skills bibi proposed that you haven't accepted. Dismissed ones can then be proposed again."
        case .learnedExamples: return "Requests that worked and examples you added. Chat retrieves fewer examples until it learns again; starter examples stay."
        case .facts: return "What bibi remembered about this Mac and you from conversations."
        case .statistics: return "Approvals, skips and other events. Approval rates start over, and so does automatic prompt rollback."
        case .chats: return "Conversations older than the number of days you choose (0 = all), with their transcripts."
        case .runs: return "Saved skill runs older than the number of days you choose (0 = all), with their reports and undo journals."
        case .housekeeping: return "Removes rolled-back prompt versions, retired skills and cached embeddings of deleted items, then compacts the file. Nothing you use is lost."
        case .factory: return "Empties bibi.db: overrides, learned skills, examples, facts and statistics. Built-ins and starter examples come back. Chats and runs stay."
        }
    }

    /// Takes a number of days.
    public var takesDays: Bool { self == .chats || self == .runs }
    /// Safe enough to run without a confirmation dialog beyond the count.
    public var safe: Bool { self == .housekeeping }
}

public struct CleanupReport: Codable, Sendable {
    public var op: CleanupOp
    public var count: Int
    /// A few of the affected items, for the confirmation dialog.
    public var items: [String]
    public var dryRun: Bool
    /// The backup taken before a real run (set by the caller).
    public var backup: String?
}

extension Settings {
    public func cleanup(_ op: CleanupOp, dryRun: Bool, days: Int = 0) -> CleanupReport {
        var items: [String] = []
        var count = 0
        func note(_ s: String) { count += 1; if items.count < 12 { items.append(s) } }
        let dry = dryRun

        switch op {
        case .prompts:
            for d in harness.promptCatalog where prompts.state(d.id, builtIn: d.builtIn).overridden {
                note(d.id)
                if !dry { prompts.revert(d.id, builtIn: d.builtIn) }
            }
        case .promptHistory:
            for head in graph.nodes(kind: "prompt") {
                let n = prompts.prune(head.name, dryRun: dry)
                if n > 0 { note("\(head.name): \(n) old version\(n == 1 ? "" : "s")"); count += n - 1 }
            }
        case .knobs:
            for k in Knob.all where knobs.override(k) != nil { note(k.label) }
            if !dry { knobs.resetAll() }
        case .skillTuning:
            for n in graph.nodes(kind: "skill") where n.props["tuned"] != nil
                || n.props["source"]?.string == "builtin" && n.status == "disabled" && n.id != GraphSync.root {
                note(n.name)
                if !dry {
                    graph.update(n.id) { s in
                        s.props["tuned"] = nil
                        if s.props["source"]?.string == "builtin" && s.status == "disabled" { s.status = "active" }
                    }
                    graph.dropVector(n.id)
                }
            }
            if !dry { harness.reloadLearned() }
        case .seedExamples:
            for i in graph.nodes(kind: "intent") where i.props["seed"] != nil && (i.props["tuned"] != nil || i.status == "disabled") {
                note(GraphSync.text(i))
                if !dry { graph.update(i.id) { $0.props["tuned"] = nil; $0.status = "active" } }
            }
        case .tools:
            for a in graph.nodes(kind: "action", status: "disabled") {
                note(a.name)
                if !dry { graph.setStatus(a.id, "active") }
            }
            for b in knobs.list(Knobs.appsDisabled) { note(harness.apps.catalog.app(b)?.name ?? b) }
            if !dry { knobs.setList(Knobs.appsDisabled, []) }
        case .policy:
            for p in knobs.list(Knobs.policyAllow) { note("allow " + p) }
            for p in knobs.list(Knobs.policyBlock) { note("block " + p) }
            if !dry { knobs.setList(Knobs.policyAllow, []); knobs.setList(Knobs.policyBlock, []) }
        case .learnedSkills, .candidates:
            let wanted: Set<String> = op == .learnedSkills ? ["active", "disabled"] : ["candidate", "dismissed"]
            for n in graph.nodes(kind: "skill") where n.props["source"]?.string == "learned" && wanted.contains(n.status) {
                note(n.name)
                if !dry { graph.delete(n.id) }
            }
            if !dry { harness.reloadLearned() }
        case .learnedExamples:
            for i in graph.nodes(kind: "intent") where i.props["seed"] == nil && i.props["outcome"]?.string == "ok" {
                note(GraphSync.text(i))
                if !dry { graph.delete(i.id) }
            }
        case .facts:
            for f in graph.nodes(kind: "fact") {
                note("\(f.name): \(f.text)")
                if !dry { graph.delete(f.id) }
            }
        case .statistics:
            count = graph.eventCount()
            if !dry { graph.deleteEvents() }
        case .chats, .runs:
            let cutoff = Date().addingTimeInterval(-Double(max(0, days)) * 86400)
            let runs = harness.store.list().filter { ($0.meta.skill == "chat") == (op == .chats) && (days <= 0 || $0.meta.started < cutoff) }
            for r in runs {
                note((op == .chats ? r.meta.summary ?? "chat" : r.meta.skill) + " " + RunStore.stamp.string(from: r.meta.started))
                if !dry {
                    try? harness.store.delete(r)
                    if op == .chats { graph.delete("conversation:" + r.id) }
                }
            }
        case .housekeeping:
            for v in graph.nodes(kind: "prompt_version") where v.status == "rolled-back"
                || graph.edges(to: v.id, kind: "has_version").isEmpty {
                note(v.name)
                if !dry { graph.delete(v.id) }
            }
            for s in graph.nodes(kind: "skill", status: "retired") {
                note(s.name)
                if !dry { graph.delete(s.id) }
            }
            let orphans = graph.orphanVectors(delete: !dry)
            if orphans > 0 { note("\(orphans) cached embeddings"); count += orphans - 1 }
            if !dry { graph.vacuum() }
        case .factory:
            count = graph.kinds().values.reduce(0, +) + graph.settings().count
            items = graph.kinds().sorted { $0.key < $1.key }.map { "\($0.value) \($0.key) nodes" }
            if !dry {
                graph.wipe()
                GraphSync.syncBuiltins(graph, skills: Array(harness.skills.values), registry: harness.registry)
                harness.apps.catalog.sync(graph)
                harness.reloadLearned()
                graph.vacuum()
            }
        }
        if !dry { graph.record("cleanup", node: "settings", payload: .string(op.rawValue)) }
        return CleanupReport(op: op, count: count, items: items, dryRun: dry, backup: nil)
    }
}
