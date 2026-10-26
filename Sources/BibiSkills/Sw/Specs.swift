import BibiCore
import Foundation

let packageName = "^[A-Za-z0-9@+._/-]{1,128}$"

/// `brew upgrade` one formula or cask. Not undoable: Homebrew keeps no previous version to roll back to.
public struct BrewUpgrade: ActionSpec {
    public let id = "brew_upgrade"
    public let summary = "Upgrade one Homebrew formula or cask"

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let name = try require(p, "name")
        guard Re.test(packageName, name) else { throw ActionError("not a package name: \(name)") }
        guard Command.which("brew") != nil else { throw ActionError("Homebrew is not installed") }
    }

    func argv(_ p: Params) -> [String] { ["brew", "upgrade"] + (p["cask"] == "true" ? ["--cask"] : []) + [p["name"]!] }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        [Shell.join(argv(p)), "cannot be undone automatically; `brew pin \(p["name"]!)` beforehand keeps a version you depend on"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let name = p["name"]!
        let info = await Command.run(["brew", "info", "--json=v2"] + (p["cask"] == "true" ? ["--cask"] : []) + [name], timeout: 60)
        let pkg = Inventory.parseBrew(info.stdout).first
        guard let pkg, pkg.outdated else { throw ActionError("\(name) is not installed or already up to date") }
        try await Command.run(argv(p), timeout: 1800).check()
        return Outcome("upgraded \(name) from \(pkg.installed) (to undo, reinstall that version yourself)")
    }
}

/// `brew uninstall` for a formula nothing else depends on.
public struct BrewUninstall: ActionSpec {
    public let id = "brew_uninstall"
    public let summary = "Uninstall a Homebrew formula nothing depends on"

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let name = try require(p, "name")
        guard Re.test(packageName, name), Command.which("brew") != nil else { throw ActionError("not a package name: \(name)") }
    }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        ["brew uninstall \(p["name"]!)   (brew install \(p["name"]!) brings it back)"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let name = p["name"]!
        let uses = await Command.run(["brew", "uses", "--installed", name], timeout: 120)
        guard uses.ok, uses.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ActionError("other installed formulae depend on \(name): \(uses.lines.prefix(5).joined(separator: ", "))")
        }
        try await Command.run(["brew", "uninstall", name], timeout: 600).check()
        return Outcome("uninstalled \(name)")
    }
}

public struct NpmGlobalUninstall: ActionSpec {
    public let id = "npm_global_uninstall"
    public let summary = "Uninstall a global npm package"

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let name = try require(p, "package")
        guard Re.test(packageName, name), Command.which("npm") != nil else { throw ActionError("not a package name: \(name)") }
    }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] { ["npm uninstall -g \(p["package"]!)"] }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        try await Command.run(["npm", "uninstall", "-g", p["package"]!], timeout: 300).check()
        return Outcome("uninstalled \(p["package"]!)")
    }
}
