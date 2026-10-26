import BibiCore
import Darwin
import Foundation

/// Parsers for the commands sys.health runs. Pure functions over text so they can be tested with fixtures.
public enum HealthParse {
    public struct TopProcess: Sendable, Equatable {
        public var pid: Int
        public var command: String
        public var cpu: Double
        public var mem: Int
        public var user: String
    }

    public struct TopSummary: Sendable {
        public var load: [Double] = []
        public var cpuUser = 0.0, cpuSys = 0.0, cpuIdle = 0.0
        public var memUsed = 0, memWired = 0, memCompressor = 0, memUnused = 0
        public var swapins = 0, swapouts = 0
        public var processes: [TopProcess] = []
    }

    /// "536M-", "1150M", "2G+", "512K", "15G" -> bytes.
    public static func size(_ s: String) -> Int {
        guard let m = Re.first("^([0-9.]+)([BKMGT]?)", s.trimmingCharacters(in: .whitespaces)), let n = Double(m[1]) else { return 0 }
        let exp = ["": 0, "B": 0, "K": 1, "M": 2, "G": 3, "T": 4][m[2]] ?? 0
        return Int(n * pow(1024, Double(exp)))
    }

    /// `top -l N -stats pid,command,cpu,mem,user`: uses the last sample (the first one has no CPU deltas).
    public static func top(_ text: String) -> TopSummary {
        let samples = text.components(separatedBy: "Processes:")
        let last = samples.count > 1 ? samples.last! : text
        var t = TopSummary()
        if let m = Re.first("Load Avg: ([0-9.]+), ([0-9.]+), ([0-9.]+)", last) { t.load = [m[1], m[2], m[3]].compactMap(Double.init) }
        if let m = Re.first("CPU usage: ([0-9.]+)% user, ([0-9.]+)% sys, ([0-9.]+)% idle", last) {
            t.cpuUser = Double(m[1]) ?? 0; t.cpuSys = Double(m[2]) ?? 0; t.cpuIdle = Double(m[3]) ?? 0
        }
        if let m = Re.first("PhysMem: (\\S+) used \\((\\S+) wired, (\\S+) compressor\\), (\\S+) unused", last) {
            t.memUsed = size(m[1]); t.memWired = size(m[2]); t.memCompressor = size(m[3]); t.memUnused = size(m[4])
        }
        if let m = Re.first("([0-9]+)\\([0-9]+\\) swapins, ([0-9]+)\\([0-9]+\\) swapouts", last) {
            t.swapins = Int(m[1]) ?? 0; t.swapouts = Int(m[2]) ?? 0
        }
        let lines = last.components(separatedBy: "\n")
        guard let h = lines.firstIndex(where: { $0.hasPrefix("PID") }) else { return t }
        // Columns: PID COMMAND %CPU MEM USER. COMMAND may contain spaces, so read PID from the left and the rest from the right.
        for line in lines[(h + 1)...] {
            let tokens = Re.all("\\S+", line).map { $0[0] }
            guard tokens.count >= 5, let pid = Int(tokens[0]), let cpu = Double(tokens[tokens.count - 3]) else { continue }
            let user = tokens[tokens.count - 1], mem = tokens[tokens.count - 2]
            let command = tokens[1..<(tokens.count - 3)].joined(separator: " ")
            t.processes.append(TopProcess(pid: pid, command: command, cpu: cpu, mem: size(mem), user: user))
        }
        return t
    }

    /// `sysctl -n vm.swapusage` -> (total, used) bytes.
    public static func swap(_ text: String) -> (total: Int, used: Int) {
        let total = Re.first("total = ([0-9.]+[KMGT]?)", text).map { size($0[1]) } ?? 0
        let used = Re.first("used = ([0-9.]+[KMGT]?)", text).map { size($0[1]) } ?? 0
        return (total, used)
    }

    /// `iostat -d -w 1 -c N`: per-disk (KB/t, tps, MB/s) from the last sample.
    public static func iostat(_ text: String) -> [String: (kbt: Double, tps: Double, mbs: Double)] {
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count >= 3 else { return [:] }
        let disks = lines[0].split(separator: " ").map(String.init)
        let values = lines.last!.split(separator: " ").compactMap { Double($0) }
        var out: [String: (Double, Double, Double)] = [:]
        for (i, d) in disks.enumerated() where values.count >= (i + 1) * 3 {
            out[d] = (values[i * 3], values[i * 3 + 1], values[i * 3 + 2])
        }
        return out
    }

    public struct Battery: Sendable {
        public var percent: Int?
        public var onAC = false
        public var cycles: Int?
        public var condition: String?
        public var maxCapacity: Int?
    }

    /// `pmset -g batt` + `system_profiler SPPowerDataType -json`. nil when there is no battery.
    public static func battery(pmset: String, profiler: String) -> Battery? {
        guard pmset.contains("InternalBattery") else { return nil }
        var b = Battery()
        b.percent = Re.first("([0-9]+)%;", pmset).flatMap { Int($0[1]) }
        b.onAC = pmset.contains("'AC Power'")
        if let v = try? JSON.decode(JSONValue.self, from: profiler), let items = v["SPPowerDataType"]?.array {
            for item in items {
                guard let info = item["sppower_battery_health_info"] else { continue }
                b.cycles = info["sppower_battery_cycle_count"]?.int
                b.condition = info["sppower_battery_health"]?.string
                b.maxCapacity = info["sppower_battery_health_maximum_capacity"]?.string.flatMap { Int($0.filter(\.isNumber)) }
            }
        }
        return b
    }

    /// `pmset -g therm`: CPU speed limit (100 = not throttled) and any recorded warnings.
    public static func thermal(_ text: String) -> (speedLimit: Int?, warnings: [String]) {
        let limit = Re.first("CPU_Speed_Limit\\s*=\\s*([0-9]+)", text).flatMap { Int($0[1]) }
        let warnings = text.split(separator: "\n").map(String.init).filter {
            ($0.contains("warning level") || $0.contains("power status")) && !$0.contains("No ")
        }
        return (limit, warnings)
    }

    public struct Crash: Sendable {
        public var process: String
        public var kind: String  // crash, hang, jetsam, other
        public var path: String
        public var date: Date
    }

    /// Diagnostic report files newer than `since`. The process name comes from the file name ("Foo-2026-10-25-101112.ips").
    public static func crashes(in dirs: [String], since: Date) -> [Crash] {
        var out: [Crash] = []
        for dir in dirs {
            for path in Paths.children(dir) {
                let name = Paths.name(path)
                guard ["ips", "crash", "spin", "hang", "diag"].contains(Paths.ext(path)), let m = Paths.mtime(path), m >= since else { continue }
                if name.hasPrefix("Analytics") || name.hasPrefix("swiftpm-testing-helper") { continue }
                let process = Re.first("^(.+?)[-_][0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}", name)?[1] ?? (name as NSString).deletingPathExtension
                var kind = "crash"
                if name.hasPrefix("JetsamEvent") { kind = "jetsam" }
                else if ["spin", "hang"].contains(Paths.ext(path)) { kind = "hang" }
                else if Paths.ext(path) == "diag" { kind = "other" }
                else if Paths.ext(path) == "ips", let first = firstLine(path),
                        let bug = (try? JSON.decode(JSONValue.self, from: first))?["bug_type"]?.string {
                    kind = ["309", "109"].contains(bug) ? "crash" : ["298", "288", "409"].contains(bug) ? "hang" : "other"
                }
                out.append(Crash(process: process, kind: kind, path: path, date: m))
            }
        }
        return out
    }

    static func firstLine(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let data = h.readData(ofLength: 4096)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init)
    }

    /// `log show --style ndjson`: count of entries per process.
    public static func logCounts(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("{") {
            guard let v = try? JSON.decode(JSONValue.self, from: String(line)) else { continue }
            let process = v["processImagePath"]?.string.map(Paths.name) ?? v["process"]?.string ?? "?"
            counts[process, default: 0] += 1
        }
        return counts
    }
}

/// Per-process disk I/O from the kernel's resource accounting (own processes only, no admin rights needed).
public enum DiskIO {
    public struct Rate: Sendable {
        public var pid: Int32
        public var name: String
        public var readPerSec: Double
        public var writtenPerSec: Double
    }

    static func snapshot() -> [Int32: (String, UInt64, UInt64)] {
        var pids = [Int32](repeating: 0, count: 8192)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard n > 0 else { return [:] }
        var out: [Int32: (String, UInt64, UInt64)] = [:]
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var info = rusage_info_v2()
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard rc == 0 else { continue }
            var name = [CChar](repeating: 0, count: 256)
            proc_name(pid, &name, UInt32(name.count))
            out[pid] = (String(cString: name), info.ri_diskio_bytesread, info.ri_diskio_byteswritten)
        }
        return out
    }

    /// Samples twice and returns the busiest processes.
    public static func busiest(interval: Double = 2, top: Int = 5) async -> [Rate] {
        let a = snapshot()
        try? await Task.sleep(for: .seconds(interval))
        let b = snapshot()
        return b.compactMap { pid, v -> Rate? in
            guard let old = a[pid], v.1 >= old.1, v.2 >= old.2 else { return nil }
            return Rate(pid: pid, name: v.0, readPerSec: Double(v.1 - old.1) / interval, writtenPerSec: Double(v.2 - old.2) / interval)
        }.sorted { $0.readPerSec + $0.writtenPerSec > $1.readPerSec + $1.writtenPerSec }.prefix(top).map { $0 }
    }
}

/// Sends SIGTERM to one of the user's own processes, after checking the pid still belongs to the same program.
public struct QuitProcess: ActionSpec {
    public let id = "quit_process"
    public let summary = "Ask one of your processes to quit (SIGTERM)"
    static let neverQuit: Set<String> = ["launchd", "kernel_task", "WindowServer", "loginwindow", "Finder", "Dock", "SystemUIServer",
                                         "ControlCenter", "bibi", "mds", "mds_stores", "coreaudiod", "cfprefsd", "distnoted"]

    static func name(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    static func owner(of pid: Int32) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info.pbi_uid : nil
    }

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        guard let pid = Int32(try require(p, "pid")), pid > 1 else { throw ActionError("bad pid") }
        let expected = try require(p, "name")
        guard let actual = Self.name(of: pid) else { throw ActionError("process \(pid) is no longer running") }
        // top truncates names to 16 characters; proc_name gives up to 32.
        guard actual.hasPrefix(expected) || expected.hasPrefix(actual) else {
            throw ActionError("pid \(pid) is now \(actual), not \(expected)")
        }
        guard Self.owner(of: pid) == getuid() else { throw ActionError("\(actual) belongs to another user or the system") }
        guard !Self.neverQuit.contains(actual) else { throw ActionError("bibi won't quit \(actual)") }
    }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        ["kill -TERM \(p["pid"]!)   (\(p["name"]!) can save and exit; unsaved work in it may be lost)"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        guard kill(Int32(p["pid"]!)!, SIGTERM) == 0 else { throw ActionError("kill failed: \(String(cString: strerror(errno)))") }
        return Outcome("asked \(p["name"]!) (pid \(p["pid"]!)) to quit")
    }
}
