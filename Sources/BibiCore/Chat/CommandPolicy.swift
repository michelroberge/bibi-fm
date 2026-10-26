import Foundation

/// What a proposed command can do, decided by bibi's rules (never by the model).
public enum CommandClass: String, Codable, Sendable {
    case readOnly = "read-only"
    case network
    case writes
    case admin
}

/// The verdict on a model-written argv: run it as is (with a class), replace it with registry actions, or refuse.
public struct CommandVerdict: Sendable {
    public var argv: [String]
    public var cls: CommandClass
    /// Registry calls to use instead (e.g. rm becomes trash_path, which can be undone).
    public var rewrite: [ActionCall]
    public var refusal: String?

    public var allowed: Bool { refusal == nil }
}

/// Classifies commands proposed in chat. The model may write argv there, so these rules decide what is shown
/// and how risky it is: no shells, no pipes or redirections, sudo only as an explicit admin step,
/// deletions go to the Trash, and destructive file commands may not touch protected paths.
public enum CommandPolicy {
    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh", "eval", "exec", "xargs"]
    /// Interpreters may only report their version: anything else would run code bibi can't show.
    static let interpreters: Set<String> = ["python", "python3", "perl", "ruby", "node", "swift", "php", "lua", "java"]
    static let operators: Set<String> = ["|", "||", "&&", ";", "&", ">", ">>", "<", "<<", "2>", "2>&1", "&>"]
    /// File commands whose path arguments must not be protected.
    static let destructive: Set<String> = ["rmdir", "mv", "cp", "chmod", "chown", "chflags", "ln", "touch", "truncate", "dd",
                                           "unlink", "srm", "xattr", "ditto", "rsync", "tee", "install", "mkdir", "tar", "unzip"]
    static let networkTools: Set<String> = ["curl", "wget", "ping", "dig", "nslookup", "host", "traceroute", "nc", "ssh", "scp",
                                            "whois", "mtr", "networkQuality", "speedtest"]

    /// Programs that never change anything, whatever their arguments (interactive or follow modes excluded below).
    static let readOnly: Set<String> = [
        "ls", "du", "df", "ps", "sw_vers", "uname", "uptime", "whoami", "id", "hostname", "date", "cal", "which", "whereis",
        "file", "stat", "wc", "head", "cat", "grep", "egrep", "fgrep", "mdfind", "mdls", "system_profiler", "vm_stat",
        "iostat", "netstat", "lsof", "pgrep", "last", "who", "w", "ioreg", "kextstat", "echo", "printenv", "tree", "shasum",
        "md5", "otool", "pwd", "groups", "arch", "nproc", "getconf", "memory_pressure", "nettop", "sort", "uniq", "cut",
        "tail", "find", "top", "log", "sysctl", "pmset", "diskutil", "launchctl", "defaults", "networksetup", "scutil",
        "csrutil", "fdesetup", "spctl", "softwareupdate", "brew", "npm", "pip", "pip3", "pipx", "git", "docker", "codesign",
        "pkgutil", "dscl", "plutil", "xcode-select", "xcrun", "ifconfig", "route", "arp", "tmutil", "socketfilterfw",
        "profiles", "systemextensionsctl", "kmutil", "security", "nvram", "mount", "smartctl", "powermetrics", "sample",
        "fs_usage", "lsappinfo", "ipconfig",
    ]

    /// For tools that both read and write, the subcommands or flags that only read.
    static let readSubcommands: [String: @Sendable ([String]) -> Bool] = [
        "find": { args in !args.contains { ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fls"].contains($0) } },
        "tail": { args in !args.contains { $0 == "-f" || $0 == "-F" } },
        "top": { args in args.contains("-l") },
        "log": { args in ["show", "stats", "help"].contains(args.first ?? "") },
        "sysctl": { args in !args.contains("-w") && !args.contains { $0.contains("=") } },
        "pmset": { args in args.first == "-g" },
        "diskutil": { args in ["list", "info", "apfs", "activity", "listFilesystems"].contains(args.first ?? "")
            && (args.first != "apfs" || ["list", "listSnapshots", "listVolumeGroups"].contains(args.dropFirst().first ?? "")) },
        "launchctl": { args in ["list", "print", "print-disabled", "print-cache", "blame", "dumpstate", "procinfo", "managerpid",
                                "version", "help"].contains(args.first ?? "") },
        "defaults": { args in ["read", "read-type", "domains", "find", "help"].contains(args.first ?? "") },
        "networksetup": { args in args.first.map { $0.hasPrefix("-get") || $0.hasPrefix("-list") || $0 == "-printcommands" } ?? false },
        "scutil": { args in ["--get", "--dns", "--proxy", "-r", "--nwi", "--nc"].contains(args.first ?? "")
            && (args.first != "--nc" || ["list", "status", "show"].contains(args.dropFirst().first ?? "")) },
        "csrutil": { args in args.first == "status" },
        "fdesetup": { args in ["status", "list", "isactive", "haspersonalrecoverykey"].contains(args.first ?? "") },
        "spctl": { args in args.contains("--status") || args.contains("-a") || args.contains("--assess") },
        "softwareupdate": { args in args.contains("-l") || args.contains("--list") || args.contains("--history") },
        "brew": { args in ["list", "ls", "info", "outdated", "leaves", "config", "doctor", "deps", "uses", "search", "--version",
                           "--prefix", "--cache", "desc", "home", "services"].contains(args.first ?? "")
            && (args.first != "services" || ["list", "info"].contains(args.dropFirst().first ?? "")) },
        "npm": { args in ["ls", "list", "outdated", "view", "info", "root", "prefix", "--version", "-v", "doctor", "explain", "why"]
            .contains(args.first ?? "") || (args.first == "config" && args.dropFirst().first == "get") },
        "pip": { args in ["list", "show", "freeze", "check", "--version", "debug"].contains(args.first ?? "") },
        "pip3": { args in ["list", "show", "freeze", "check", "--version", "debug"].contains(args.first ?? "") },
        "pipx": { args in ["list", "environment", "--version"].contains(args.first ?? "") },
        "git": { args in ["status", "log", "diff", "show", "branch", "remote", "rev-parse", "describe", "shortlog", "blame",
                          "ls-files", "worktree", "stash", "tag", "config", "--version"].contains(args.first ?? "")
            && !(args.first == "config" && !args.contains("--get") && !args.contains("--list") && !args.contains("-l"))
            && !(["branch", "tag", "stash", "worktree", "remote"].contains(args.first ?? "")
                 && args.dropFirst().contains { ["-d", "-D", "-m", "-M", "add", "remove", "rm", "prune", "drop", "pop", "clear",
                                                 "apply", "push", "rename", "set-url", "move", "lock", "unlock"].contains($0) }) },
        "docker": { args in ["ps", "images", "info", "version", "inspect", "logs", "stats", "top", "port", "history", "search"]
            .contains(args.first ?? "") || (args.first == "system" && args.dropFirst().first == "df")
            || (["image", "container", "volume", "network", "context", "builder"].contains(args.first ?? "")
                && ["ls", "inspect", "list", "du"].contains(args.dropFirst().first ?? "")) },
        "codesign": { args in args.contains("-d") || args.contains("--display") || args.contains("-v") || args.contains("--verify") },
        "pkgutil": { args in args.first.map { ["--pkgs", "--pkg-info", "--files", "--file-info", "--pkg-info-plist", "--export-plist",
                                                "--check-signature", "--payload-files", "--regexp"].contains($0) } ?? false },
        "dscl": { args in args.dropFirst().first.map { ["-list", "-read", "-search", "-readall", "-ls", "-cat"].contains($0) } ?? false },
        "plutil": { args in args.contains("-p") || args.contains("-lint") || args.contains("-help") || args.contains("-type") },
        "xcode-select": { args in args.contains("-p") || args.contains("--print-path") || args.contains("-v") || args.contains("--version") },
        "xcrun": { args in args.contains("--find") || args.contains("--show-sdk-path") || args.contains("--show-sdk-version")
            || (args.first == "simctl" && ["list", "help", "getenv"].contains(args.dropFirst().first ?? "")) },
        "ifconfig": { args in args.count <= 1 || args == ["-a"] || args == ["-l"] },
        "route": { args in ["get", "-n"].contains(args.first ?? "") && !args.contains("add") && !args.contains("delete") },
        "arp": { args in args.contains("-a") || args.contains("-n") },
        "tmutil": { args in ["listbackups", "latestbackup", "destinationinfo", "status", "listlocalsnapshots",
                             "listlocalsnapshotdates", "machinedirectory", "version", "isexcluded"].contains(args.first ?? "") },
        "socketfilterfw": { args in args.allSatisfy { $0.hasPrefix("--get") || $0 == "--listapps" } && !args.isEmpty },
        "profiles": { args in ["list", "show", "status", "-P", "-L"].contains(args.first ?? "") },
        "systemextensionsctl": { args in args.first == "list" },
        "kmutil": { args in ["showloaded", "inspect"].contains(args.first ?? "") },
        "security": { args in ["list-keychains", "default-keychain", "find-certificate", "show-keychain-info",
                               "dump-trust-settings", "find-identity", "authorizationdb"].contains(args.first ?? "")
            && !(args.first == "authorizationdb" && args.dropFirst().first != "read") },
        "nvram": { args in args.isEmpty || args.allSatisfy { !$0.contains("=") && $0 != "-d" && $0 != "-c" } },
        "mount": { args in args.isEmpty },
        "ipconfig": { args in ["getifaddr", "getpacket", "getoption", "getsummary", "ifcount", "getiflist", "getv6packet"].contains(args.first ?? "") },
        "lsappinfo": { args in ["list", "info", "front", "find", "visibleProcessList", "processList"].contains(args.first ?? "") },
    ]

    /// Commands that need root to be useful even for reading; proposing them without sudo just fails.
    static let rootOnly: Set<String> = ["powermetrics", "fs_usage", "dtrace", "opensnoop", "smartctl"]

    /// Expands a leading ~ (argv isn't run by a shell, so nothing else would).
    public static func expand(_ arg: String, home: String = Paths.home) -> String {
        if arg == "~" { return home }
        if arg.hasPrefix("~/") { return home + arg.dropFirst(1) }
        return arg
    }

    public static func classify(_ argv: [String], policy: SafetyPolicy = SafetyPolicy(),
                                exists: (String) -> Bool = { Command.which($0) != nil }) -> CommandVerdict {
        var argv = argv.map { expand($0.trimmingCharacters(in: .whitespaces), home: policy.home) }.filter { !$0.isEmpty }
        var verdict = CommandVerdict(argv: argv, cls: .writes, rewrite: [], refusal: nil)
        func refuse(_ why: String) -> CommandVerdict { verdict.refusal = why; return verdict }

        var admin = false
        if argv.first == "sudo" {
            admin = true
            argv.removeFirst()
            while let f = argv.first, f.hasPrefix("-") { argv.removeFirst() }  // sudo's own options
            verdict.argv = argv
        }
        guard let exe = argv.first else { return refuse("empty command") }
        let name = Paths.name(exe)
        let args = Array(argv.dropFirst())

        if argv.count == 1, exe.contains(" ") {
            return refuse("the command was written as one string; give the program and each argument separately")
        }
        if shells.contains(name) || name == "sudo" || name == "su" || name == "doas" {
            return refuse("\(name) would run a script or another shell; propose the actual command instead")
        }
        if interpreters.contains(name) {
            guard args.count == 1, ["--version", "-V", "-v", "-version"].contains(args[0]) else {
                return refuse("\(name) would run code bibi can't show you; propose the command it should run instead")
            }
            verdict.cls = .readOnly
            return exists(exe) ? verdict : refuse("\(exe) is not installed on this Mac")
        }
        if let op = args.first(where: { operators.contains($0) }) {
            return refuse("'\(op)' needs a shell; bibi runs one program with its arguments (propose separate steps instead)")
        }
        if args.contains(where: { $0.contains("$(") || $0.contains("`") }) {
            return refuse("command substitution needs a shell; bibi runs one program with its arguments")
        }
        if name == "osascript" && args.contains(where: { $0.lowercased().contains("do shell script") }) {
            return refuse("AppleScript 'do shell script' would run a shell; propose the command itself")
        }
        // The BSD mail tools hand messages to a local sendmail that isn't set up on a Mac: they fail or vanish.
        if ["mail", "mailx", "sendmail"].contains(name) {
            return refuse("\(name) can't deliver email on this Mac; use action:mail_send, which sends through your Mail accounts")
        }
        // Raw AppleScript could send mail or delete data with no risk class; app tools are checked against the app.
        if name == "osascript" && args.contains(where: { $0.lowercased().contains("tell app") }) {
            return refuse("AppleScript that controls an app must go through a listed action or app tool, so bibi can check what it does")
        }
        guard exists(exe) else { return refuse("\(exe) is not installed on this Mac") }

        if name == "rm" {
            let paths = args.filter { !$0.hasPrefix("-") }
            guard !paths.isEmpty else { return refuse("rm without a path") }
            guard paths.allSatisfy({ $0.hasPrefix("/") }) else {
                return refuse("rm needs absolute paths (bibi doesn't run in your shell's folder)")
            }
            verdict.rewrite = paths.map { ActionCall("trash_path", ["path": Paths.standardize($0)]) }
            verdict.cls = .writes
            return verdict
        }
        if destructive.contains(name) {
            let paths = args.filter { $0.hasPrefix("/") }.map(Paths.standardize)
            if let p = paths.first(where: policy.isProtected) {
                return refuse("\(Paths.short(p)) is protected; bibi won't change it with \(name)")
            }
        }

        let readsOnly = readOnly.contains(name) && (readSubcommands[name]?(args) ?? true)
        if admin {
            verdict.cls = .admin
        } else if rootOnly.contains(name) {
            return refuse("\(name) only works with administrator rights; propose it with sudo")
        } else if readsOnly {
            verdict.cls = .readOnly
        } else if networkTools.contains(name) && !args.contains(where: { ["-o", "-O", "--output", "-T", "--upload-file", "-d", "--data", "-X"].contains($0) }) {
            verdict.cls = .network
        } else {
            verdict.cls = .writes
        }
        return verdict
    }

    /// The JSON form stored in an ActionCall's params (Params are strings).
    public static func encode(_ argv: [String]) -> String { JSON.string(argv) }
    public static func decode(_ text: String) -> [String]? { try? JSON.decode([String].self, from: text) }
}

/// Runs a command proposed in chat after the user approved it. Two registry entries: run_command (user) and
/// run_command_admin (asks for the password every time). Both re-check the command with CommandPolicy, so a
/// refused or rewritten argv can never run, whatever is stored in a report.
public struct RunCommand: ActionSpec {
    let admin: Bool
    public init(admin: Bool = false) { self.admin = admin }
    public var id: String { admin ? "run_command_admin" : "run_command" }
    public var summary: String { admin ? "Run a command you approved, with administrator rights" : "Run a command you approved" }
    public var privilege: Privilege { admin ? .admin : .user }

    func check(_ p: Params, _ env: ActionEnv) throws -> CommandVerdict {
        guard let argv = CommandPolicy.decode(try require(p, "argv")), !argv.isEmpty else { throw ActionError("\(id): bad argv") }
        let v = CommandPolicy.classify((admin ? ["sudo"] : []) + argv, policy: env.policy)
        if let r = v.refusal { throw ActionError(r) }
        if !v.rewrite.isEmpty { throw ActionError("\(argv[0]) must go through \(v.rewrite[0].spec)") }
        if (v.cls == .admin) != admin { throw ActionError("\(id) can't run a \(v.cls.rawValue) command") }
        return v
    }

    public func validate(_ p: Params, _ env: ActionEnv) throws { _ = try check(p, env) }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        let v = try check(p, env)
        return [(admin ? "sudo " : "") + Shell.join(v.argv) + "   (\(v.cls.rawValue); cannot be undone by bibi)"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let v = try check(p, env)
        let timeout = p["timeout"].flatMap(Double.init) ?? 120
        let text: String
        if admin {
            text = try await env.admin.run(v.argv)
        } else {
            let out = await Command.run(v.argv, timeout: timeout)
            if out.timedOut { throw ActionError("\(v.argv[0]) timed out after \(Int(timeout))s") }
            if !out.ok && out.stdout.isEmpty { try out.check() }
            text = out.stdout + (out.stderr.isEmpty ? "" : "\n" + out.stderr) + (out.ok ? "" : "\n(exit \(out.status))")
        }
        let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome("ran " + Text.oneLine(Shell.join(v.argv), max: 80), output: Text.clip(shown.ifEmpty("(no output)"), max: 20000))
    }

    public static func call(_ argv: [String], admin: Bool) -> ActionCall {
        ActionCall(admin ? "run_command_admin" : "run_command", ["argv": CommandPolicy.encode(argv)])
    }
}

/// Runs a skill from chat. The chat engine handles it (it needs the harness); the registry entry exists so
/// previews, journals and the approval UI treat it like any other action.
public struct RunSkillSpec: ActionSpec {
    public let id = "run_skill"
    public let summary = "Run one of bibi's skills (read-only analysis; its recommendations come back for approval)"
    public init() {}
    public func validate(_ p: Params, _ env: ActionEnv) throws {
        _ = try require(p, "skill")
        guard CommandPolicy.decode(p["argv"] ?? "[]") != nil else { throw ActionError("run_skill: bad argv") }
    }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        ["run bibi \(p["skill"]!) \(Shell.join(CommandPolicy.decode(p["argv"] ?? "[]") ?? []))   (analysis only; changes need another approval)"]
    }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        throw ActionError("skills run through chat")
    }
}
