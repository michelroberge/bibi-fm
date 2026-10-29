import Foundation

/// What a known path is, ported from the storage catalog: a hint for the model, whether it regenerates on its own,
/// and which tool owns its cleanup.
public struct PathKnowledge: Sendable {
    public var hint: String?
    public var regenerable: Bool
    public var tool: String?
}

/// Rules about which paths may be modified. Tests can relax `protectedPrefixes` (temp dirs live under /private).
public struct SafetyPolicy: Sendable {
    public var home: String
    public var protectedExact: Set<String>
    public var protectedPrefixes: [String]
    /// Overrides the regenerable rule (tests only).
    public var regenerableOverride: (@Sendable (String) -> Bool)?
    /// Programs the user added in Settings: allowed ones count as read-only (bibi's structural rules still apply),
    /// blocked ones are refused.
    public var allowCommands: Set<String> = []
    public var blockCommands: Set<String> = []

    public init(home: String = Paths.home) {
        self.home = home
        let h = { (p: String) in home + "/" + p }
        protectedExact = ["/", home, h("Library"), h("Documents"), h("Desktop"), h("Pictures"), h("Movies"), h("Music"),
                          h("Downloads"), h("Applications"), h("Library/Application Support"), h("Library/Containers"),
                          h("Library/Group Containers")]
        protectedPrefixes = ["/System", "/usr", "/bin", "/sbin", "/private", "/Library", "/Applications", "/opt", "/Volumes",
                             h("Library/Mobile Documents"), h("Library/Mail"), h("Library/Messages"), h("Library/Keychains"),
                             h("Library/CloudStorage"), h("Library/Application Support/MobileSync"), h(".ssh"), h(".gnupg")]
        regenerableOverride = nil
    }

    public var trash: String { home + "/.Trash" }

    public func isProtected(_ path: String) -> Bool {
        if protectedExact.contains(path) || Paths.parts(path).contains(where: { $0.hasSuffix(".app") }) { return true }
        if Paths.isWithin(path, home + "/Library/Caches") || Paths.isWithin(path, home + "/Library/Logs") { return false }
        return protectedPrefixes.contains { Paths.isWithin(path, $0) }
    }

    public func knowledge(_ path: String) -> PathKnowledge {
        let parts = Paths.parts(path), name = Paths.name(path), ext = Paths.ext(path)
        let parent = Paths.name(Paths.parent(path))
        let rules: [(Bool, String, Bool, String?)] = [
            (path == trash, "the user's Trash; emptying it frees space permanently", false, nil),
            (parts.suffix(3) == ["go", "pkg", "mod"], "Go module cache, re-downloaded on demand", true, "go"),
            (parent == "avd" && ext == "avd", "Android emulator image; recreatable in Android Studio", false, nil),
            (parts.suffix(2) == ["Android", "sdk"], "Android SDK; remove unused system images via Android Studio's SDK Manager", false, nil),
            (parts.contains("DerivedData"), "Xcode build artifacts, rebuilt automatically", true, nil),
            (parts.contains("CoreSimulator"), "iOS simulator data; stale devices removable via simctl", false, "simctl"),
            (parts.contains("Homebrew") && parts.contains("Caches"), "Homebrew download cache", true, "brew"),
            (name == "Docker.raw" || name == "com.docker.docker", "Docker disk image; prune unused images/containers", false, "docker"),
            (parts.contains("_cacache") || path == home + "/.npm", "npm cache", true, "npm"),
            (name == "pip" && (parts.contains("Caches") || parts.contains(".cache")), "pip download cache", true, "pip"),
            (name == "node_modules", "npm dependencies, reinstallable with npm install", true, nil),
            (name == ".venv" || name == "venv", "Python virtualenv, recreatable", true, nil),
            (name == ".gradle" || (name == "caches" && parts.contains(".gradle")), "Gradle caches", true, nil),
            (parts.contains("MobileSync"), "iPhone/iPad backups; manage in Finder, do not delete blindly", false, nil),
            (parts.contains("Caches") || name == ".cache", "application cache, regenerated automatically", true, nil),
            (parts.contains("Logs"), "log files", true, nil),
            (["dmg", "pkg", "iso", "xip"].contains(ext), "installer image; usually removable after install", false, nil),
            (["zip", "tar", "gz", "tgz", "rar", "7z"].contains(ext), "archive file", false, nil),
            (path == home + "/Downloads", "user downloads; often old installers and archives", false, nil),
            (path == home + "/Library", "app data, caches, containers; mixed content", false, nil),
        ]
        for (matches, hint, regen, tool) in rules where matches {
            return PathKnowledge(hint: hint, regenerable: regenerableOverride?(path) ?? regen, tool: tool)
        }
        return PathKnowledge(hint: nil, regenerable: regenerableOverride?(path) ?? false, tool: nil)
    }

    public func isRegenerable(_ path: String) -> Bool { knowledge(path).regenerable }
    public func hint(_ path: String) -> String? { knowledge(path).hint }
}

/// Cleanup commands owned by a tool. The only argv the tool_cleanup action can run.
public enum Tools {
    public static let commands: [String: [String]] = [
        "brew": ["brew", "cleanup", "-s", "--prune=all"],
        "docker": ["docker", "system", "prune", "-f"],
        "docker-dangling": ["docker", "image", "prune", "-f"],
        "simctl": ["xcrun", "simctl", "delete", "unavailable"],
        "npm": ["npm", "cache", "clean", "--force"],
        "pip": ["pip3", "cache", "purge"],
        "go": ["go", "clean", "-modcache"],
        "cargo": ["cargo", "cache", "--autoclean"],
        "pnpm": ["pnpm", "store", "prune"],
        "yarn": ["yarn", "cache", "clean"],
        "uv": ["uv", "cache", "prune"],
    ]

    /// How to check a tool really works. `xcrun` exists with the Command Line Tools alone, but simctl needs Xcode.
    static let checks: [String: [String]] = [
        "simctl": ["xcrun", "--find", "simctl"],
        "go": ["go", "env", "GOMODCACHE"],
        "docker": ["docker", "info", "--format", "{{.ServerVersion}}"],
        "docker-dangling": ["docker", "info", "--format", "{{.ServerVersion}}"],
        "cargo": ["cargo", "cache", "--version"],
    ]

    private static let cache = Mutex<[String: Bool]>([:])

    public static func available(_ key: String) -> Bool {
        if let hit = cache.withLock({ $0[key] }) { return hit }
        var ok = false
        if let argv = commands[key], Command.which(argv[0]) != nil {
            if let check = checks[key] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: Command.which(check[0])!)
                p.arguments = Array(check.dropFirst())
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                ok = (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
            } else {
                ok = true
            }
        }
        cache.withLock { $0[key] = ok }
        return ok
    }
}

/// A small lock-protected value (Synchronization.Mutex needs a non-copyable dance that is overkill here).
public final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    public init(_ value: Value) { self.value = value }
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
