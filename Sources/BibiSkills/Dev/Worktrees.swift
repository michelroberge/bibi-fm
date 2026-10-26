import BibiCore
import Foundation

public struct Worktree: Sendable {
    public var path: String
    public var branch: String?
    public var prunable: String?
    public var locked: Bool
    public var main: Bool
}

public enum Worktrees {
    /// `git worktree list --porcelain`
    public static func parse(_ text: String) -> [Worktree] {
        var out: [Worktree] = []
        for block in text.components(separatedBy: "\n\n") where !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var w = Worktree(path: "", branch: nil, prunable: nil, locked: false, main: out.isEmpty)
            for line in block.split(separator: "\n") {
                let (k, v) = line.firstIndex(of: " ").map { (String(line[..<$0]), String(line[line.index(after: $0)...])) } ?? (String(line), "")
                switch k {
                case "worktree": w.path = v
                case "branch": w.branch = v.replacingOccurrences(of: "refs/heads/", with: "")
                case "prunable": w.prunable = v.isEmpty ? "missing" : v
                case "locked": w.locked = true
                default: break
                }
            }
            out.append(w)
        }
        return out
    }

    public static func defaultBranch(_ repo: String) async -> String? {
        let head = await Command.run(["git", "-C", repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], timeout: 10)
        if head.ok { return head.stdout.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "origin/", with: "") }
        for b in ["main", "master"] where await Command.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", b], timeout: 10).ok {
            return b
        }
        return nil
    }

    public static func merged(_ repo: String, into branch: String) async -> Set<String> {
        let o = await Command.run(["git", "-C", repo, "branch", "--merged", branch, "--format=%(refname:short)"], timeout: 20)
        return Set(o.lines)
    }
}

public struct GitWorktreePrune: ActionSpec {
    public let id = "git_worktree_prune"
    public let summary = "Forget git worktrees whose folders no longer exist"
    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let repo = try require(p, "repo")
        guard repo.hasPrefix("/"), Paths.exists(repo + "/.git") else { throw ActionError("\(Paths.short(repo)) is not a git repository") }
    }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] { ["git -C \(Paths.short(p["repo"]!)) worktree prune   (only removes stale bookkeeping)"] }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        try await Command.run(["git", "-C", p["repo"]!, "worktree", "prune", "-v"], timeout: 60).check()
        return Outcome("pruned stale worktrees of \(Paths.short(p["repo"]!))")
    }
}

/// Removes a clean worktree; the branch and its commits stay in the repository.
public struct GitWorktreeRemove: ActionSpec {
    public let id = "git_worktree_remove"
    public let summary = "Remove a clean git worktree (its branch is kept)"

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let repo = try require(p, "repo"), path = try require(p, "path")
        guard repo.hasPrefix("/"), path.hasPrefix("/"), path != repo, Paths.exists(repo + "/.git"), Paths.isDirectory(path) else {
            throw ActionError("not a worktree of \(Paths.short(repo))")
        }
    }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        ["git -C \(Paths.short(p["repo"]!)) worktree remove \(Paths.short(p["path"]!))   (refuses if there are uncommitted changes; the branch is kept)"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let repo = p["repo"]!, path = p["path"]!
        let list = Worktrees.parse(await Command.run(["git", "-C", repo, "worktree", "list", "--porcelain"]).stdout)
        guard list.contains(where: { $0.path == path && !$0.main }) else { throw ActionError("\(Paths.short(path)) is not a linked worktree of \(Paths.short(repo))") }
        let status = await Command.run(["git", "-C", path, "status", "--porcelain"], timeout: 30)
        guard status.ok, status.stdout.isEmpty else { throw ActionError("\(Paths.short(path)) has uncommitted changes") }
        try await Command.run(["git", "-C", repo, "worktree", "remove", path], timeout: 120).check()
        return Outcome("removed worktree \(Paths.short(path)) (branch kept)")
    }
}
