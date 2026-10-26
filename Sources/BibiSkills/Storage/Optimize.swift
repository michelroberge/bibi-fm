import BibiCore
import Foundation

/// storage.optimize: find the best ways to reclaim disk space.
public struct OptimizeStorage: Skill {
    public init() {}
    public let name = "storage.optimize"
    public let help = "Analyze disk usage and recommend (and run) the top cleanup actions"
    public var aliases: [String] { ["optimize-storage"] }
    public var params: [Param] {
        [
            .positional("path", help: "folder to analyze (default: your home folder)", default: "~"),
            .option("top", "-n", "--top", kind: .int, default: "5", help: "number of actions to recommend"),
            .option("depth", "--depth", kind: .int, default: "3", help: "how many levels fm may descend"),
            .option("min_size", "--min-size", kind: .size, default: "200M", help: "ignore items smaller than this"),
            .option("jobs", "--jobs", kind: .int, default: "2", help: "parallel fm calls"),
        ]
    }
    public var factsSpec: FactsSpec { FactsSpec(["sizes": FactsSpec.bytes, "free": FactsSpec.bytes]) }

    public func run(_ args: Args, _ ctx: SkillContext) async throws -> SkillResult {
        let root = Paths.resolve(args.string("path") ?? "~")
        guard Paths.isDirectory(root) else { throw SkillError("not a directory: \(args.string("path") ?? "")") }
        let top = args.int("top") ?? 5, depth = args.int("depth") ?? 3
        let (free, total) = diskUsage(root)
        ctx.reporter.info("Disk: \(human(free)) free of \(human(total))")

        var t = Date()
        ctx.reporter.progress("Scanning \(Paths.short(root)) (this can take a minute)...")
        let reporter = ctx.reporter
        let tree = try await scan(root, depth: depth + 1) { i, p in
            if i % 50 == 0 { reporter.progress("Scanning \(Paths.short(root)): \(i + 1) folders  \(String(Paths.short(p).suffix(50)))") }
        }
        ctx.reporter.info("Scanned \(Paths.short(root)): \(human(tree.size)) in \(Int(Date().timeIntervalSince(t)))s")

        t = Date()
        let cfg = Analyze.Config(root: root, depth: depth, minSize: args.size("min_size") ?? 200 << 20,
                                 keep: max(2 * top, 6), jobs: args.int("jobs") ?? 2)
        let actions = Array(await Analyze.analyze(tree, depthLeft: depth - 1, ctx: ctx, cfg: cfg).prefix(top))
        let reclaim = actions.filter { $0.kind != "review" }.map(\.bytes).reduce(0, +)

        // Each recommendation becomes a finding backed by what bibi measured about the item.
        let ev = Evidence()
        let diskObs = ev.observe("statfs \(Paths.short(root))", "\(human(free)) free of \(human(total))")
        for a in actions {
            var cites = [ev.observe("du -k \(Paths.short(a.target))", "\(Paths.short(a.target)) uses \(human(a.bytes))",
                                    value: .number(Double(a.bytes)))]
            if let m = Paths.mtime(a.target) {
                cites.append(ev.observe("stat \(Paths.short(a.target))", "last modified \(ago(m))"))
            }
            if let hint = ctx.policy.hint(a.target) {
                cites.append(ev.observe("bibi path rules", "\(Paths.short(a.target)) is known as: \(hint)"))
            }
            cites.append(diskObs)
            let severity: Severity = a.kind == "review" ? .info : a.bytes >= 10 << 30 ? .high : a.bytes >= 2 << 30 ? .medium : .low
            ev.find("storage", a.title, severity: severity, cites: cites, confidence: a.confidence * 10,
                    explanation: a.reason, subject: ["path": a.target], actions: [a])
        }

        var sizes: [String: Double] = [:]
        for c in tree.children.prefix(30) { sizes[Paths.short(c.path)] = Double(c.size) }
        return SkillResult(
            summary: "Analyzed with fm in \(Int(Date().timeIntervalSince(t)))s. Up to \(human(reclaim)) reclaimable from the top \(actions.count).",
            observations: ev.allObservations,
            findings: ev.allFindings,  // already ranked by score
            facts: ["sizes": .numbers(sizes), "free": .number(Double(free)), "root": .string(root)],
            notes: root == Paths.home
                ? ["folders macOS protects (Desktop/Documents/Downloads, Mail...) are only measured if your terminal has Full Disk Access"]
                : []
        )
    }

    public func afterRun(_ result: SkillResult, _ ctx: SkillContext) async -> String? {
        guard let before = result.facts["free"]?.number else { return nil }
        let free = Double(diskUsage(result.facts["root"]?.string ?? Paths.home).free)
        return "Free space: \(human(before)) -> \(human(free)) (\(human(free - before)) reclaimed)"
    }
}
