import BibiCore
import Foundation

/// Parsers and fixed tables for sec.audit. Detection is deterministic; the model only explains.
public enum SecParse {
    public struct Firewall: Sendable {
        public var enabled = false, stealth = false, blockAll = false, allowSigned = false, allowDownloaded = false
    }

    public static func firewall(_ text: String) -> Firewall {
        var f = Firewall()
        f.enabled = Re.test("Firewall is enabled|State = [12]", text)
        f.stealth = text.contains("stealth mode is on")
        f.blockAll = Re.test("block all state set to enabled|Block all INCOMING connections is enabled", text, ci: true)
        f.allowSigned = text.contains("built-in signed software ENABLED")
        f.allowDownloaded = text.contains("downloaded signed software ENABLED")
        return f
    }

    public struct Listener: Sendable, Hashable {
        public var pid: Int32
        public var command: String
        public var user: String
        public var proto: String
        public var address: String
        public var port: Int

        /// Bound to every interface (reachable from the network), not just this Mac.
        public var external: Bool { !["127.0.0.1", "[::1]", "localhost"].contains(address) && !address.hasPrefix("127.") }
        public var key: String { "\(command):\(proto)/\(port)\(external ? "" : " (local only)")" }
    }

    /// `lsof -nP +c 0 -i... -F pcLn` (machine-readable: p=pid, c=command, L=login, n=name, one field per line).
    public static func lsof(_ text: String, proto: String) -> [Listener] {
        var out: Set<Listener> = []
        var pid: Int32 = 0, command = "", user = ""
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value.replacingOccurrences(of: "\\x20", with: " ")
            case "L": user = value
            case "n":
                // "*:7000", "127.0.0.1:5432", "[::1]:6379"; UDP may include "->" for connected sockets
                guard !value.contains("->"), let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                var addr = String(value[..<colon])
                if addr == "*" || addr == "[::]" || addr == "0.0.0.0" { addr = "*" }
                out.insert(Listener(pid: pid, command: command, user: user, proto: proto, address: addr, port: port))
            default: break
            }
        }
        // IPv4 and IPv6 sockets of the same service collapse into one entry per (process, port, scope).
        var seen: Set<String> = []
        return out.sorted { ($0.port, $0.command) < ($1.port, $1.command) }.filter { seen.insert("\($0.pid)/\($0.proto)/\($0.port)/\($0.external)").inserted }
    }

    /// `sysadminctl -screenLock status`: delay in seconds, 0 = immediate, nil = off/unknown.
    public static func screenLock(_ text: String) -> (off: Bool, delay: Int?) {
        if text.contains("screenLock is off") { return (true, nil) }
        if text.contains("immediate") { return (false, 0) }
        return (false, Re.first("delay is ([0-9]+) seconds", text).flatMap { Int($0[1]) })
    }

    /// `defaults read` output: "Key = 1;" -> value.
    public static func defaultsValue(_ text: String, _ key: String) -> String? {
        Re.first("(?m)^\\s*\"?\(key)\"?\\s*=\\s*\"?([^\";]*)\"?;", text)?[1]
    }

    /// `systemextensionsctl list`: third-party extensions that are active.
    public static func systemExtensions(_ text: String) -> [String] {
        text.split(separator: "\n").filter { $0.contains("[activated enabled]") }.map {
            Re.replace("\\s+", String($0), with: " ").trimmingCharacters(in: .whitespaces)
        }
    }

    /// Where malware likes to live, and how it often starts.
    public static func persistenceFlags(_ item: LaunchItem, signature: CodeSignature?) -> [String] {
        var flags: [String] = []
        guard let program = item.program else { return [] }  // an empty or incomplete plist starts nothing
        let suspiciousDirs = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/Users/Shared/"]
        if suspiciousDirs.contains(where: { program.hasPrefix($0) }) { flags.append("runs from a shared or temporary folder") }
        if Paths.parts(program).dropLast().contains(where: { $0.hasPrefix(".") && $0 != "." }) && !program.contains("/.local/") {
            flags.append("runs from a hidden folder")
        }
        let interpreters = ["sh", "bash", "zsh", "python", "python3", "perl", "ruby", "osascript", "node", "curl"]
        if interpreters.contains(Paths.name(program)) && item.arguments.count > 1 {
            flags.append("runs a script through \(Paths.name(program))")
        }
        let homebrew = program.hasPrefix("/opt/homebrew/") || program.hasPrefix("/usr/local/Cellar/") || program.hasPrefix("/usr/local/opt/")
        if let s = signature, !homebrew {
            if !s.signed { flags.append("unsigned program") }
            else if !s.valid { flags.append("invalid signature") }
            else if s.adhoc { flags.append("ad-hoc signature (no developer identity)") }
        }
        return flags
    }
}

/// macOS sharing services bibi can switch off (fixed table; nothing else can be passed).
public enum SharingServices {
    public struct Service: Sendable {
        public var key: String
        public var name: String
        public var label: String
        public var plist: String
    }

    public static let all: [Service] = [
        .init(key: "remote-login", name: "Remote Login (SSH)", label: "com.openssh.sshd", plist: "/System/Library/LaunchDaemons/ssh.plist"),
        .init(key: "screen-sharing", name: "Screen Sharing", label: "com.apple.screensharing", plist: "/System/Library/LaunchDaemons/com.apple.screensharing.plist"),
        .init(key: "file-sharing", name: "File Sharing (SMB)", label: "com.apple.smbd", plist: "/System/Library/LaunchDaemons/com.apple.smbd.plist"),
        .init(key: "remote-apple-events", name: "Remote Apple Events", label: "com.apple.AEServer", plist: "/System/Library/LaunchDaemons/com.apple.AEServer.plist"),
    ]

    public static func get(_ key: String) -> Service? { all.first { $0.key == key } }
}

/// Turns the firewall or stealth mode on (admin). Undo turns it back off.
public struct FirewallSet: ActionSpec {
    public let enable: Bool
    public init(enable: Bool) { self.enable = enable }
    public var id: String { enable ? "firewall_enable" : "firewall_restore" }
    public var summary: String { enable ? "Turn on the macOS firewall or its stealth mode" : "Turn the firewall setting back off" }
    public var privilege: Privilege { .admin }
    public var reversible: Bool { enable }
    public var selectable: Bool { enable }
    static let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
    static let flags = ["global": "--setglobalstate", "stealth": "--setstealthmode"]

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        guard Self.flags[try require(p, "setting")] != nil else { throw ActionError("unknown firewall setting") }
    }

    func argv(_ p: Params) -> [String] { [Self.tool, Self.flags[p["setting"]!]!, enable ? "on" : "off"] }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] { ["sudo " + Shell.join(argv(p))] }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let out = try await env.admin.run(argv(p))
        return Outcome(out.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("firewall \(p["setting"]!) \(enable ? "on" : "off")"),
                       undo: enable ? ActionCall("firewall_restore", p) : nil)
    }
}

/// Stops a sharing service and keeps it from starting again (admin). Undo re-enables it.
public struct SharingSet: ActionSpec {
    public let enable: Bool
    public init(enable: Bool) { self.enable = enable }
    public var id: String { enable ? "sharing_service_restore" : "sharing_service_disable" }
    public var summary: String { enable ? "Turn a sharing service back on" : "Turn off a sharing service (Remote Login, Screen Sharing, File Sharing...)" }
    public var privilege: Privilege { .admin }
    public var reversible: Bool { !enable }
    public var selectable: Bool { !enable }

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        guard SharingServices.get(try require(p, "service")) != nil else { throw ActionError("unknown sharing service") }
    }

    func argv(_ s: SharingServices.Service) -> [String] {
        enable
            ? ["/bin/sh", "-c", "launchctl enable \"system/$1\" && launchctl bootstrap system \"$2\"", "bibi", s.label, s.plist]
            : ["/bin/sh", "-c", "launchctl disable \"system/$1\"; launchctl bootout \"system/$1\" 2>/dev/null; true", "bibi", s.label]
    }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        let s = SharingServices.get(p["service"]!)!
        return enable ? ["sudo launchctl enable system/\(s.label) && sudo launchctl bootstrap system \(s.plist)"]
            : ["sudo launchctl disable system/\(s.label)", "sudo launchctl bootout system/\(s.label)   (\(s.name) stops now and after restarts)"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let s = SharingServices.get(p["service"]!)!
        _ = try await env.admin.run(argv(s))
        return Outcome("\(s.name) \(enable ? "turned back on" : "turned off")", undo: enable ? nil : ActionCall("sharing_service_restore", p))
    }
}
