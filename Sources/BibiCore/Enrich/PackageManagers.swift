import Foundation

/// Outdated-package queries. These commands contact their registries, so they go through the Fetcher's online gate.
public enum PackageManagers {
    public struct Outdated: Sendable, Codable, Hashable {
        public var manager: String  // brew, brew-cask, npm, pip, macos
        public var name: String
        public var installed: String
        public var latest: String
        public var pinned: Bool
    }

    public static func brew(_ fetcher: Fetcher) async throws -> [Outdated] {
        guard Command.which("brew") != nil else { return [] }
        let out = try await fetcher.command(["brew", "outdated", "--json=v2"], timeout: 300)
        return parseBrew(out.stdout)
    }

    public static func parseBrew(_ text: String) -> [Outdated] {
        guard let v = try? JSON.decode(JSONValue.self, from: text) else { return [] }
        let formulae = (v["formulae"]?.array ?? []).map { f in
            Outdated(manager: "brew", name: f["name"]?.string ?? "?", installed: f["installed_versions"]?.strings?.last ?? "?",
                     latest: f["current_version"]?.string ?? "?", pinned: f["pinned"]?.bool ?? false)
        }
        let casks = (v["casks"]?.array ?? []).map { c in
            Outdated(manager: "brew-cask", name: c["name"]?.string ?? "?",
                     installed: c["installed_versions"]?.strings?.last ?? c["installed_versions"]?.string ?? "?",
                     latest: c["current_version"]?.string ?? "?", pinned: false)
        }
        return formulae + casks
    }

    public static func npmGlobal(_ fetcher: Fetcher) async throws -> [Outdated] {
        guard Command.which("npm") != nil else { return [] }
        // npm outdated exits 1 when something is outdated; the JSON is still valid.
        let out = try await fetcher.command(["npm", "outdated", "-g", "--json"], timeout: 120)
        return parseNpm(out.stdout)
    }

    public static func parseNpm(_ text: String) -> [Outdated] {
        guard let v = try? JSON.decode(JSONValue.self, from: text), let o = v.object else { return [] }
        return o.keys.sorted().map { k in
            Outdated(manager: "npm", name: k, installed: o[k]?["current"]?.string ?? "?", latest: o[k]?["latest"]?.string ?? "?", pinned: false)
        }
    }

    public static func pip(_ fetcher: Fetcher, python: String = "python3") async throws -> [Outdated] {
        guard Command.which(python) != nil else { return [] }
        let out = try await fetcher.command([python, "-m", "pip", "list", "--outdated", "--format", "json", "--disable-pip-version-check"],
                                            timeout: 180)
        return parsePip(out.stdout)
    }

    public static func parsePip(_ text: String) -> [Outdated] {
        guard let v = try? JSON.decode(JSONValue.self, from: text), let a = v.array else { return [] }
        return a.map { p in
            Outdated(manager: "pip", name: p["name"]?.string ?? "?", installed: p["version"]?.string ?? "?",
                     latest: p["latest_version"]?.string ?? "?", pinned: false)
        }
    }

    public static func macOSUpdates(_ fetcher: Fetcher) async throws -> [Outdated] {
        let out = try await fetcher.command(["softwareupdate", "-l"], timeout: 180)
        return parseSoftwareUpdate(out.stdout + "\n" + out.stderr)
    }

    /// "* Label: macOS Sequoia 15.1-24B83\n\tTitle: macOS Sequoia 15.1, Version: 15.1, Size: ..., Recommended: YES, Action: restart,"
    public static func parseSoftwareUpdate(_ text: String) -> [Outdated] {
        Re.all("Title: ([^,\\n]+), Version: ([^,\\n]+)", text).map {
            Outdated(manager: "macos", name: $0[1].trimmingCharacters(in: .whitespaces), installed: "",
                     latest: $0[2].trimmingCharacters(in: .whitespaces), pinned: false)
        }
    }
}

/// Version comparison good enough for upgrade-risk heuristics.
public enum Version {
    public static func parts(_ v: String) -> [Int] {
        v.split(whereSeparator: { !$0.isNumber }).prefix(4).compactMap { Int($0) }
    }

    public static func major(_ v: String) -> Int? { parts(v).first }

    /// "major", "minor", "patch" or nil when unknown.
    public static func bump(from a: String, to b: String) -> String? {
        let x = parts(a), y = parts(b)
        guard !x.isEmpty, !y.isEmpty else { return nil }
        if x[0] != y[0] { return "major" }
        if x.count > 1, y.count > 1, x[1] != y[1] { return "minor" }
        return "patch"
    }

    public static func less(_ a: String, _ b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q }
        }
        return false
    }
}
