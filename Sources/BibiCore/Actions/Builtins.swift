import Foundation

/// Actions available to every skill.
public enum Builtins {
    public static let all: [any ActionSpec] = [
        TrashPath(), RestorePath(), ClearRegenerableDir(), EmptyTrash(), ToolCleanup(), Reveal(), OpenURL(), OpenApp(),
        OpenSettingsPane(), RunDiagnostic(admin: false), RunDiagnostic(admin: true),
        RunCommand(admin: false), RunCommand(admin: true), RunSkillSpec(),
    ] + Recipes.all
}

func requireAbsolute(_ path: String, _ id: String) throws -> String {
    guard path.hasPrefix("/"), !path.contains("/../"), !path.hasSuffix("/..") else {
        throw ActionError("\(id): not an absolute path: \(path)")
    }
    return Paths.standardize(path)
}

/// Moves a file or folder to the Trash (Finder's "Put Back" still works). Reversible.
public struct TrashPath: ActionSpec {
    public let id = "trash_path"
    public let summary = "Move a file or folder to the Trash"
    public var reversible: Bool { true }

    /// `app=true` allows exactly one top-level app bundle in /Applications or ~/Applications.
    static func isTopLevelApp(_ path: String, _ policy: SafetyPolicy) -> Bool {
        Paths.ext(path) == "app" && ["/Applications", policy.home + "/Applications"].contains(Paths.parent(path))
    }

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let path = try requireAbsolute(try require(p, "path"), id)
        guard Paths.exists(path) || Paths.isSymlink(path) else { throw ActionError("\(Paths.short(path)) no longer exists") }
        if p["app"] == "true" {
            guard Self.isTopLevelApp(path, env.policy) else { throw ActionError("\(Paths.short(path)) is not an app in Applications") }
            return
        }
        if env.policy.isProtected(path) { throw ActionError("\(Paths.short(path)) is protected; review it yourself instead") }
        if Paths.isDirectory(path) && Paths.exists(path + "/.git") {
            throw ActionError("\(Paths.short(path)) is a git repository; bibi never trashes repositories")
        }
    }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        ["move \(Paths.short(p["path"]!)) to the Trash (restorable with bibi undo or Finder's Put Back)"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let path = Paths.standardize(p["path"]!)
        var result: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
        let dest = result?.path ?? env.policy.trash + "/" + Paths.name(path)
        return Outcome("moved to Trash (\(Paths.short(dest))); empty the Trash to reclaim the space",
                       undo: ActionCall("restore_path", ["from": dest, "to": path]))
    }
}

/// Undo for trash/quarantine moves.
public struct RestorePath: ActionSpec {
    public let id = "restore_path"
    public let summary = "Move a trashed or quarantined item back where it was"
    public var selectable: Bool { false }

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let from = try requireAbsolute(try require(p, "from"), id), to = try requireAbsolute(try require(p, "to"), id)
        guard Paths.exists(from) else { throw ActionError("\(Paths.short(from)) is gone (was the Trash emptied?)") }
        guard !Paths.exists(to) else { throw ActionError("\(Paths.short(to)) already exists; not overwriting it") }
        let allowed = [env.policy.trash, Quarantine.root]
        guard allowed.contains(where: { Paths.isWithin(from, $0) }) else { throw ActionError("can only restore from the Trash or quarantine") }
    }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        ["move \(Paths.short(p["from"]!)) back to \(Paths.short(p["to"]!))"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let to = p["to"]!
        try FileManager.default.createDirectory(atPath: Paths.parent(to), withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: p["from"]!, toPath: to)
        return Outcome("restored \(Paths.short(to))")
    }
}

/// Deletes the contents of a folder that rules recognize as regenerable (caches, logs, build output).
public struct ClearRegenerableDir: ActionSpec {
    public let id = "clear_regenerable_dir"
    public let summary = "Delete the contents of a cache, log or build folder (regenerated automatically)"

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let path = try requireAbsolute(try require(p, "path"), id)
        guard Paths.isDirectory(path) else { throw ActionError("\(Paths.short(path)) is not a folder") }
        guard env.policy.isRegenerable(path) else { throw ActionError("\(Paths.short(path)) is not a known regenerable folder") }
        guard !env.policy.isProtected(path) else { throw ActionError("\(Paths.short(path)) is protected") }
    }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        ["permanently delete everything inside \(Paths.short(p["path"]!)) (it is regenerated when needed)"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        Outcome(Self.deleteContents(p["path"]!))
    }

    static func deleteContents(_ path: String) -> String {
        var failed = 0
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            do { try FileManager.default.removeItem(atPath: path + "/" + entry) } catch { failed += 1 }
        }
        return "emptied \(Paths.short(path))" + (failed > 0 ? " (\(failed) item(s) could not be removed)" : "")
    }
}

public struct EmptyTrash: ActionSpec {
    public let id = "empty_trash"
    public let summary = "Empty the Trash"
    public func validate(_ p: Params, _ env: ActionEnv) throws {}
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] { ["permanently delete everything in ~/.Trash"] }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        Outcome(ClearRegenerableDir.deleteContents(env.policy.trash))
    }
}

/// Runs a tool's own cleanup command from the fixed Tools table.
public struct ToolCleanup: ActionSpec {
    public let id = "tool_cleanup"
    public let summary = "Run a tool's own cleanup (brew, docker, npm, pip, go, simctl, cargo)"

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let tool = try require(p, "tool")
        guard Tools.commands[tool] != nil else { throw ActionError("unknown tool '\(tool)'") }
        guard Tools.available(tool) else { throw ActionError("\(tool) is not installed or not working") }
    }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] { ["run " + Shell.join(Tools.commands[p["tool"]!]!)] }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let argv = Tools.commands[p["tool"]!]!
        try await Command.run(argv, timeout: 1800).check()
        return Outcome("ran \(Shell.join(argv))")
    }
}

public struct Reveal: ActionSpec {
    public let id = "reveal"
    public let summary = "Show an item in Finder for manual review"
    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let path = try requireAbsolute(try require(p, "path"), id)
        guard Paths.exists(path) else { throw ActionError("\(Paths.short(path)) no longer exists") }
    }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] { ["open -R \(Paths.short(p["path"]!))   (manual review in Finder)"] }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        _ = await Command.run(["open", "-R", p["path"]!])
        return Outcome("revealed \(Paths.short(p["path"]!)) in Finder")
    }
}

public struct OpenURL: ActionSpec {
    public let id = "open_url"
    public let summary = "Open a web page in the browser"
    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let url = try require(p, "url")
        guard let u = URL(string: url), ["http", "https"].contains(u.scheme ?? ""), u.host != nil else {
            throw ActionError("not a web URL: \(url)")
        }
    }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] { ["open \(p["url"]!)"] }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        _ = await Command.run(["open", p["url"]!])
        return Outcome("opened \(p["url"]!)")
    }
}

/// Opens an installed app, or brings it forward. The name is matched loosely ("garageband" is GarageBand.app, "word"
/// is Microsoft Word) against the apps really installed, so nothing else can be opened.
public struct OpenApp: ActionSpec {
    public let id = "open_app"
    public let summary = "Open an app"

    public init() {}

    static func folders(home: String) -> [String] {
        ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", home + "/Applications"]
    }

    /// Letters and digits only, lowercased: "Garage Band.app" and "garageband" are the same app.
    static func key(_ name: String) -> String {
        let n = name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
        return n.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// App bundles in the app folders and their subfolders ("/Applications/Microsoft Office/…").
    static func folderApps(home: String) -> [String] {
        let fm = FileManager.default
        return folders(home: home).flatMap { dir -> [String] in
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted().flatMap { e -> [String] in
                let path = dir + "/" + e
                if Paths.ext(e) == "app" { return [path] }
                guard Paths.isDirectory(path), !e.hasPrefix(".") else { return [] }
                return ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted().filter { Paths.ext($0) == "app" }.map { path + "/" + $0 }
            }
        }
    }

    /// Every other app Spotlight knows (Setapp, Homebrew casks, apps kept elsewhere), without helpers inside bundles.
    static func spotlightApps() -> [String] {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["kMDItemContentType == \"com.apple.application-bundle\""]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { Paths.ext($0) == "app" && !Paths.parent($0).contains(".app/") && !Paths.parent($0).hasSuffix(".app") }
    }

    /// Apps the name could mean: the one whose name it is, else those whose name contains it.
    public static func candidates(_ name: String, home: String) -> [String] {
        let k = key(Paths.name(name))
        guard !k.isEmpty else { return [] }
        let local = folderApps(home: home)
        if let exact = local.first(where: { key(Paths.name($0)) == k }) { return [exact] }
        let all = local + spotlightApps()
        if let exact = all.first(where: { key(Paths.name($0)) == k }) { return [exact] }
        var seen = Set<String>()
        return all.filter { key(Paths.name($0)).contains(k) && seen.insert(key(Paths.name($0))).inserted }
    }

    /// The bundle path of the app called `name`, if exactly one installed app fits.
    public static func find(_ name: String, home: String) -> String? {
        let c = candidates(name, home: home)
        return c.count == 1 ? c[0] : nil
    }

    /// The app's own name, so the card shows what will open.
    public func normalize(_ p: Params, _ env: ActionEnv) -> Params {
        guard let path = p["app"].flatMap({ Self.find($0, home: env.policy.home) }) else { return p }
        var p = p
        p["app"] = String(Paths.name(path).dropLast(4))
        return p
    }

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let name = try require(p, "app")
        let c = Self.candidates(name, home: env.policy.home)
        if c.count > 1 {
            throw ActionError("app: \(name) could be " + c.prefix(4).map { String(Paths.name($0).dropLast(4)) }.joined(separator: ", "))
        }
        guard !c.isEmpty else { throw ActionError("app: no app named \(name) is installed") }
    }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        ["open -a \(Paths.short(Self.find(p["app"]!, home: env.policy.home) ?? p["app"]!))"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        guard let path = Self.find(p["app"]!, home: env.policy.home) else { throw ActionError("\(p["app"]!) is no longer installed") }
        let out = await Command.run(["open", path])
        guard out.ok else { throw ActionError("couldn't open \(Paths.name(path)): \(out.stderr.ifEmpty("exit \(out.status)"))") }
        return Outcome("opened \(Paths.name(path).dropLast(4))")
    }
}

/// Opens a System Settings pane: the fallback for anything bibi shouldn't change itself.
public struct OpenSettingsPane: ActionSpec {
    public let id = "open_settings_pane"
    public let summary = "Open a System Settings pane"
    public static let panes: [String: String] = [
        "firewall": "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall",
        "sharing": "x-apple.systempreferences:com.apple.Sharing-Settings.extension",
        "privacy": "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        "filevault": "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault",
        "login-items": "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
        "software-update": "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
        "battery": "x-apple.systempreferences:com.apple.Battery-Settings.extension",
        "lock-screen": "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension",
        "users": "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension",
        "storage": "x-apple.systempreferences:com.apple.settings.Storage",
        "profiles": "x-apple.systempreferences:com.apple.Profiles-Settings.extension",
    ]
    public func validate(_ p: Params, _ env: ActionEnv) throws {
        guard Self.panes[try require(p, "pane")] != nil else { throw ActionError("unknown settings pane '\(p["pane"]!)'") }
    }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] { ["open System Settings > \(p["pane"]!)"] }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        _ = await Command.run(["open", Self.panes[p["pane"]!]!])
        return Outcome("opened System Settings (\(p["pane"]!))")
    }
}

/// Runs a read-only diagnostic from the catalog. Its output becomes new evidence in the run.
/// Two registry entries: run_diagnostic (user) and run_admin_diagnostic (admin, password each time).
public struct RunDiagnostic: ActionSpec {
    let admin: Bool
    public init(admin: Bool = false) { self.admin = admin }
    public var id: String { admin ? "run_admin_diagnostic" : "run_diagnostic" }
    public var summary: String { admin ? "Run a read-only diagnostic that needs administrator rights" : "Run a read-only diagnostic command" }
    public var privilege: Privilege { admin ? .admin : .user }

    func resolve(_ p: Params) throws -> (Diagnostic, [String]) {
        guard let d = Diagnostics.get(try require(p, "diagnostic")) else { throw ActionError("unknown diagnostic '\(p["diagnostic"]!)'") }
        guard d.admin == admin else { throw ActionError("\(d.id) must run as \(d.admin ? "run_admin_diagnostic" : "run_diagnostic")") }
        var subject = p
        subject.removeValue(forKey: "diagnostic")
        guard let argv = d.command(subject: subject) else { throw ActionError("\(d.id): missing or unsafe parameters") }
        return (d, argv)
    }

    public func validate(_ p: Params, _ env: ActionEnv) throws { _ = try resolve(p) }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        let (_, argv) = try resolve(p)
        return [(admin ? "sudo " : "") + Shell.join(argv) + "   (read-only)"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let (d, argv) = try resolve(p)
        let text: String
        if admin {
            text = try await env.admin.run(argv)
        } else {
            let out = await Command.run(argv, timeout: d.timeout)
            if !out.ok && out.stdout.isEmpty { try out.check() }
            text = out.stdout + (out.stderr.isEmpty ? "" : "\n" + out.stderr)
        }
        return Outcome("ran \(d.title.lowercased())", output: String(text.prefix(20000)))
    }

    /// The call for a diagnostic on a finding's subject.
    public static func call(_ d: Diagnostic, subject: [String: String]) -> ActionCall {
        var p = subject
        p["diagnostic"] = d.id
        return ActionCall(d.admin ? "run_admin_diagnostic" : "run_diagnostic", p)
    }
}
