import BibiCore
import Foundation

/// sys.health: CPU and memory pressure, heavy processes, disk I/O, battery, thermal state, login items,
/// crashes and log fault storms, correlated by fm into likely causes with ways to confirm them.
public struct SysHealth: Skill {
    public init() {}
    public let name = "sys.health"
    public let help = "Check CPU, memory, disk I/O, battery, login items, crashes and system logs, and explain what's wrong"
    public let keywords = "slow sluggish hot fan battery crash crashes freeze freezing lag performance hang beachball health overheating"
    public var params: [Param] {
        [
            .option("log_minutes", "--log-minutes", kind: .int, default: "15", help: "how many minutes of the system log to scan for faults"),
            .option("crash_days", "--crash-days", kind: .int, default: "7", help: "how many days of crash reports to look at"),
            .flag("no_log", "--no-log", help: "skip the system log (faster)"),
        ]
    }
    public var factsSpec: FactsSpec {
        FactsSpec(["top_cpu": .init(relative: 0.5, absolute: 25), "top_mem": .init(relative: 0.5, absolute: 500 * 1024 * 1024),
                   "crashes": .init(relative: 0, absolute: 1), "swap_used": FactsSpec.bytes, "disk_free": FactsSpec.bytes,
                   "battery_capacity": .init(relative: 0, absolute: 1)])
    }
    public var actionSpecs: [any ActionSpec] { [QuitProcess()] + LaunchItemSpecs.all }

    static let context = "Context: a macOS system health check. Explain symptoms and likely causes; prefer checking over acting."

    public func run(_ args: Args, _ ctx: SkillContext) async throws -> SkillResult {
        let ui = ctx.reporter, ev = Evidence()
        let me = NSUserName()
        ui.progress("Sampling CPU, memory, disk and battery...")
        async let topCPU = Command.run(["top", "-l", "2", "-s", "1", "-n", "25", "-o", "cpu", "-stats", "pid,command,cpu,mem,user"], timeout: 30)
        async let topMem = Command.run(["top", "-l", "1", "-n", "15", "-o", "mem", "-stats", "pid,command,cpu,mem,user"], timeout: 20)
        async let swapOut = Command.run(["sysctl", "-n", "vm.swapusage"])
        async let hw = Command.run(["sysctl", "-n", "hw.memsize", "hw.ncpu", "kern.memorystatus_vm_pressure_level"])
        async let ios = Command.run(["iostat", "-d", "-w", "1", "-c", "3"], timeout: 15)
        async let busiest = DiskIO.busiest(interval: 2)
        async let batt = Command.run(["pmset", "-g", "batt"])
        async let profiler = Command.run(["system_profiler", "SPPowerDataType", "-json"], timeout: 40)
        async let therm = Command.run(["pmset", "-g", "therm"])
        async let launch = LaunchItems.scan()
        let minutes = args.int("log_minutes") ?? 15
        async let faults: CommandOutput? = args.flag("no_log") ? nil
            : Command.run(["log", "show", "--last", "\(minutes)m", "--style", "ndjson", "--predicate", "messageType == fault"], timeout: 120)

        let cpuOut = await topCPU, memOut = await topMem
        let top = HealthParse.top(cpuOut.stdout), topM = HealthParse.top(memOut.stdout)
        let hwLines = (await hw).lines
        let ram = Int(hwLines.first ?? "") ?? 0, ncpu = Int(hwLines.dropFirst().first ?? "") ?? 1
        let pressure = Int(hwLines.dropFirst(2).first ?? "") ?? 1
        let swapCmd = await swapOut
        let swap = HealthParse.swap(swapCmd.stdout)
        let (free, total) = diskUsage("/")

        // --- CPU ---------------------------------------------------------------------------------------------
        let cpuObs = ev.observe(cpuOut, String(format: "CPU: %.0f%% user, %.0f%% system, %.0f%% idle; load average %@ on %d cores",
                                               top.cpuUser, top.cpuSys, top.cpuIdle, top.load.map { String($0) }.joined(separator: ", "), ncpu))
        let (launchItems, launchSource) = await launch
        for p in top.processes where p.cpu >= 80 && !["top", "bibi"].contains(p.command) {
            var cites = [ev.observe(cpuOut, "\(p.command) (pid \(p.pid), user \(p.user)) used \(Int(p.cpu))% CPU, \(human(p.mem)) memory"), cpuObs]
            if let agent = launchItems.first(where: { $0.program.map(Paths.name)?.hasPrefix(p.command) == true }) {
                cites.append(ev.observe(launchSource, "\(p.command) is started by login item \(agent.display)"))
            }
            let thermal = p.command == "kernel_task"
            var actions: [BoundAction] = []
            if p.user == me && !QuitProcess.neverQuit.contains(p.command) {
                actions.append(BoundAction(ActionCall("quit_process", ["pid": String(p.pid), "name": p.command]), title: "Quit \(p.command) (pid \(p.pid))",
                                           kind: "quit", target: p.command, safety: 5, confidence: 6,
                                           reason: "frees the CPU now; unsaved work in it may be lost and it may start again",
                                           command: "kill -TERM \(p.pid)"))
            }
            ev.find("cpu", thermal ? "kernel_task is using \(Int(p.cpu))% CPU" : "\(p.command) is using \(Int(p.cpu))% CPU",
                    severity: p.cpu >= 150 ? .high : .medium, cites: cites, confidence: 75,
                    explanation: thermal
                        ? "macOS makes kernel_task busy on purpose to slow other work down when the Mac is too hot; look for heat, a blocked vent or a charger issue."
                        : "\(p.command) kept at least one CPU core busy during the sample. If it stays that way it drains the battery and slows other apps.",
                    diagnostics: thermal ? ["powermetrics", "pmset_therm"] : ["sample_process", "top_cpu"],
                    subject: ["pid": String(p.pid), "process": p.command], actions: actions)
        }
        if let load1 = top.load.first, load1 > Double(ncpu) * 1.5 {
            ev.find("cpu", String(format: "System load is high (%.1f on %d cores)", load1, ncpu), severity: .medium, cites: [cpuObs], confidence: 70,
                    explanation: "More work is waiting for the CPU than there are cores to run it, so everything feels slower.",
                    diagnostics: ["top_cpu"])
        }

        // --- Memory ------------------------------------------------------------------------------------------
        let memObs = ev.observe(cpuOut, "Memory: \(human(top.memUsed)) used of \(human(ram)) (\(human(top.memCompressor)) compressed, \(human(top.memWired)) wired), \(human(top.memUnused)) free; \(top.swapouts) swapouts since boot")
        let swapObs = ev.observe(swapCmd, "Swap: \(human(swap.used)) used of \(human(swap.total))", value: .number(Double(swap.used)))
        let pressureName = [1: "normal", 2: "warning", 4: "critical"][pressure] ?? "level \(pressure)"
        let pressureObs = ev.observe("sysctl kern.memorystatus_vm_pressure_level", "Memory pressure: \(pressureName)")
        let heavy = topM.processes.prefix(3).map { ev.observe(memOut, "\($0.command) (pid \($0.pid)) uses \(human($0.mem))") }
        let crashDays = args.int("crash_days") ?? 7
        let crashes = HealthParse.crashes(in: [ctx.policy.home + "/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"],
                                          since: Date().addingTimeInterval(-Double(crashDays) * 86400))
        let jetsam = crashes.filter { $0.kind == "jetsam" }
        var memCites = [pressureObs, memObs, swapObs] + heavy
        if !jetsam.isEmpty {
            memCites.append(ev.observe("ls ~/Library/Logs/DiagnosticReports", "\(jetsam.count) JetsamEvent report(s) in \(crashDays) days: macOS killed processes to free memory"))
        }
        if pressure >= 2 || swap.used > 4 << 30 || jetsam.count >= 2 {
            ev.find("memory", pressure >= 2 ? "Memory pressure is \(pressureName)" : "The Mac is relying on swap (\(human(swap.used)))",
                    severity: pressure >= 4 ? .high : .medium, cites: memCites, confidence: pressure >= 2 ? 85 : 65,
                    explanation: "Apps need more memory than is free, so macOS compresses memory and writes it to disk, which slows everything down. Quitting the biggest apps or tabs helps most.",
                    diagnostics: ["top_mem", "vm_stat", "memory_pressure"])
        }
        if let biggest = topM.processes.first, ram > 0, biggest.mem > ram / 4 {
            var actions: [BoundAction] = []
            if biggest.user == me && !QuitProcess.neverQuit.contains(biggest.command) {
                actions.append(BoundAction(ActionCall("quit_process", ["pid": String(biggest.pid), "name": biggest.command]),
                                           title: "Quit \(biggest.command) (pid \(biggest.pid))", kind: "quit", target: biggest.command,
                                           bytes: biggest.mem, safety: 5, confidence: 6,
                                           reason: "returns its memory immediately; unsaved work in it may be lost", command: "kill -TERM \(biggest.pid)"))
            }
            ev.find("memory", "\(biggest.command) uses \(human(biggest.mem)) (\(biggest.mem * 100 / ram)% of memory)",
                    severity: biggest.mem > ram / 2 ? .high : .low, cites: [heavy.first!, memObs], confidence: 70,
                    explanation: "One process holds a large share of memory. A leak or many open documents/tabs are the usual causes.",
                    diagnostics: ["top_mem", "sample_process"], subject: ["pid": String(biggest.pid), "process": biggest.command], actions: actions)
        }

        // --- Disk space and I/O ------------------------------------------------------------------------------
        let diskObs = ev.observe("statfs /", "Startup disk: \(human(free)) free of \(human(total))", value: .number(Double(free)))
        if total > 0 && (free < total / 10 || free < 15 << 30) {
            let critical = free < total / 20 || free < 5 << 30
            ev.find("disk", "Startup disk is almost full (\(human(free)) free)", severity: critical ? .high : .medium, cites: [diskObs, swapObs],
                    confidence: 90, explanation: "macOS needs free space for swap, updates and caches; below about 10% everything slows down. Run `bibi storage.optimize` or `bibi dev.cleanup` to find what to remove.",
                    actions: [BoundAction(ActionCall("open_settings_pane", ["pane": "storage"]), title: "Open Storage settings", kind: "open",
                                          target: "storage", safety: 10, confidence: 9, reason: "shows what uses space by category",
                                          command: "open System Settings > Storage")])
        }
        let iosOut = await ios
        let disks = HealthParse.iostat(iosOut.stdout)
        for (disk, v) in disks where v.mbs >= 150 {
            let o = ev.observe(iosOut, String(format: "%@: %.0f MB/s, %.0f transfers/s over the last second", disk, v.mbs, v.tps))
            ev.find("disk-io", "\(disk) is busy (\(Int(v.mbs)) MB/s)", severity: .low, cites: [o], confidence: 55,
                    explanation: "Sustained heavy disk traffic slows app launches and file access. Spotlight indexing, backups, swap and sync clients are common causes.",
                    diagnostics: ["iostat", "fs_usage_process"])
        }
        for r in await busiest where r.readPerSec + r.writtenPerSec >= 30e6 {
            let o = ev.observe("proc_pid_rusage (2 s sample)", String(format: "%@ (pid %d) read %@/s and wrote %@/s", r.name, r.pid,
                                                                        human(r.readPerSec), human(r.writtenPerSec)))
            ev.find("disk-io", "\(r.name) is doing heavy disk I/O", severity: .low, cites: [o], confidence: 60,
                    explanation: "\(r.name) is reading or writing a lot right now. That is fine for a short burst (copying, building, syncing) but slows the Mac if it never stops.",
                    diagnostics: ["fs_usage_process", "lsof_process"], subject: ["pid": String(r.pid), "process": r.name])
        }

        // --- Battery and thermal -----------------------------------------------------------------------------
        let battOut = await batt, profOut = await profiler
        var batteryFacts: [String: JSONValue] = [:]
        if let b = HealthParse.battery(pmset: battOut.stdout, profiler: profOut.stdout) {
            let o = ev.observe(profOut, "Battery: condition \(b.condition ?? "?"), maximum capacity \(b.maxCapacity.map { "\($0)%" } ?? "?"), \(b.cycles.map(String.init) ?? "?") cycles; now \(b.percent.map { "\($0)%" } ?? "?") on \(b.onAC ? "AC power" : "battery")")
            batteryFacts["battery_capacity"] = b.maxCapacity.map { .number(Double($0)) }
            batteryFacts["battery_cycles"] = b.cycles.map { .number(Double($0)) }
            let open = BoundAction(ActionCall("open_settings_pane", ["pane": "battery"]), title: "Open Battery settings", kind: "open", target: "battery",
                                   safety: 10, confidence: 9, reason: "shows battery health and service status", command: "open System Settings > Battery")
            if let c = b.condition, !["Normal", "Good"].contains(c) {
                ev.find("battery", "Battery condition: \(c)", severity: .high, cites: [o], confidence: 90,
                        explanation: "macOS reports the battery needs service. It may hold much less charge or shut down unexpectedly; Apple or an authorized provider can replace it.",
                        diagnostics: ["battery_info"], actions: [open])
            } else if let cap = b.maxCapacity, cap < 80 {
                ev.find("battery", "Battery holds \(cap)% of its original charge", severity: .medium, cites: [o], confidence: 85,
                        explanation: "Below 80% capacity, battery life is noticeably shorter. That's normal wear after many cycles.",
                        diagnostics: ["battery_info"], actions: [open])
            } else if let cycles = b.cycles, cycles > 1000 {
                ev.find("battery", "Battery has \(cycles) charge cycles", severity: .low, cites: [o], confidence: 70,
                        explanation: "Mac batteries are rated for about 1000 cycles; expect capacity to drop from here.", diagnostics: ["battery_info"])
            }
        }
        let thermOut = await therm
        let thermal = HealthParse.thermal(thermOut.stdout)
        if let limit = thermal.speedLimit, limit < 100 {
            let o = ev.observe(thermOut, "CPU speed limit: \(limit)% (100% = not throttled)")
            ev.find("thermal", "The CPU is being slowed down to \(limit)% to stay cool", severity: .medium, cites: [o, cpuObs], confidence: 80,
                    explanation: "The Mac is too warm, so macOS limits CPU speed. Heavy apps, a warm room, a blocked vent or a weak charger can cause it.",
                    diagnostics: ["powermetrics", "pmset_therm"])
        } else if !thermal.warnings.isEmpty {
            let o = ev.observe(thermOut, thermal.warnings.joined(separator: "; "))
            ev.find("thermal", "Thermal or power warnings were recorded", severity: .low, cites: [o], confidence: 60,
                    explanation: "macOS recorded a thermal or power limit since startup.", diagnostics: ["pmset_therm"])
        }

        // --- Crashes and log faults --------------------------------------------------------------------------
        let grouped = Dictionary(grouping: crashes.filter { $0.kind != "jetsam" && $0.kind != "other" }) { $0.process }
        for (process, list) in grouped.sorted(by: { $0.value.count > $1.value.count }) where list.count >= 2 {
            let latest = list.max { $0.date < $1.date }!
            let kinds = Set(list.map(\.kind)).sorted().joined(separator: "/")
            let o = ev.observe("ls ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports",
                               "\(process): \(list.count) \(kinds) report(s) in \(crashDays) days, latest \(ago(latest.date)) (\(Paths.name(latest.path)))")
            ev.find("crash", "\(process) \(kinds == "hang" ? "hung" : "crashed") \(list.count) times in \(crashDays) days",
                    severity: list.count >= 10 ? .high : list.count >= 3 ? .medium : .low, cites: [o], confidence: 85,
                    explanation: "Repeated \(kinds) reports point to a bug, a bad plug-in or extension, or corrupted settings for this app. Updating or reinstalling it, or checking its log, usually shows which.",
                    diagnostics: ["log_process", "crash_reports"], subject: ["process": process, "path": latest.path],
                    actions: [BoundAction(ActionCall("reveal", ["path": latest.path]), title: "Show the latest \(process) report", kind: "review",
                                          target: latest.path, safety: 10, confidence: 9, reason: "the report names the crashing thread and library",
                                          command: "open -R \(Paths.short(latest.path))", weight: 0.4)])
        }
        if let fout = await faults {
            let counts = HealthParse.logCounts(fout.stdout)
            for (process, n) in counts.sorted(by: { $0.value > $1.value }).prefix(5) where n >= 50 {
                let o = ev.observe(fout, "\(process) logged \(n) faults in the last \(minutes) minutes")
                ev.find("log", "\(process) is logging many faults (\(n) in \(minutes) min)", severity: .low, cites: [o], confidence: 50,
                        explanation: "Faults are errors a component considers serious. A steady stream from one process often goes with high CPU, failing sync or a crash loop.",
                        diagnostics: ["log_process"], subject: ["process": process])
            }
        }

        // --- Login and background items ----------------------------------------------------------------------
        let third = launchItems.filter { !$0.isApple }
        var itemObs: [String] = []
        for item in third {
            let state = item.pid != nil ? "running (pid \(item.pid!))" : item.loaded ? "loaded, not running" : "not loaded"
            let id = ev.observe(item.path, "\(item.label): runs \(item.program.map(Paths.short) ?? "?"), \(item.runAtLoad ? "at login" : "on demand")\(item.keepAlive ? ", kept alive" : ""), \(state)" + (item.lastExit.map { $0 != 0 ? ", last exit \($0)" : "" } ?? ""))
            itemObs.append(id)
            if !item.programExists {
                ev.find("login-items", "Leftover login item \(item.label): its program is gone", severity: .low, cites: [id], confidence: 90,
                        explanation: "The app this belongs to was probably removed, but launchd still tries to start it at login.",
                        diagnostics: ["plist_show"], subject: ["path": item.path, "label": item.label],
                        actions: [item.disableAction(reason: "the program it starts no longer exists", safety: 8, confidence: 8)])
            } else if item.keepAlive, item.loaded, item.pid == nil, let code = item.lastExit, code != 0 {
                ev.find("login-items", "\(item.label) keeps failing (exit \(code))", severity: .low, cites: [id], confidence: 70,
                        explanation: "launchd keeps restarting this background item and it keeps exiting with an error, which wastes CPU and fills the log.",
                        diagnostics: [item.scope == .systemDaemon ? "launchctl_system" : "launchctl_user", "log_process"],
                        subject: ["path": item.path, "label": item.label, "process": Paths.name(item.program ?? item.label)],
                        actions: [item.disableAction(reason: "stops the restart loop; undo restores it", safety: 6, confidence: 6)])
            }
        }
        if !third.isEmpty {
            ev.find("login-items", "\(third.count) third-party login and background items", severity: .info, cites: Array(itemObs.prefix(25)),
                    confidence: 95, explanation: "These start automatically. Each one costs a little memory and CPU; remove the ones you don't recognize or need.",
                    actions: [BoundAction(ActionCall("open_settings_pane", ["pane": "login-items"]), title: "Open Login Items settings", kind: "open",
                                          target: "login-items", safety: 10, confidence: 9, reason: "turn background items on or off per app",
                                          command: "open System Settings > Login Items")])
        }

        var facts: [String: JSONValue] = [
            "top_cpu": .numbers(Dictionary(top.processes.filter { $0.cpu >= 5 }.prefix(10).map { ($0.command, $0.cpu) }, uniquingKeysWith: max)),
            "top_mem": .numbers(Dictionary(topM.processes.prefix(10).map { ($0.command, Double($0.mem)) }, uniquingKeysWith: max)),
            "login_items": .strings(third.map(\.label)),
            "crashes": .numbers(grouped.mapValues { Double($0.count) }),
            "swap_used": .number(Double(swap.used)), "disk_free": .number(Double(free)), "pressure": .string(pressureName),
        ]
        facts.merge(batteryFacts) { $1 }

        // New background items since the baseline are worth a look on their own.
        if let diff = ctx.diff(facts, spec: factsSpec) {
            for ch in diff.changes where ch.key == "login_items" && ch.kind == .added {
                guard let item = third.first(where: { $0.label == ch.item }) else { continue }
                let o = ev.observe("bibi history (run \(diff.baselineRun))", "\(item.label) was not there on \(diff.baselineDate.formatted(date: .abbreviated, time: .omitted))")
                ev.find("login-items", "New background item since last check: \(item.label)", severity: .low, cites: [o] + itemObs.filter { id in ev.allObservations.first { $0.id == id }?.text.hasPrefix(item.label) == true },
                        confidence: 80, explanation: "Something installed a new item that starts automatically. That's normal after installing an app; if you don't recognize it, look it up before keeping it.",
                        diagnostics: ["plist_show", "codesign_info"], subject: ["path": item.path, "label": item.label],
                        actions: [item.disableAction(reason: "stops it from starting automatically; undo restores it", safety: 6, confidence: 6)])
            }
        }

        ui.progress("Asking fm to explain and connect the findings...")
        let explained = await ctx.explainer.explainAll(ev.sortedFindings(), observations: ev.allObservations, context: Self.context, limit: 10)
        let hypotheses = await ctx.explainer.correlate(explained, observations: ev.allObservations, context: Self.context)
        let counts = Dictionary(grouping: explained.filter { $0.severity > .info }) { $0.severity }.mapValues(\.count)
        let summary = String(format: "%d issue(s): %d high, %d medium, %d low. CPU %.0f%% idle, memory pressure %@, swap %@, %@ free on disk.",
                             counts.values.reduce(0, +), counts[.high] ?? 0, counts[.medium] ?? 0, counts[.low] ?? 0,
                             top.cpuIdle, pressureName, human(swap.used), human(free))
        return SkillResult(summary: summary, observations: ev.allObservations, findings: explained, hypotheses: hypotheses, facts: facts)
    }
}
