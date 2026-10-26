import BibiCore
import Foundation

/// dev.cleanup: find developer waste (build folders, Docker leftovers, package caches, unused SDKs, stale worktrees)
/// without touching active projects or anything that can't be rebuilt.
public struct DevCleanup: Skill {
    public init() {}
    public let name = "dev.cleanup"
    public let help = "Find build artifacts, Docker leftovers, package caches, unused SDKs and stale git worktrees"
    public let keywords = "developer projects node_modules build artifacts docker images sdk sdks worktree worktrees xcode deriveddata dev"
    public var params: [Param] {
        [
            .option("root", "--root", kind: .list, help: "folder with your projects (repeatable; default: ~/dev ~/src ~/code ~/projects ~/work ~/Developer)"),
            .option("active_days", "--active-days", kind: .int, default: "30", help: "projects touched this recently are left alone"),
            .option("min_size", "--min-size", kind: .size, default: "100M", help: "ignore items smaller than this"),
            .option("depth", "--depth", kind: .int, default: "4", help: "how deep to look for git projects under each root"),
            .flag("no_docker", "--no-docker", help: "skip Docker"),
        ]
    }
    public var factsSpec: FactsSpec { FactsSpec(["artifacts": FactsSpec.bytes, "caches": FactsSpec.bytes]) }
    public var actionSpecs: [any ActionSpec] {
        [DeleteBuildArtifact(), DockerImageRemove(), DockerVolumeRemove(), DockerBuilderPrune(), GitWorktreePrune(), GitWorktreeRemove()]
    }

    static let defaultRoots = ["dev", "src", "code", "projects", "work", "Developer", "repos", "git"]

    /// (path under home, label, owning tool)
    static let caches: [(String, String, String?)] = [
        ("Library/Caches/Homebrew", "Homebrew downloads", "brew"),
        (".npm/_cacache", "npm cache", "npm"),
        ("Library/Caches/pip", "pip cache", "pip"),
        ("Library/pnpm/store", "pnpm store", "pnpm"),
        ("Library/Caches/pnpm", "pnpm cache", "pnpm"),
        ("Library/Caches/Yarn", "Yarn cache", "yarn"),
        (".cache/uv", "uv cache", "uv"),
        ("go/pkg/mod", "Go module cache", "go"),
        ("Library/Caches/go-build", "Go build cache", nil),
        (".gradle/caches", "Gradle caches", nil),
        (".m2/repository", "Maven repository", nil),
        (".cargo/registry", "Cargo registry", "cargo"),
        ("Library/Developer/Xcode/DerivedData", "Xcode DerivedData", nil),
        ("Library/Developer/CoreSimulator/Caches", "Simulator caches", nil),
        ("Library/Caches/ms-playwright", "Playwright browsers", nil),
        (".cache/huggingface", "Hugging Face model cache", nil),
    ]

    public func run(_ args: Args, _ ctx: SkillContext) async throws -> SkillResult {
        let ui = ctx.reporter, ev = Evidence()
        let home = ctx.policy.home
        let activeDays = args.int("active_days") ?? 30, minSize = args.size("min_size") ?? 100 << 20
        var roots = args.list("root").map(Paths.expand)
        if roots.isEmpty { roots = Self.defaultRoots.map { home + "/" + $0 }.filter(Paths.isDirectory) }
        var notes: [String] = []
        if roots.isEmpty { notes.append("no project folder found; pass --root ~/where/your/projects/are") }

        // Projects and their build folders.
        ui.progress("Looking for git projects in \(roots.map(Paths.short).joined(separator: ", "))...")
        let repos = Projects.discover(roots, maxDepth: args.int("depth") ?? 4)
        var projects: [Project] = []
        for (i, repo) in repos.enumerated() {
            ui.progress("Checking projects \(i + 1)/\(repos.count): \(Paths.short(repo))")
            projects.append(await Projects.info(repo))
        }
        var found: [(Project, String, ArtifactRule, String?, String?)] = []
        for p in projects {
            for a in Projects.artifacts(in: p.path) { found.append((p, a.path, a.rule, a.manifest, a.lock)) }
        }
        ui.progress("Measuring \(found.count) build folders...")
        let sizes = await Projects.sizes(found.map(\.1))
        let artifacts = found.map { Artifact(path: $0.1, project: $0.0.path, bytes: sizes[$0.1] ?? 0, rule: $0.2, manifest: $0.3, lock: $0.4) }

        var pins = Pins()
        PinScanner.scan(repos, into: &pins)
        PinScanner.globalDefaults(home: home, into: &pins)
        let javaHome = await Command.run(["/usr/libexec/java_home"], timeout: 10)
        if javaHome.ok, let v = Re.first("([0-9]+(\\.[0-9.]+)?)", Paths.name(Paths.parent(Paths.parent(javaHome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))))?[1] {
            pins.add("java", v, from: "/usr/libexec/java_home (default JDK)")
        }

        async let dockerUsage = args.flag("no_docker") ? nil : Docker.collect()
        let cacheSizes = await Projects.sizes(Self.caches.map { home + "/" + $0.0 }.filter(Paths.isDirectory))
        let installs = SDKs.find(home: home)
        let sdkSizes = await Projects.sizes(SDKs.unused(installs, pins: pins).map(\.path))

        artifactFindings(projects, artifacts, activeDays: activeDays, minSize: minSize, ev: ev)
        cacheFindings(cacheSizes, minSize: minSize, ev: ev, policy: ctx.policy)
        sdkFindings(installs, pins: pins, sizes: sdkSizes, minSize: minSize, ev: ev)
        ui.progress("Checking git worktrees...")
        await worktreeFindings(repos, ev: ev)
        if let docker = await dockerUsage {
            dockerFindings(docker, minSize: minSize, ev: ev)
        } else if !args.flag("no_docker") && Command.which("docker") != nil {
            notes.append("Docker is installed but not running; start it to include images and volumes")
        }

        let ranked = ev.allFindings.sorted {
            ($0.severity, $0.recommendations.map(\.bytes).reduce(0, +)) > ($1.severity, $1.recommendations.map(\.bytes).reduce(0, +))
        }
        let findings = await ctx.explainer.explainAll(ranked, observations: ev.allObservations,
                                                      context: "Context: developer environment cleanup on a Mac. Free disk space without breaking active projects or losing data that can't be rebuilt.",
                                                      limit: 8)
        let reclaim = findings.flatMap { $0.recommendations.prefix(1) }.filter { $0.kind != "review" }.map(\.bytes).reduce(0, +)
        let active = projects.filter { $0.isActive(days: activeDays) }.count

        var artifactFacts: [String: Double] = [:]
        for a in artifacts where a.bytes >= 50 << 20 { artifactFacts[Paths.short(a.path)] = Double(a.bytes) }
        var cacheFacts: [String: Double] = [:]
        for (path, size) in cacheSizes { cacheFacts[Paths.short(path)] = Double(size) }
        return SkillResult(
            summary: "Scanned \(projects.count) projects (\(active) active, left alone). Up to \(human(reclaim)) can be freed.",
            observations: ev.allObservations, findings: findings,
            facts: ["artifacts": .numbers(artifactFacts), "caches": .numbers(cacheFacts),
                    "sdks": .strings(installs.map { "\($0.manager):\($0.tool)@\($0.version)" }),
                    "projects": .strings(projects.map { Paths.short($0.path) })],
            notes: notes)
    }

    func artifactFindings(_ projects: [Project], _ artifacts: [Artifact], activeDays: Int, minSize: Int, ev: Evidence) {
        let byProject = Dictionary(grouping: artifacts.filter { $0.bytes >= minSize / 4 }) { $0.project }
        var activeBytes = 0, activeCount = 0, activeObs: [String] = []
        for p in projects {
            guard let list = byProject[p.path], list.map(\.bytes).reduce(0, +) >= minSize else { continue }
            let total = list.map(\.bytes).reduce(0, +)
            let s = Paths.short(p.path)
            let activity = p.lastActivity.map { "last activity \(ago($0))" } ?? "no commits"
            if p.isActive(days: activeDays) {
                activeBytes += total
                activeCount += 1
                activeObs.append(ev.observe("git -C \(s) status / log", "\(s): \(activity), \(p.dirtyFiles) uncommitted file(s), \(human(total)) of build folders"))
                continue
            }
            var cites = [ev.observe("git -C \(s) log -1 / status", "\(s): \(activity), \(p.dirtyFiles) uncommitted file(s), branch \(p.branch ?? "?")")]
            var actions: [BoundAction] = []
            for a in list.sorted(by: { $0.bytes > $1.bytes }) {
                let rel = String(a.path.dropFirst(p.path.count + 1))
                let rebuild = a.manifest.map { "rebuild from \($0)" + (a.lock.map { " + \($0)" } ?? " (no lockfile: versions may change)") } ?? "regenerated automatically"
                cites.append(ev.observe("du -sk \(Paths.short(a.path))", "\(rel): \(human(a.bytes)) — \(a.rule.hint); \(rebuild)", value: .number(Double(a.bytes))))
                let safety = a.rule.locks.isEmpty || a.lock != nil ? 9 : 6
                actions.append(BoundAction(ActionCall("delete_build_artifact", ["path": a.path]), title: "Delete \(s)/\(rel)", kind: "clear",
                                           target: a.path, bytes: a.bytes, safety: safety, confidence: 9,
                                           reason: "\(a.rule.hint); \(rebuild)", command: "rm -rf \(Paths.short(a.path))"))
            }
            let severity: Severity = total >= 5 << 30 ? .medium : .low
            ev.find("build-artifacts", "\(s): \(human(total)) of rebuildable folders (\(activity))", severity: severity, cites: cites,
                    confidence: 85, explanation: "This project hasn't been touched in over \(activeDays) days and has no uncommitted changes. Its dependency and build folders can be rebuilt from the project's manifest when you come back to it.",
                    diagnostics: ["git_status"], subject: ["path": p.path], actions: actions)
        }
        if activeCount > 0 {
            ev.find("build-artifacts", "\(activeCount) active project(s) hold \(human(activeBytes)) of build folders (left alone)", severity: .info,
                    cites: Array(activeObs.prefix(10)), confidence: 90,
                    explanation: "These projects changed in the last \(activeDays) days or have uncommitted work, so bibi doesn't suggest deleting anything in them. Use --active-days to change that.")
        }
    }

    func cacheFindings(_ sizes: [String: Int], minSize: Int, ev: Evidence, policy: SafetyPolicy) {
        // Caches owned by the same tool (pnpm store + pnpm cache) become one finding with one cleanup.
        var groups: [(key: String, entries: [(String, String, Int)], tool: String?)] = []
        for (rel, label, tool) in Self.caches {
            let path = policy.home + "/" + rel
            guard let size = sizes[path], size > 0 else { continue }
            if let tool, Tools.available(tool), let i = groups.firstIndex(where: { $0.tool == tool }) {
                groups[i].entries.append((path, label, size))
            } else {
                groups.append((rel, [(path, label, size)], tool.flatMap { Tools.available($0) ? $0 : nil }))
            }
        }
        for g in groups {
            let size = g.entries.map(\.2).reduce(0, +)
            guard size >= minSize else { continue }
            let (path, label, _) = g.entries[0]
            let s = Paths.short(path)
            let cites = g.entries.map { ev.observe("du -sk \(Paths.short($0.0))", "\(Paths.short($0.0)) (\($0.1)) uses \(human($0.2))", value: .number(Double($0.2))) }
            let action: BoundAction
            if let tool = g.tool {
                action = BoundAction(ActionCall("tool_cleanup", ["tool": tool]), title: "Run \(tool) cleanup (\(label))", kind: "tool_cleanup",
                                     target: path, bytes: size, safety: 9, confidence: 8,
                                     reason: "\(tool) removes what it no longer needs and re-downloads on demand",
                                     command: Shell.join(Tools.commands[tool]!))
            } else if policy.isRegenerable(path) {
                action = BoundAction(ActionCall("clear_regenerable_dir", ["path": path]), title: "Clear \(s)", kind: "clear", target: path,
                                     bytes: size, safety: 8, confidence: 8, reason: "\(label) is re-created when needed", command: "rm -rf \(s)/*")
            } else {
                action = BoundAction(ActionCall("reveal", ["path": path]), title: "Review \(s)", kind: "review", target: path, bytes: size,
                                     safety: 10, confidence: 6, reason: "\(label): remove what you no longer use from inside it",
                                     command: "open -R \(s)", weight: 0.4)
            }
            ev.find("package-cache", "\(label): \(human(size))", severity: size >= 5 << 30 ? .medium : .low, cites: cites, confidence: 80,
                    explanation: "\(label) only holds downloaded or generated files; tools fetch them again when needed, at the cost of some time and bandwidth.",
                    subject: ["path": path], actions: [action])
        }
    }

    func sdkFindings(_ installs: [SDKInstall], pins: Pins, sizes: [String: Int], minSize: Int, ev: Evidence) {
        for i in SDKs.unused(installs, pins: pins) {
            let size = sizes[i.path] ?? 0
            guard size >= minSize / 2 else { continue }
            let s = Paths.short(i.path)
            let siblings = installs.filter { $0.manager == i.manager && $0.tool == i.tool && $0.version != i.version }.map(\.version)
            var cites = [ev.observe("ls \(Paths.short(Paths.parent(i.path)))", "\(i.manager) has \(i.tool) \(i.version) (\(human(size))); other versions: \(siblings.joined(separator: ", ").ifEmpty("none"))",
                                    value: .number(Double(size)))]
            let pinned = (pins.byTool[i.tool] ?? []).sorted()
            cites.append(ev.observe("bibi pin scan (.python-version, .nvmrc, .tool-versions...)",
                                    pinned.isEmpty ? "no project pins a \(i.tool) version" : "projects pin \(i.tool) \(pinned.joined(separator: ", ")); none match \(i.version)"))
            let action = i.removable
                ? BoundAction(ActionCall("trash_path", ["path": i.path]), title: "Move \(i.tool) \(i.version) (\(i.manager)) to Trash", kind: "trash",
                              target: i.path, bytes: size, safety: 7, confidence: 7,
                              reason: i.tool == "android-image"
                                  ? "Android emulator image; download it again from Android Studio's SDK Manager if needed"
                                  : "not pinned by any scanned project and not the global default; reinstall with \(i.manager) if needed",
                              command: "mv \(s) ~/.Trash/", reversible: true)
                : BoundAction(ActionCall("reveal", ["path": i.path]), title: "Review \(i.tool) \(i.version)", kind: "review", target: i.path,
                              bytes: size, safety: 10, confidence: 6, reason: "installed system-wide; remove it with its installer or sudo",
                              command: "open -R \(s)", weight: 0.4)
            let what = i.tool == "android-image" ? "Android system image \(i.version)" : "Unused \(i.tool) \(i.version) (\(i.manager))"
            ev.find("sdk", "\(what), \(human(size))", severity: size >= 1 << 30 ? .medium : .low,
                    cites: cites, confidence: i.tool == "android-image" ? 55 : 65,
                    explanation: i.tool == "android-image"
                        ? "Emulator images are large and easy to download again. Keep the ones your emulators (AVDs) still use."
                        : "No project bibi scanned pins this version and it isn't your default. Projects outside the scanned folders might still use it.",
                    subject: ["path": i.path], actions: [action])
        }
    }

    func worktreeFindings(_ repos: [String], ev: Evidence) async {
        for repo in repos {
            let out = await Command.run(["git", "-C", repo, "worktree", "list", "--porcelain"], timeout: 20)
            let list = Worktrees.parse(out.stdout).filter { !$0.main }
            guard !list.isEmpty else { continue }
            let s = Paths.short(repo)
            let prunable = list.filter { $0.prunable != nil }
            if !prunable.isEmpty {
                let o = ev.observe(out.source, "\(prunable.count) worktree(s) of \(s) point at folders that no longer exist: " + prunable.map { Paths.short($0.path) }.joined(separator: ", "))
                ev.find("git-worktree", "\(s): \(prunable.count) stale worktree record(s)", severity: .low, cites: [o], confidence: 95,
                        explanation: "Git still tracks worktrees whose folders were deleted. Pruning only removes that bookkeeping.",
                        actions: [BoundAction(ActionCall("git_worktree_prune", ["repo": repo]), title: "git worktree prune in \(s)", kind: "tool",
                                              target: repo, safety: 10, confidence: 9, reason: "removes records of deleted worktrees only",
                                              command: "git -C \(s) worktree prune")])
            }
            guard let main = await Worktrees.defaultBranch(repo) else { continue }
            let merged = await Worktrees.merged(repo, into: main)
            for w in list where w.prunable == nil && !w.locked {
                let status = await Command.run(["git", "-C", w.path, "status", "--porcelain"], timeout: 20)
                let dirty = status.lines.count
                let isMerged = w.branch.map(merged.contains) ?? false
                let o = ev.observe("git -C \(Paths.short(w.path)) status; git branch --merged \(main)",
                                   "worktree \(Paths.short(w.path)) on \(w.branch ?? "detached HEAD"): \(dirty) uncommitted file(s), \(isMerged ? "merged into \(main)" : "not merged into \(main)")")
                if dirty == 0 && isMerged {
                    ev.find("git-worktree", "Merged worktree \(Paths.short(w.path))", severity: .low, cites: [o], confidence: 85,
                            explanation: "This worktree has no uncommitted changes and its branch is already merged into \(main). Removing it deletes the folder; the branch stays.",
                            subject: ["path": w.path],
                            actions: [BoundAction(ActionCall("git_worktree_remove", ["repo": repo, "path": w.path]), title: "Remove worktree \(Paths.short(w.path))",
                                                  kind: "tool", target: w.path, safety: 8, confidence: 8, reason: "clean and merged; branch \(w.branch ?? "") is kept",
                                                  command: "git -C \(s) worktree remove \(Paths.short(w.path))")])
                } else if dirty > 0 {
                    ev.find("git-worktree", "Worktree \(Paths.short(w.path)) has uncommitted work", severity: .info, cites: [o], confidence: 90,
                            explanation: "Commit or stash the changes before removing this worktree.", diagnostics: ["git_status"], subject: ["path": w.path])
                }
            }
        }
    }

    func dockerFindings(_ d: Docker.Usage, minSize: Int, ev: Evidence) {
        let src = d.sources.first ?? "docker images"
        let dangling = d.images.filter(\.dangling)
        let danglingBytes = dangling.map(\.bytes).reduce(0, +)
        if danglingBytes >= minSize / 2 {
            let o = ev.observe(src, "\(dangling.count) untagged (dangling) image(s), \(human(danglingBytes))")
            ev.find("docker", "\(dangling.count) dangling Docker images (\(human(danglingBytes)))", severity: .low, cites: [o], confidence: 90,
                    explanation: "Untagged images are usually leftovers of rebuilt images; nothing refers to them by name.",
                    diagnostics: ["docker_df"],
                    actions: [BoundAction(ActionCall("tool_cleanup", ["tool": "docker-dangling"]), title: "docker image prune", kind: "tool_cleanup",
                                          target: "docker", bytes: danglingBytes, safety: 9, confidence: 9, reason: "removes untagged images only",
                                          command: "docker image prune -f")])
        }
        let unused = d.images.filter { !$0.dangling && !Docker.isUsed($0, by: d.usedImages) && $0.bytes >= minSize }.sorted { $0.bytes > $1.bytes }
        for img in unused.prefix(10) {
            let o = ev.observe(src, "image \(img.name) (\(img.id)), \(human(img.bytes)), created \(img.created); no container uses it")
            ev.find("docker", "Unused image \(img.name) (\(human(img.bytes)))", severity: img.bytes >= 2 << 30 ? .medium : .low, cites: [o],
                    confidence: 70, explanation: "No container, running or stopped, was created from this image. Pull or rebuild it if you need it again.",
                    actions: [BoundAction(ActionCall("docker_image_rm", ["image": img.id]), title: "docker rmi \(img.name)", kind: "docker",
                                          target: img.name, bytes: img.bytes, safety: 7, confidence: 7,
                                          reason: "unused; docker pull or a rebuild restores it", command: "docker rmi \(img.id)")])
        }
        for v in d.danglingVolumes where v.bytes >= minSize / 2 {
            let o = ev.observe(d.sources.last ?? "docker system df -v", "volume \(v.name): \(human(v.bytes)), used by no container")
            ev.find("docker", "Orphaned volume \(v.name) (\(human(v.bytes)))", severity: .low, cites: [o], confidence: 60,
                    explanation: "No container uses this volume, but volumes hold data (databases, uploads). Check what's in it before removing.",
                    actions: [BoundAction(ActionCall("docker_volume_rm", ["volume": v.name]), title: "docker volume rm \(v.name)", kind: "docker",
                                          target: v.name, bytes: v.bytes, safety: 3, confidence: 6, reason: "may hold data you can't recreate",
                                          command: "docker volume rm \(v.name)")])
        }
        if d.buildCacheBytes >= minSize {
            let o = ev.observe(d.sources.last ?? "docker system df -v", "unused build cache: \(human(d.buildCacheBytes))")
            ev.find("docker", "Docker build cache: \(human(d.buildCacheBytes))", severity: .low, cites: [o], confidence: 85,
                    explanation: "Build cache speeds up rebuilds; clearing it frees space and only makes the next build slower.",
                    actions: [BoundAction(ActionCall("docker_builder_prune"), title: "docker builder prune", kind: "tool_cleanup", target: "docker",
                                          bytes: d.buildCacheBytes, safety: 9, confidence: 9, reason: "the next builds refill it",
                                          command: "docker builder prune -f")])
        }
    }
}
