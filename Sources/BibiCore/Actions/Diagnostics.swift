import Foundation

/// Read-only commands that help confirm a finding. The model may suggest them by id; they never change anything.
public struct Diagnostic: Sendable, Codable {
    public var id: String
    public var title: String
    /// argv with placeholders: {pid}, {process}, {path}, {label}, {uid}
    public var argv: [String]
    public var admin: Bool
    public var categories: [String]
    public var timeout: Double

    /// The concrete argv for a finding's subject, or nil if a placeholder can't be filled safely.
    public func command(subject: [String: String]) -> [String]? {
        var subject = subject
        subject["uid"] = String(getuid())
        var out: [String] = []
        for arg in argv {
            var a = arg
            for (key, pattern) in Diagnostics.placeholders where a.contains("{\(key)}") {
                guard let v = subject[key], v.range(of: pattern, options: .regularExpression) != nil else { return nil }
                if key == "path" && !Paths.exists(v) { return nil }
                a = a.replacingOccurrences(of: "{\(key)}", with: v)
            }
            out.append(a)
        }
        return out
    }

    /// For display when a placeholder can't be filled: the template itself.
    public var template: String { Shell.join(argv) }
}

public enum Diagnostics {
    static let placeholders: [String: String] = [
        "pid": "^[0-9]{1,7}$",
        "process": "^[A-Za-z0-9 ._()+-]{1,64}$",
        "path": "^/[^\\x00]{1,1024}$",
        "label": "^[A-Za-z0-9._-]{1,128}$",
        "uid": "^[0-9]{1,7}$",
    ]

    public static let all: [Diagnostic] = [
        .init(id: "top_cpu", title: "Top processes by CPU (2 samples)", argv: ["top", "-l", "2", "-n", "15", "-o", "cpu", "-stats", "pid,command,cpu,mem,state"], admin: false, categories: ["cpu", "thermal"], timeout: 15),
        .init(id: "top_mem", title: "Top processes by memory", argv: ["top", "-l", "1", "-n", "15", "-o", "mem", "-stats", "pid,command,mem,cpu"], admin: false, categories: ["memory"], timeout: 15),
        .init(id: "sample_process", title: "Sample what a process is doing for 3 seconds", argv: ["sample", "{pid}", "3"], admin: false, categories: ["cpu", "hang"], timeout: 20),
        .init(id: "vm_stat", title: "Memory paging statistics over 5 seconds", argv: ["vm_stat", "-c", "5", "1"], admin: false, categories: ["memory"], timeout: 15),
        .init(id: "memory_pressure", title: "Current memory pressure level", argv: ["memory_pressure", "-Q"], admin: false, categories: ["memory"], timeout: 10),
        .init(id: "iostat", title: "Disk throughput over 5 seconds", argv: ["iostat", "-d", "-w", "1", "-c", "5"], admin: false, categories: ["disk-io"], timeout: 15),
        .init(id: "fs_usage_process", title: "File system calls by a process for 5 seconds", argv: ["fs_usage", "-w", "-f", "filesys", "-t", "5", "{pid}"], admin: true, categories: ["disk-io"], timeout: 20),
        .init(id: "spindump", title: "System-wide hang report (spindump, 5 seconds)", argv: ["spindump", "-notarget", "5", "-stdout"], admin: true, categories: ["hang", "cpu"], timeout: 60),
        .init(id: "powermetrics", title: "CPU power and thermal sample", argv: ["powermetrics", "-n", "1", "-i", "2000", "--samplers", "cpu_power,thermal"], admin: true, categories: ["thermal", "cpu", "battery"], timeout: 20),
        .init(id: "pmset_therm", title: "Thermal and performance warnings", argv: ["pmset", "-g", "therm"], admin: false, categories: ["thermal"], timeout: 10),
        .init(id: "battery_info", title: "Battery condition, capacity and cycle count", argv: ["system_profiler", "SPPowerDataType"], admin: false, categories: ["battery"], timeout: 30),
        .init(id: "log_process", title: "Last 10 minutes of log messages from a process", argv: ["log", "show", "--last", "10m", "--style", "compact", "--process", "{process}"], admin: false, categories: ["crash", "log"], timeout: 60),
        .init(id: "log_process_faults", title: "Faults a process logged in the last 15 minutes", argv: ["log", "show", "--last", "15m", "--style", "compact", "--predicate", "process == \"{process}\" AND messageType == fault"], admin: false, categories: ["log"], timeout: 60),
        .init(id: "log_faults", title: "Faults logged in the last 15 minutes", argv: ["log", "show", "--last", "15m", "--style", "compact", "--predicate", "messageType == fault"], admin: false, categories: ["log", "crash"], timeout: 60),
        .init(id: "crash_reports", title: "Recent crash reports", argv: ["ls", "-lt", NSHomeDirectory() + "/Library/Logs/DiagnosticReports"], admin: false, categories: ["crash"], timeout: 10),
        .init(id: "lsof_listen", title: "Processes listening on TCP ports", argv: ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"], admin: false, categories: ["network", "listener"], timeout: 20),
        .init(id: "lsof_listen_all", title: "All listening TCP ports, including other users' processes", argv: ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"], admin: true, categories: ["listener"], timeout: 20),
        .init(id: "lsof_process", title: "Files and sockets a process has open", argv: ["lsof", "-nP", "-p", "{pid}"], admin: false, categories: ["listener", "disk-io"], timeout: 20),
        .init(id: "codesign_info", title: "Code signature of a program", argv: ["codesign", "-dv", "--verbose=2", "{path}"], admin: false, categories: ["persistence", "listener", "app"], timeout: 15),
        .init(id: "spctl_assess", title: "Gatekeeper assessment of a program", argv: ["spctl", "--assess", "-vv", "{path}"], admin: false, categories: ["persistence", "app"], timeout: 15),
        .init(id: "launchctl_user", title: "launchd state of a login agent", argv: ["launchctl", "print", "gui/{uid}/{label}"], admin: false, categories: ["login-items", "persistence"], timeout: 10),
        .init(id: "launchctl_system", title: "launchd state of a system daemon", argv: ["launchctl", "print", "system/{label}"], admin: false, categories: ["login-items", "persistence", "sharing"], timeout: 10),
        .init(id: "plist_show", title: "Contents of a launchd plist", argv: ["plutil", "-p", "{path}"], admin: false, categories: ["login-items", "persistence"], timeout: 10),
        .init(id: "firewall_apps", title: "Applications allowed through the firewall", argv: ["/usr/libexec/ApplicationFirewall/socketfilterfw", "--listapps"], admin: false, categories: ["firewall"], timeout: 10),
        .init(id: "docker_df", title: "Docker disk usage in detail", argv: ["docker", "system", "df", "-v"], admin: false, categories: ["docker"], timeout: 60),
        .init(id: "brew_doctor", title: "Homebrew self-check", argv: ["brew", "doctor"], admin: false, categories: ["homebrew", "software"], timeout: 120),
        .init(id: "brew_deps", title: "Installed formulae that depend on a formula", argv: ["brew", "uses", "--installed", "{label}"], admin: false, categories: ["homebrew", "software"], timeout: 60),
        .init(id: "git_status", title: "Git status of a project", argv: ["git", "-C", "{path}", "status", "--short", "--branch"], admin: false, categories: ["git", "project"], timeout: 15),
        .init(id: "du_path", title: "Size of a folder", argv: ["du", "-sh", "{path}"], admin: false, categories: ["project", "storage"], timeout: 120),
    ]

    public static func get(_ id: String) -> Diagnostic? { all.first { $0.id == id } }
}
