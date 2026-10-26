import BibiCore
import Foundation

/// A launchd job definition (login agent or daemon) and what launchctl says about it.
public struct LaunchItem: Sendable, Codable {
    public enum Scope: String, Sendable, Codable { case user, systemAgent, systemDaemon }
    public var path: String
    public var scope: Scope
    public var label: String
    public var program: String?  // resolved executable (first ProgramArguments entry or Program)
    public var arguments: [String]
    public var runAtLoad: Bool
    public var keepAlive: Bool
    public var disabled: Bool
    public var loaded: Bool
    public var pid: Int?
    public var lastExit: Int?

    public var isApple: Bool { label.hasPrefix("com.apple.") }
    public var programExists: Bool { program.map { Paths.exists($0) } ?? true }
    public var display: String { "\(label) (\(Paths.short(path)))" }
}

public enum LaunchItems {
    public static func directories(home: String = Paths.home) -> [(String, LaunchItem.Scope)] {
        [(home + "/Library/LaunchAgents", .user), ("/Library/LaunchAgents", .systemAgent), ("/Library/LaunchDaemons", .systemDaemon)]
    }

    /// `launchctl list` output -> label: (pid, last exit status). Only covers the user's own domain.
    public static func parseList(_ text: String) -> [String: (pid: Int?, status: Int?)] {
        var out: [String: (Int?, Int?)] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { continue }
            out[String(cols[2])] = (Int(cols[0]), Int(cols[1]))
        }
        return out
    }

    public static func parse(_ path: String, scope: LaunchItem.Scope, plist: [String: Any]) -> LaunchItem {
        let args = (plist["ProgramArguments"] as? [String]) ?? []
        let program = (plist["Program"] as? String) ?? args.first
        let keepAlive: Bool = {
            if let b = plist["KeepAlive"] as? Bool { return b }
            return plist["KeepAlive"] is [String: Any]
        }()
        return LaunchItem(path: path, scope: scope, label: (plist["Label"] as? String) ?? Paths.name(path),
                          program: program, arguments: args, runAtLoad: (plist["RunAtLoad"] as? Bool) ?? false,
                          keepAlive: keepAlive, disabled: (plist["Disabled"] as? Bool) ?? false, loaded: false, pid: nil, lastExit: nil)
    }

    /// All third-party (and Apple, if any were added) plists in the three launchd folders, with live state where visible.
    public static func scan() async -> (items: [LaunchItem], listSource: String) {
        let list = await Command.run(["launchctl", "list"])
        let state = parseList(list.stdout)
        var items: [LaunchItem] = []
        for (dir, scope) in directories() {
            for path in Paths.children(dir) where Paths.ext(path) == "plist" {
                guard let plist = Plist.read(path) else { continue }
                var item = parse(path, scope: scope, plist: plist)
                if let s = state[item.label] {
                    item.loaded = true
                    item.pid = s.pid
                    item.lastExit = s.status
                }
                items.append(item)
            }
        }
        return (items, list.source)
    }
}

/// Moves a login agent's plist into bibi's quarantine after unloading it. Reversible.
public struct DisableLaunchItem: ActionSpec {
    public let admin: Bool
    public init(admin: Bool) { self.admin = admin }
    public var id: String { admin ? "disable_launch_item_admin" : "disable_login_agent" }
    public var summary: String { admin ? "Unload a system launch agent/daemon and quarantine its plist" : "Unload a login agent and quarantine its plist" }
    public var privilege: Privilege { admin ? .admin : .user }
    public var reversible: Bool { true }

    static func scope(of path: String) -> LaunchItem.Scope? {
        let dir = Paths.parent(path)
        return LaunchItems.directories().first { $0.0 == dir }?.1
    }

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let path = try require(p, "path")
        guard Paths.ext(path) == "plist", Paths.exists(path), let scope = Self.scope(of: path) else {
            throw ActionError("\(Paths.short(path)) is not a plist in a LaunchAgents/LaunchDaemons folder")
        }
        guard (scope == .user) != admin else {
            throw ActionError("\(Paths.short(path)) needs \(scope == .user ? "disable_login_agent" : "disable_launch_item_admin")")
        }
        if let label = Plist.read(path)?["Label"] as? String, label.hasPrefix("com.apple.") {
            throw ActionError("bibi does not disable Apple's own launch items")
        }
    }

    static func domain(_ path: String) -> String {
        scope(of: path) == .systemDaemon ? "system" : "gui/\(getuid())"
    }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        let path = p["path"]!
        return [(admin ? "sudo " : "") + "launchctl bootout \(Self.domain(path)) \(Paths.short(path))",
                "move \(Paths.short(path)) to \(Paths.short(Quarantine.root))/… (restorable with bibi undo)"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let path = p["path"]!
        let dest = Quarantine.destination(for: path)
        let domain = Self.domain(path)
        if admin {
            // One password prompt for the whole step: a fixed script with the paths passed as arguments.
            _ = try await env.admin.run(["/bin/sh", "-c", "launchctl bootout \"$1\" \"$2\" 2>/dev/null; mkdir -p \"$(dirname \"$3\")\" && mv \"$2\" \"$3\"",
                                         "bibi", domain, path, dest])
        } else {
            _ = await Command.run(["launchctl", "bootout", domain, path])
            try FileManager.default.createDirectory(atPath: Paths.parent(dest), withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: path, toPath: dest)
        }
        return Outcome("unloaded and quarantined \(Paths.short(path))",
                       undo: ActionCall(admin ? "restore_launch_item_admin" : "restore_login_agent", ["from": dest, "to": path]))
    }
}

/// Undo for DisableLaunchItem: move the plist back and load it again.
public struct RestoreLaunchItem: ActionSpec {
    public let admin: Bool
    public init(admin: Bool) { self.admin = admin }
    public var id: String { admin ? "restore_launch_item_admin" : "restore_login_agent" }
    public var summary: String { "Restore a quarantined launch item" }
    public var privilege: Privilege { admin ? .admin : .user }
    public var selectable: Bool { false }

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let from = try require(p, "from"), to = try require(p, "to")
        guard Paths.isWithin(from, Quarantine.root), Paths.exists(from) else { throw ActionError("nothing to restore at \(Paths.short(from))") }
        guard DisableLaunchItem.scope(of: to) != nil, !Paths.exists(to) else { throw ActionError("cannot restore to \(Paths.short(to))") }
    }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        ["move \(Paths.short(p["from"]!)) back to \(Paths.short(p["to"]!))", "launchctl bootstrap \(DisableLaunchItem.domain(p["to"]!)) it"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let from = p["from"]!, to = p["to"]!
        let domain = DisableLaunchItem.domain(to)
        if admin {
            _ = try await env.admin.run(["/bin/sh", "-c", "mv \"$1\" \"$2\" && launchctl bootstrap \"$3\" \"$2\"", "bibi", from, to, domain])
        } else {
            try FileManager.default.moveItem(atPath: from, toPath: to)
            _ = await Command.run(["launchctl", "bootstrap", domain, to])
        }
        return Outcome("restored and loaded \(Paths.short(to))")
    }
}

extension LaunchItem {
    /// The action that disables this item (user or admin variant).
    public func disableAction(reason: String, safety: Int, confidence: Int) -> BoundAction {
        let admin = scope != .user
        return BoundAction(ActionCall(admin ? "disable_launch_item_admin" : "disable_login_agent", ["path": path]),
                           title: "Disable \(label)", kind: "disable", target: path, safety: safety, confidence: confidence,
                           reason: reason, command: (admin ? "sudo " : "") + "launchctl bootout … && mv \(Paths.short(path)) quarantine",
                           privilege: admin ? .admin : .user, reversible: true)
    }
}

public enum LaunchItemSpecs {
    public static let all: [any ActionSpec] = [DisableLaunchItem(admin: false), DisableLaunchItem(admin: true),
                                               RestoreLaunchItem(admin: false), RestoreLaunchItem(admin: true)]
}
