import BibiCore
import Foundation

/// Recursive analysis: assess each child independently with fm, descend where useful,
/// then merge and optimize candidate actions on the way back up.
public enum Analyze {
    public static let verdictSchema = Schema("Verdict", [
        .init("verdict", .choice(["act", "descend", "skip"]),
              "act = recommend an action on this item; descend = look inside; skip = leave alone"),
        .init("action_type", .choice(Catalog.actionTypes)),
        .init("safety", .int(0...10), "0 = risky data loss, 10 = no risk at all"),
        .init("confidence", .int(0...10), "0-10 how sure you are"),
        .init("reason", .string, "one short sentence"),
    ])

    public static let verdictInstructions = """
    You are a careful macOS disk-space advisor. You get ONE file or folder with its size and largest contents.
    Decide:
    - verdict "act": a specific cleanup is appropriate for this whole item.
    - verdict "descend": the item is large but mixed (e.g. ~/Library, ~/Documents, project folders); look inside instead. Only when "Can look inside" is yes.
    - verdict "skip": leave it alone (small gain, or personal data with no clear cleanup).
    action_type (use "none" unless verdict is "act"):
    - empty_cache_dir: caches, logs, build artifacts that apps regenerate.
    - trash: a file or folder the user very likely no longer needs (old installers, archives, stale downloads).
    - tool_cleanup: a tool owns this data and has its own cleanup (Homebrew, Docker, npm, pip, iOS simulators).
    - empty_trash: only for the Trash itself.
    - review: large personal data (photos, videos, backups, documents) the user should look at themselves.
    Never suggest deleting documents, photos, source code, or app data outright; use review.
    Safety is 10 only when nothing of value can be lost.
    """

    public static let consolidateSchema = Schema("Consolidate", [
        .init("combine", .bool, "true to replace the items with one action on the parent folder"),
        .init("safety", .int(0...10), "0-10 safety of clearing the whole parent folder"),
        .init("reason", .string, "one short sentence"),
    ])

    public static let consolidateInstructions = """
    You optimize a list of disk cleanup recommendations that all live inside one parent folder.
    Say combine=true only if clearing the entire parent folder is as safe as the individual items and simpler for the user.
    """

    struct Consolidate: Decodable {
        var combine: Bool
        var safety: Int
        var reason: String
    }

    public struct Config: Sendable {
        public var root: String
        public var depth: Int
        public var minSize: Int
        public var keep: Int  // candidates kept per level while bubbling up
        public var jobs: Int
        public init(root: String, depth: Int, minSize: Int, keep: Int, jobs: Int) {
            self.root = root; self.depth = depth; self.minSize = minSize; self.keep = keep; self.jobs = jobs
        }
    }

    static func describe(_ node: Node, canDescend: Bool, policy: SafetyPolicy) -> String {
        let age = node.ageDays >= 0 ? ", modified \(node.ageDays) days ago" : ""
        var lines = ["Item: \(Paths.short(node.path))", "Type: \(node.isDir ? "folder" : "file"), \(human(node.size))\(age)"]
        if let hint = policy.hint(node.path) { lines.append("Known as: \(hint)") }
        if node.isDir {
            lines.append("Can look inside: \(canDescend && !node.children.isEmpty ? "yes" : "no")")
            if !node.children.isEmpty {
                lines.append("Largest contents:")
                for c in node.children.prefix(10) { lines.append("- \(Paths.name(c.path))\(c.isDir ? "/" : "") \(human(c.size))") }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func assess(_ node: Node, canDescend: Bool, ctx: SkillContext) async -> Catalog.Verdict? {
        let start = Date()
        do {
            let v = try await ctx.model.respond(describe(node, canDescend: canDescend, policy: ctx.policy),
                                                instructions: verdictInstructions, schema: verdictSchema, as: Catalog.Verdict.self)
            ctx.reporter.debug(String(format: "  %@ %@  %@/%@ s=%d c=%d (%.1fs) %@",
                                      Paths.short(node.path).padding(toLength: 50, withPad: " ", startingAt: 0),
                                      human(node.size), v.verdict, v.action_type, v.safety, v.confidence,
                                      Date().timeIntervalSince(start), v.reason))
            return v
        } catch {
            ctx.reporter.debug("  ! \(Paths.short(node.path)): \(error)")
            return nil
        }
    }

    /// Assesses node's children independently, recurses into "descend" ones, returns the best candidates.
    public static func analyze(_ node: Node, depthLeft: Int, ctx: SkillContext, cfg: Config) async -> [BoundAction] {
        let kids = node.children.filter { $0.size >= cfg.minSize }
        guard !kids.isEmpty else { return [] }
        ctx.reporter.progress("Analyzing \(Paths.short(node.path)) (\(kids.count) items)...")
        var verdicts = [Catalog.Verdict?](repeating: nil, count: kids.count)
        await withTaskGroup(of: (Int, Catalog.Verdict?).self) { group in
            var next = 0
            func add() {
                let i = next, kid = kids[i]
                group.addTask { (i, await assess(kid, canDescend: depthLeft > 0, ctx: ctx)) }
                next += 1
            }
            while next < min(cfg.jobs, kids.count) { add() }
            for await (i, v) in group {
                verdicts[i] = v
                if next < kids.count { add() }
            }
        }

        var candidates: [BoundAction] = []
        for (kid, verdict) in zip(kids, verdicts) {
            guard var v = verdict else { continue }
            if v.verdict == "descend" {
                if depthLeft > 0 && kid.isDir && !kid.children.isEmpty {
                    candidates += await analyze(kid, depthLeft: depthLeft - 1, ctx: ctx, cfg: cfg)
                    continue
                }
                v.verdict = "act"
                v.action_type = "review"
            }
            if let a = Catalog.buildAction(kid, v, root: cfg.root, policy: ctx.policy) { candidates.append(a) }
        }
        return await bubbleUp(node, candidates, ctx: ctx, cfg: cfg)
    }

    static func covers(_ parent: BoundAction, _ child: BoundAction) -> Bool {
        parent.target != child.target && Paths.isWithin(child.target, parent.target)
    }

    /// Merges duplicates, drops overlaps, optionally consolidates with fm, keeps the top `keep`.
    static func bubbleUp(_ node: Node, _ candidates: [BoundAction], ctx: SkillContext, cfg: Config) async -> [BoundAction] {
        // 1. Same command (e.g. two Homebrew dirs -> one `brew cleanup`): merge sizes.
        var merged: [String: BoundAction] = [:], order: [String] = []
        for a in candidates {
            let key = a.kind == "tool_cleanup" ? a.command : a.target
            if var m = merged[key] {
                if a.kind == "tool_cleanup" { m.bytes += a.bytes }
                m.safety = min(m.safety, a.safety)
                merged[key] = m
            } else {
                merged[key] = a
                order.append(key)
            }
        }
        // 2. Overlaps: an action on a folder and on something inside it double-count; keep the better.
        let actions = order.map { merged[$0]! }.sorted { $0.score > $1.score }
        var kept: [BoundAction] = []
        for a in actions where !kept.contains(where: { covers($0, a) || covers(a, $0) }) { kept.append(a) }

        // 3. Several clear/trash actions inside a regenerable folder -> ask fm whether to clear the folder.
        let inside = kept.filter { ["empty_cache_dir", "trash"].contains($0.kind) && Paths.parent($0.target) == node.path }
        if inside.count >= 3 && ctx.policy.isRegenerable(node.path) && !ctx.policy.isProtected(node.path) {
            let items = inside.map { "- \(Paths.short($0.target)) \(human($0.bytes)) (\($0.kind), safety \($0.safety))" }
            let prompt = "Parent folder: \(Paths.short(node.path)) (\(human(node.size)))\nKnown as: \(ctx.policy.hint(node.path) ?? "unknown")\nItems:\n"
                + items.joined(separator: "\n")
            do {
                let r = try await ctx.model.respond(prompt, instructions: consolidateInstructions, schema: consolidateSchema,
                                                    as: Consolidate.self)
                if r.combine {
                    let safety = min(r.safety, inside.map(\.safety).min()!)
                    if let combined = Catalog.consolidatedAction(node, inside, safety: safety, reason: r.reason, policy: ctx.policy) {
                        ctx.reporter.debug("  ⇡ consolidated \(inside.count) items into \(combined.title)")
                        let ids = Set(inside.map(\.target))
                        kept = kept.filter { !ids.contains($0.target) } + [combined]
                    }
                }
            } catch {
                ctx.reporter.debug("  ! consolidate \(Paths.short(node.path)): \(error)")
            }
        }
        kept.sort { $0.score > $1.score }
        return Array(kept.prefix(cfg.keep))
    }
}
