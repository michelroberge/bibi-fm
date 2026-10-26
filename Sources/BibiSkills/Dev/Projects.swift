import BibiCore
import Foundation

/// A git project found under the scanned roots.
public struct Project: Sendable {
    public var path: String
    public var lastCommit: Date?
    public var lastTouched: Date?  // .git/index changes on checkout, staging, commits
    public var dirtyFiles: Int
    public var branch: String?

    public var lastActivity: Date? { [lastCommit, lastTouched].compactMap { $0 }.max() }
    public func isActive(days: Int, now: Date = Date()) -> Bool {
        dirtyFiles > 0 || (lastActivity.map { now.timeIntervalSince($0) < Double(days) * 86400 } ?? false)
    }
}

/// A regenerable folder inside a project and how to get it back.
public struct ArtifactRule: Sendable {
    public var names: [String]
    /// Files next to the folder that prove it can be rebuilt (any one). Empty = always regenerable.
    public var manifests: [String]
    /// Lockfiles that make the rebuild reproducible (exact versions). Empty = not applicable.
    public var locks: [String]
    public var hint: String

    public static let all: [ArtifactRule] = [
        .init(names: ["node_modules"], manifests: ["package.json"],
              locks: ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock", "npm-shrinkwrap.json"],
              hint: "JavaScript dependencies; npm/pnpm/yarn install restores them"),
        .init(names: [".venv", "venv"], manifests: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "setup.cfg"],
              locks: ["uv.lock", "poetry.lock", "Pipfile.lock", "requirements.txt", "pdm.lock"],
              hint: "Python virtual environment; recreate it from the project's requirements"),
        .init(names: ["target"], manifests: ["Cargo.toml", "pom.xml"], locks: [], hint: "Rust/Maven build output, rebuilt by cargo build / mvn"),
        .init(names: [".build"], manifests: ["Package.swift"], locks: [], hint: "SwiftPM build output, rebuilt by swift build"),
        .init(names: ["build"], manifests: ["package.json", "build.gradle", "build.gradle.kts", "CMakeLists.txt", "setup.py", "pyproject.toml"],
              locks: [], hint: "build output, recreated by the project's build"),
        .init(names: ["dist"], manifests: ["package.json", "setup.py", "pyproject.toml"], locks: [], hint: "packaged build output"),
        .init(names: [".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular"], manifests: ["package.json"], locks: [],
              hint: "web framework build cache"),
        .init(names: [".gradle"], manifests: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], locks: [],
              hint: "Gradle project cache"),
        .init(names: [".tox", ".nox"], manifests: ["tox.ini", "noxfile.py", "pyproject.toml", "setup.cfg"], locks: [], hint: "Python test environments"),
        .init(names: ["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"], manifests: [], locks: [], hint: "Python caches"),
        .init(names: ["DerivedData"], manifests: [], locks: [], hint: "Xcode build output"),
    ]

    public static func rule(for name: String) -> ArtifactRule? { all.first { $0.names.contains(name) } }

    /// (reproducible, has lockfile, the manifest found) for an artifact folder, or nil if no rule applies.
    public static func check(_ path: String) -> (rule: ArtifactRule, manifest: String?, lock: String?)? {
        guard let rule = rule(for: Paths.name(path)) else { return nil }
        let dir = Paths.parent(path)
        let present = Set((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        func has(_ f: String) -> Bool { f == "requirements.txt" ? present.contains { $0.hasPrefix("requirements") && $0.hasSuffix(".txt") } : present.contains(f) }
        let manifest = rule.manifests.first(where: has)
        if !rule.manifests.isEmpty && manifest == nil { return nil }
        return (rule, manifest, rule.locks.first(where: has))
    }
}

public struct Artifact: Sendable {
    public var path: String
    public var project: String
    public var bytes: Int
    public var rule: ArtifactRule
    public var manifest: String?
    public var lock: String?
}

public enum Projects {
    static let skipDirs: Set<String> = ["node_modules", ".git", "Library", ".Trash", "Pictures", "Movies", "Music", ".venv", "venv",
                                        "vendor", "Pods", ".build", "target", "DerivedData"]

    /// Git repositories under the roots, not descending into repositories once found.
    public static func discover(_ roots: [String], maxDepth: Int) -> [String] {
        var found: [String] = []
        var queue = roots.map { ($0, 0) }
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            if Paths.exists(dir + "/.git") { found.append(dir); continue }
            guard depth < maxDepth else { continue }
            for child in Paths.children(dir) where Paths.isDirectory(child) && !Paths.isSymlink(child) {
                let name = Paths.name(child)
                if skipDirs.contains(name) || (name.hasPrefix(".") && name != ".config") { continue }
                queue.append((child, depth + 1))
            }
        }
        return found
    }

    public static func info(_ repo: String) async -> Project {
        async let status = Command.run(["git", "-C", repo, "status", "--porcelain", "--untracked-files=normal"], timeout: 20)
        async let log = Command.run(["git", "-C", repo, "log", "-1", "--format=%ct"], timeout: 10)
        async let branch = Command.run(["git", "-C", repo, "rev-parse", "--abbrev-ref", "HEAD"], timeout: 10)
        let s = await status, l = await log, b = await branch
        return Project(path: repo,
                       lastCommit: Double(l.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).map { Date(timeIntervalSince1970: $0) },
                       lastTouched: Paths.mtime(repo + "/.git/index"),
                       dirtyFiles: s.ok ? s.lines.count : 0,
                       branch: b.ok ? b.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
    }

    /// Artifact folders inside a project (not inside other artifacts or .git).
    public static func artifacts(in project: String, maxDepth: Int = 4) -> [(path: String, rule: ArtifactRule, manifest: String?, lock: String?)] {
        var out: [(String, ArtifactRule, String?, String?)] = []
        var queue = [(project, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            for child in Paths.children(dir) where Paths.isDirectory(child) && !Paths.isSymlink(child) {
                let name = Paths.name(child)
                if name == ".git" { continue }
                if let c = ArtifactRule.check(child) {
                    out.append((child, c.rule, c.manifest, c.lock))
                    continue
                }
                if ArtifactRule.rule(for: name) != nil { continue }  // e.g. a "build" folder without a manifest: leave it alone
                if depth + 1 < maxDepth && !Projects.skipDirs.contains(name) { queue.append((child, depth + 1)) }
            }
        }
        return out
    }

    /// Sizes with `du -sk`, a few at a time.
    public static func sizes(_ paths: [String], jobs: Int = 6) async -> [String: Int] {
        await withTaskGroup(of: (String, Int).self) { group in
            var it = paths.makeIterator(), running = 0, out: [String: Int] = [:]
            func add(_ p: String) {
                group.addTask {
                    let o = await Command.run(["du", "-sk", p], timeout: 300)
                    return (p, (Int(o.stdout.split(separator: "\t").first ?? "") ?? 0) * 1024)
                }
            }
            while running < jobs, let p = it.next() { add(p); running += 1 }
            for await (p, size) in group {
                out[p] = size
                if let next = it.next() { add(next) }
            }
            return out
        }
    }
}

/// Deletes a build artifact folder after re-checking that the project can rebuild it.
public struct DeleteBuildArtifact: ActionSpec {
    public let id = "delete_build_artifact"
    public let summary = "Delete a project's build output or dependency folder (rebuilt from the project's manifest)"

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let path = try require(p, "path")
        guard path.hasPrefix("/"), Paths.isDirectory(path), !Paths.isSymlink(path) else { throw ActionError("\(Paths.short(path)) is not a folder") }
        guard ArtifactRule.check(path) != nil else {
            throw ActionError("\(Paths.short(path)) is not a recognized build artifact next to its project manifest")
        }
        guard !env.policy.isProtected(path) else { throw ActionError("\(Paths.short(path)) is protected") }
        var dir = Paths.parent(path), inRepo = false
        while dir != "/" && !inRepo {
            inRepo = Paths.exists(dir + "/.git")
            dir = Paths.parent(dir)
        }
        guard inRepo else { throw ActionError("\(Paths.short(path)) is not inside a git project") }
    }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        let c = ArtifactRule.check(p["path"]!)!
        return ["permanently delete \(Paths.short(p["path"]!))",
                "rebuild later from \(c.manifest ?? "the project")" + (c.lock.map { " (exact versions pinned by \($0))" } ?? "")]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        try FileManager.default.removeItem(atPath: p["path"]!)
        return Outcome("deleted \(Paths.short(p["path"]!))")
    }
}
