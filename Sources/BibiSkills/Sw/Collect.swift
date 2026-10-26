import BibiCore
import CoreServices
import Foundation

public struct AppInfo: Sendable {
    public var path: String
    public var name: String
    public var bundleID: String
    public var version: String
    public var archs: [String]
    public var lastUsed: Date?
    public var appStore: Bool

    public var isApple: Bool { bundleID.hasPrefix("com.apple.") }
    public var intelOnly: Bool { archs == ["x86_64"] }
}

public struct BrewPackage: Sendable {
    public var name: String
    public var cask: Bool
    public var installed: String
    public var latest: String
    public var outdated: Bool
    public var pinned: Bool
    public var deprecated: Bool
    public var disabled: Bool
    public var onRequest: Bool
    public var autoUpdates: Bool
    public var apps: [String]
    public var dependencies: [String]
}

public struct RuntimeInstall: Sendable, Hashable {
    public var tool: String
    public var path: String
    public var version: String
    public var source: String
}

public enum Inventory {
    // MARK: apps

    public static func appPaths(home: String = Paths.home) -> [String] {
        var out: [String] = []
        for root in ["/Applications", home + "/Applications"] {
            for p in Paths.children(root) {
                if Paths.ext(p) == "app" { out.append(p) }
                else if Paths.isDirectory(p) && !Paths.isSymlink(p) { out += Paths.children(p).filter { Paths.ext($0) == "app" } }
            }
        }
        return out
    }

    public static func app(_ path: String) -> AppInfo? {
        guard let plist = Plist.read(path + "/Contents/Info.plist") else { return nil }
        let exe = (plist["CFBundleExecutable"] as? String).map { path + "/Contents/MacOS/" + $0 }
        return AppInfo(path: path, name: (plist["CFBundleName"] as? String) ?? (Paths.name(path) as NSString).deletingPathExtension,
                       bundleID: (plist["CFBundleIdentifier"] as? String) ?? "?",
                       version: (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String) ?? "?",
                       archs: exe.map(machOArchs) ?? [], lastUsed: lastUsed(path), appStore: Paths.exists(path + "/Contents/_MASReceipt"))
    }

    public static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// CPU architectures in a Mach-O executable (thin or universal).
    public static func machOArchs(_ path: String) -> [String] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let data = h.readData(ofLength: 4096)
        guard data.count >= 8 else { return [] }
        func be(_ o: Int) -> UInt32 { data[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func le(_ o: Int) -> UInt32 { data[o..<o + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        let names: [UInt32: String] = [0x0100000c: "arm64", 0x01000007: "x86_64", 0x0000000c: "arm", 0x00000007: "i386"]
        switch be(0) {
        case 0xcafebabe, 0xcafebabf:
            let size = be(0) == 0xcafebabe ? 20 : 32
            let n = Int(be(4))
            return (0..<min(n, 8)).compactMap { i in
                let o = 8 + i * size
                return o + 4 <= data.count ? names[be(o)] : nil
            }
        default:
            let magic = le(0)
            return magic == 0xfeedfacf || magic == 0xfeedface ? [names[le(4)] ?? "unknown"] : []
        }
    }

    // MARK: Homebrew

    /// `brew info --json=v2 --installed`
    public static func parseBrew(_ text: String) -> [BrewPackage] {
        guard let v = try? JSON.decode(JSONValue.self, from: text) else { return [] }
        let formulae = (v["formulae"]?.array ?? []).map { f -> BrewPackage in
            let inst = f["installed"]?.array?.last
            return BrewPackage(name: f["name"]?.string ?? "?", cask: false, installed: inst?["version"]?.string ?? "?",
                               latest: f["versions"]?["stable"]?.string ?? "?", outdated: f["outdated"]?.bool ?? false,
                               pinned: f["pinned"]?.bool ?? false, deprecated: f["deprecated"]?.bool ?? false,
                               disabled: f["disabled"]?.bool ?? false, onRequest: inst?["installed_on_request"]?.bool ?? false,
                               autoUpdates: false, apps: [],
                               dependencies: (inst?["runtime_dependencies"]?.array ?? []).compactMap { $0["full_name"]?.string })
        }
        let casks = (v["casks"]?.array ?? []).map { c -> BrewPackage in
            let apps = (c["artifacts"]?.array ?? []).flatMap { $0["app"]?.array?.compactMap(\.string) ?? [] }
            return BrewPackage(name: c["token"]?.string ?? "?", cask: true, installed: c["installed"]?.string ?? "?",
                               latest: c["version"]?.string ?? "?", outdated: c["outdated"]?.bool ?? false, pinned: false,
                               deprecated: c["deprecated"]?.bool ?? false, disabled: c["disabled"]?.bool ?? false, onRequest: true,
                               autoUpdates: c["auto_updates"]?.bool ?? false, apps: apps, dependencies: [])
        }
        return formulae + casks
    }

    /// Installed formulae that depend on each formula (computed locally from the same JSON).
    public static func dependents(_ pkgs: [BrewPackage]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for p in pkgs where !p.cask {
            for d in p.dependencies { out[d.split(separator: "/").last.map(String.init) ?? d, default: []].append(p.name) }
        }
        return out
    }

    /// Runtime formulae and the tool/version they provide ("python@3.12" -> python 3.12, "node" -> node <installed>).
    public static func runtimeTool(_ formula: String) -> String? {
        let base = formula.split(separator: "@").first.map(String.init) ?? formula
        return ["python": "python", "node": "node", "ruby": "ruby", "go": "go", "openjdk": "java", "rust": "rust"][base]
    }

    // MARK: npm / pipx

    public static func parseNpmGlobal(_ text: String) -> [String: String] {
        guard let v = try? JSON.decode(JSONValue.self, from: text), let deps = v["dependencies"]?.object else { return [:] }
        var out: [String: String] = [:]
        for (name, d) in deps where d["resolved"]?.string?.hasPrefix("file:") != true {  // linked local packages aren't from the registry
            if let ver = d["version"]?.string { out[name] = ver }
        }
        return out
    }

    public static func parsePipx(_ text: String) -> [String: String] {
        guard let v = try? JSON.decode(JSONValue.self, from: text), let venvs = v["venvs"]?.object else { return [:] }
        var out: [String: String] = [:]
        for (name, venv) in venvs {
            if let ver = venv["metadata"]?["main_package"]?["package_version"]?.string { out[name] = ver }
        }
        return out
    }

    // MARK: runtimes on PATH

    public static func source(of path: String, home: String = Paths.home) -> String {
        if path.hasPrefix("/usr/bin/") { return "macOS / Command Line Tools" }
        if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/Cellar") || path.hasPrefix("/usr/local/opt") { return "Homebrew" }
        if path.hasPrefix("/Library/Frameworks/Python.framework") { return "python.org installer" }
        for (dir, name) in [(".pyenv", "pyenv"), (".nvm", "nvm"), (".rbenv", "rbenv"), (".asdf", "asdf"), ("mise", "mise"),
                            (".local/share/uv", "uv"), (".local/bin", "~/.local/bin (uv, pipx...)"), (".volta", "Volta"),
                            ("fnm", "fnm"), (".cargo", "cargo")] where path.contains(dir) {
            return name
        }
        return Paths.short(Paths.parent(path))
    }

    static let versionArgs: [String: [String]] = ["python3": ["--version"], "node": ["--version"], "ruby": ["--version"],
                                                   "go": ["version"], "java": ["-version"]]

    /// Every distinct install of each runtime on PATH, in PATH order (the first one is what runs).
    public static func runtimes() async -> [RuntimeInstall] {
        var out: [RuntimeInstall] = []
        for tool in ["python3", "node", "ruby", "go", "java"] {
            let which = await Command.run(["/usr/bin/which", "-a", tool])
            var seen: Set<String> = []
            for path in which.lines {
                let real = Paths.resolve(path)
                guard seen.insert(real).inserted else { continue }
                let v = await Command.run([path] + versionArgs[tool]!, timeout: 10)
                let text = v.stdout + v.stderr
                guard v.ok || !text.isEmpty, let version = Re.first("([0-9]+\\.[0-9]+(\\.[0-9]+)?)", text)?[1] else { continue }
                // /usr/bin/python3 and java are stubs that may only offer to install the CLT/JDK.
                if text.contains("xcode-select") || text.contains("Unable to locate a Java Runtime") { continue }
                out.append(RuntimeInstall(tool: tool == "python3" ? "python" : tool, path: path, version: version, source: source(of: real)))
            }
        }
        return out
    }
}
