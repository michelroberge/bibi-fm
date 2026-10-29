import BibiCore
import Foundation

/// sec.audit: firewall, encryption, Gatekeeper/SIP, updates, sharing services, listening ports, persistence and
/// configuration weaknesses. Every detection is a deterministic check; fm only explains the results.
public struct SecAudit: Skill {
    public init() {}
    public let name = "sec.audit"
    public let help = "Audit firewall, sharing, listening ports, updates, persistence and security settings"
    public let keywords = "security secure firewall ports listening sharing malware audit vulnerable safe persistence hacked"
    public var usesWeb: Bool { true }
    public var params: [Param] { [.flag("no_explain", "--no-explain", help: "skip fm explanations (faster, rule text only)")] }
    public var actionSpecs: [any ActionSpec] {
        [FirewallSet(enable: true), FirewallSet(enable: false), SharingSet(enable: false), SharingSet(enable: true)] + LaunchItemSpecs.all
    }

    public var prompts: [PromptDefinition] {
        [PromptDefinition("sec.audit.context", "Security audit context", group: PromptCatalog.analysis,
                          purpose: "Put before each finding sec.audit asks the model to explain.", builtIn: Self.context)]
    }

    static let context = "Context: a macOS security posture audit for a technical user. Be precise and calm; say how to verify before changing anything."

    struct Check {
        var name: String
        var passed: Bool?
    }

    public func run(_ args: Args, _ ctx: SkillContext) async throws -> SkillResult {
        let ui = ctx.reporter, ev = Evidence()
        var checks: [Check] = []
        ui.progress("Checking firewall, encryption and system protections...")
        let fwTool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        async let fwOut = Command.run([fwTool, "--getglobalstate", "--getstealthmode", "--getblockall", "--getallowsigned"])
        async let fv = Command.run(["fdesetup", "status"])
        async let gk = Command.run(["spctl", "--status"])
        async let sip = Command.run(["csrutil", "status"])
        async let su = Command.run(["defaults", "read", "/Library/Preferences/com.apple.SoftwareUpdate"])
        async let lw = Command.run(["defaults", "read", "/Library/Preferences/com.apple.loginwindow"])
        async let lock = Command.run(["sysadminctl", "-screenLock", "status"])
        async let guest = Command.run(["sysadminctl", "-guestAccount", "status"])
        async let disabled = Command.run(["launchctl", "print-disabled", "system"])
        async let tcp = Command.run(["lsof", "-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-F", "pcLn"], timeout: 30)
        async let udp = Command.run(["lsof", "-nP", "+c", "0", "-iUDP", "-F", "pcLn"], timeout: 30)
        async let launch = LaunchItems.scan()
        async let cron = Command.run(["crontab", "-l"])
        async let sysext = Command.run(["systemextensionsctl", "list"])
        async let mdm = Command.run(["profiles", "status", "-type", "enrollment"])

        let pane = { (pane: String, what: String) in
            BoundAction(ActionCall("open_settings_pane", ["pane": pane]), title: "Open \(what) settings", kind: "open", target: pane,
                        safety: 10, confidence: 9, reason: "change it yourself in System Settings", command: "open System Settings > \(what)")
        }

        // Firewall
        let fw = await fwOut
        let f = SecParse.firewall(fw.stdout)
        let fwObs = ev.observe(fw, "Firewall \(f.enabled ? "on" : "off"), stealth mode \(f.stealth ? "on" : "off"), block all \(f.blockAll ? "on" : "off"); signed apps allowed automatically: built-in \(f.allowSigned ? "yes" : "no"), downloaded \(f.allowDownloaded ? "yes" : "no")")
        checks.append(Check(name: "firewall", passed: f.enabled))
        if !f.enabled {
            ev.find("firewall", "The firewall is off", severity: .medium, cites: [fwObs], confidence: 90,
                    explanation: "Without the application firewall, any app that listens on the network accepts connections from other devices on the same Wi-Fi. Turn it on, especially on public networks.",
                    diagnostics: ["firewall_apps", "lsof_listen"],
                    actions: [BoundAction(ActionCall("firewall_enable", ["setting": "global"]), title: "Turn on the firewall", kind: "admin",
                                          target: "firewall", safety: 9, confidence: 9, reason: "blocks unexpected incoming connections; allowed apps keep working",
                                          command: "sudo socketfilterfw --setglobalstate on", privilege: .admin, reversible: true),
                              pane("firewall", "Firewall")])
        } else if !f.stealth {
            ev.find("firewall", "Firewall stealth mode is off", severity: .low, cites: [fwObs], confidence: 80,
                    explanation: "Stealth mode makes the Mac ignore pings and probes to closed ports, so it is harder to discover on untrusted networks.",
                    actions: [BoundAction(ActionCall("firewall_enable", ["setting": "stealth"]), title: "Turn on stealth mode", kind: "admin",
                                          target: "firewall", safety: 9, confidence: 8, reason: "the Mac stops answering probes",
                                          command: "sudo socketfilterfw --setstealthmode on", privilege: .admin, reversible: true)])
        }
        checks.append(Check(name: "stealth", passed: f.stealth))

        // FileVault, Gatekeeper, SIP
        let fvOut = await fv, gkOut = await gk, sipOut = await sip
        let fvOn = fvOut.stdout.contains("FileVault is On")
        checks.append(Check(name: "filevault", passed: fvOut.ok ? fvOn : nil))
        if fvOut.ok && !fvOn {
            ev.find("encryption", "FileVault disk encryption is off", severity: .high, cites: [ev.observe(fvOut, fvOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines))],
                    confidence: 95, explanation: "Anyone with the Mac in hand can read the disk without your password. Turning FileVault on encrypts it in the background; keep the recovery key safe.",
                    actions: [pane("filevault", "FileVault")])
        }
        let gkOn = gkOut.stdout.contains("assessments enabled")
        checks.append(Check(name: "gatekeeper", passed: gkOn))
        if !gkOn {
            ev.find("gatekeeper", "Gatekeeper is disabled", severity: .high, cites: [ev.observe(gkOut, gkOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty(gkOut.stderr))],
                    confidence: 90, explanation: "Gatekeeper checks downloaded apps for a valid developer signature and Apple's malware notarization. With it off, any downloaded program runs without that check.",
                    actions: [pane("privacy", "Privacy & Security")])
        }
        let sipOn = sipOut.stdout.contains("status: enabled")
        checks.append(Check(name: "sip", passed: sipOut.stdout.isEmpty ? nil : sipOn))
        if !sipOut.stdout.isEmpty && !sipOn {
            ev.find("sip", "System Integrity Protection is off", severity: .high, cites: [ev.observe(sipOut, sipOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines))],
                    confidence: 90, explanation: "SIP stops anything, even with admin rights, from changing protected system files. It can only be turned back on from Recovery mode (csrutil enable).")
        }

        // Software update settings and pending updates
        let suOut = await su
        let settings = ["AutomaticCheckEnabled": "check for updates", "AutomaticDownload": "download updates",
                        "CriticalUpdateInstall": "install security responses and system files", "ConfigDataInstall": "install XProtect data"]
        let off = settings.keys.sorted().filter { SecParse.defaultsValue(suOut.stdout, $0) == "0" }
        checks.append(Check(name: "auto-update", passed: off.isEmpty))
        if !off.isEmpty {
            let o = ev.observe(suOut, "Automatic update settings turned off: " + off.map { "\($0) (\(settings[$0]!))" }.joined(separator: ", "))
            ev.find("updates", "Automatic security updates are partly off", severity: off.contains("CriticalUpdateInstall") || off.contains("ConfigDataInstall") ? .medium : .low,
                    cites: [o], confidence: 85,
                    explanation: "Apple ships malware definitions (XProtect) and urgent security fixes as background updates. With these off, the Mac misses them until you update by hand.",
                    actions: [pane("software-update", "Software Update")])
        }
        if ctx.online {
            ui.progress("Checking for pending macOS updates (softwareupdate -l)...")
            if let pending = try? await PackageManagers.macOSUpdates(ctx.fetcher), !pending.isEmpty {
                let o = ev.observe("softwareupdate -l", "Pending: " + pending.map { "\($0.name) \($0.latest)" }.joined(separator: "; "))
                let security = pending.contains { $0.name.localizedCaseInsensitiveContains("security") || $0.name.contains("macOS") }
                ev.find("updates", "\(pending.count) macOS update(s) waiting", severity: security ? .medium : .low, cites: [o], confidence: 90,
                        explanation: "Installed updates fix known security problems; the longer they wait, the longer the Mac is exposed.",
                        actions: [pane("software-update", "Software Update")])
            }
        }

        // Login window, screen lock, guest
        let lwOut = await lw, lockOut = await lock, guestOut = await guest
        if let user = SecParse.defaultsValue(lwOut.stdout, "autoLoginUser") {
            ev.find("login", "Automatic login is on for \(user)", severity: .medium, cites: [ev.observe(lwOut, "autoLoginUser = \(user)")], confidence: 90,
                    explanation: "Anyone who restarts the Mac gets into this account without a password.", actions: [pane("users", "Users & Groups")])
        }
        checks.append(Check(name: "auto-login", passed: SecParse.defaultsValue(lwOut.stdout, "autoLoginUser") == nil))
        let lockText = lockOut.stdout + lockOut.stderr
        let sl = SecParse.screenLock(lockText)
        let lockObs = ev.observe(lockOut, sl.off ? "Screen lock is off" : "Password required \(sl.delay.map { $0 == 0 ? "immediately" : "\($0 / 60) minute(s)" } ?? "?") after sleep or screen saver")
        checks.append(Check(name: "screen-lock", passed: !sl.off && (sl.delay ?? 0) <= 300))
        if sl.off || (sl.delay ?? 0) > 300 {
            ev.find("login", sl.off ? "No password is required after sleep" : "Password is only required \((sl.delay ?? 0) / 60) minutes after sleep",
                    severity: sl.off ? .medium : .low, cites: [lockObs], confidence: 85,
                    explanation: "An unlocked Mac left unattended gives full access to your accounts and files. Requiring the password immediately (or within a few minutes) closes that window.",
                    actions: [pane("lock-screen", "Lock Screen")])
        }
        let guestText = guestOut.stdout + guestOut.stderr
        if guestText.contains("enabled") && !guestText.contains("disabled") {
            ev.find("login", "The guest account is enabled", severity: .low, cites: [ev.observe(guestOut, guestText.trimmingCharacters(in: .whitespacesAndNewlines))],
                    confidence: 80, explanation: "Anyone can log in as guest. It's sandboxed, but rarely needed.", actions: [pane("users", "Users & Groups")])
        }

        // Sharing services
        let disabledOut = await disabled
        var sharing: [String: JSONValue] = [:]
        for s in SharingServices.all {
            let loaded = await Command.run(["launchctl", "print", "system/\(s.label)"]).ok
            let explicitlyDisabled = disabledOut.stdout.contains("\"\(s.label)\" => disabled") || disabledOut.stdout.contains("\"\(s.label)\" => true")
            let on = loaded && !explicitlyDisabled
            sharing[s.key] = .string(on ? "on" : "off")
            checks.append(Check(name: s.key, passed: !on))
            guard on else { continue }
            let o = ev.observe("launchctl print system/\(s.label)", "\(s.name) is on (\(s.label) is loaded)")
            ev.find("sharing", "\(s.name) is on", severity: s.key == "remote-apple-events" || s.key == "remote-login" ? .medium : .low, cites: [o, fwObs],
                    confidence: 85, explanation: "\(s.name) lets other computers connect to this Mac. Keep it only if you use it, and only with strong passwords or keys.",
                    diagnostics: ["launchctl_system"], subject: ["label": s.label],
                    actions: [pane("sharing", "Sharing"),
                              BoundAction(ActionCall("sharing_service_disable", ["service": s.key]), title: "Turn off \(s.name)", kind: "admin", target: s.label,
                                          safety: 8, confidence: 8, reason: "stops the service now and after restarts; undo turns it back on",
                                          command: "sudo launchctl disable system/\(s.label)", privilege: .admin, reversible: true)])
        }

        // Listening ports
        let tcpOut = await tcp, udpOut = await udp
        let listeners = SecParse.lsof(tcpOut.stdout, proto: "tcp") + SecParse.lsof(udpOut.stdout, proto: "udp").filter(\.external)
        var appleExternal: [String] = [], localOnly: [String] = [], udpExternal: [String] = []
        for l in listeners {
            let path = CodeSign.executable(pid: l.pid)
            let sig = path.map(CodeSign.check)
            if sig?.apple == true {
                if l.external && l.proto == "tcp" { appleExternal.append("\(l.command) \(l.proto)/\(l.port)") }
                continue
            }
            guard l.external else {
                localOnly.append("\(l.command) \(l.proto)/\(l.port)")
                continue
            }
            // Open UDP sockets are mostly discovery (mDNS 5353) and call media; list them instead of flagging each.
            guard l.proto == "tcp" else {
                udpExternal.append("\(l.command) udp/\(l.port)")
                continue
            }
            let o = ev.observe(l.proto == "tcp" ? tcpOut : udpOut, "\(l.command) (pid \(l.pid), user \(l.user)) accepts \(l.proto.uppercased()) connections on port \(l.port) from any network interface")
            let s = ev.observe(path.map { "codesign check of \($0)" } ?? "proc_pidpath", "\(path.map(Paths.short) ?? "unknown path"): \(sig?.summary ?? "could not read signature")")
            let risky = sig.map { !$0.signed || !$0.valid } ?? true
            ev.find("listener", "\(l.command) is reachable from the network on port \(l.port)", severity: risky ? .medium : f.enabled ? .low : .medium,
                    cites: [o, s, fwObs], confidence: 80,
                    explanation: "This program accepts connections from other devices, not just this Mac. That's expected for servers you run on purpose; otherwise bind it to localhost or block it in the firewall.",
                    diagnostics: ["lsof_process", "codesign_info"], subject: ["pid": String(l.pid), "process": l.command, "path": path ?? ""],
                    actions: f.enabled ? [] : [pane("firewall", "Firewall")])
        }
        if !appleExternal.isEmpty {
            let o = ev.observe(tcpOut, "Apple services listening on all interfaces: " + appleExternal.joined(separator: ", "))
            ev.find("listener", "\(appleExternal.count) Apple service port(s) are open to the network", severity: .info, cites: [o], confidence: 90,
                    explanation: "These are macOS features such as AirPlay Receiver (ports 5000/7000) and Continuity. Turn off the ones you don't use under General > AirDrop & Handoff and Sharing.",
                    actions: [pane("sharing", "Sharing")])
        }
        if !udpExternal.isEmpty {
            let o = ev.observe(udpOut, "Third-party UDP sockets open on all interfaces: " + udpExternal.joined(separator: ", "))
            ev.find("listener", "\(udpExternal.count) third-party UDP socket(s) open to the network", severity: .info, cites: [o], confidence: 80,
                    explanation: "Usually network discovery (mDNS on port 5353) or audio/video calls. With the firewall on, macOS asks before an app may accept incoming traffic.",
                    diagnostics: ["lsof_listen"])
        }
        if !localOnly.isEmpty {
            let o = ev.observe(tcpOut, "Listening only on this Mac (localhost): " + localOnly.joined(separator: ", "))
            ev.find("listener", "\(localOnly.count) local-only server(s)", severity: .info, cites: [o], confidence: 95,
                    explanation: "These only accept connections from this Mac (development databases, editors, model servers). Other devices can't reach them.")
        }
        if listeners.isEmpty == false || tcpOut.ok {
            // lsof without root can't see other users' (root) daemons.
            checks.append(Check(name: "listeners-scanned", passed: true))
        }

        // Persistence: launchd items, cron, system extensions, MDM
        ui.progress("Checking login items, launch daemons and other persistence...")
        let (items, listSource) = await launch
        var persistence: [String] = []
        var unknownForSearch: [(String, LaunchItem)] = []
        for item in items where !item.isApple {
            let sig = item.program.flatMap { Paths.exists($0) ? CodeSign.check($0) : nil }
            let flags = SecParse.persistenceFlags(item, signature: sig)
            let hash = Hashing.sha256(file: item.path).map { String($0.prefix(12)) } ?? "?"
            persistence.append("\(item.label) [\(hash)]")
            let added = Paths.mtime(item.path).map { ago($0) } ?? "?"
            let o = ev.observe(item.path, "\(item.label) (\(item.scope == .systemDaemon ? "system daemon, runs as root" : item.scope == .systemAgent ? "agent for every user" : "your login agent")) runs \(item.program.map(Paths.short) ?? "?") \(item.arguments.dropFirst().prefix(3).joined(separator: " ")); plist changed \(added)")
            let s = ev.observe(item.program.map { "codesign check of \($0)" } ?? listSource, item.program.map { Paths.exists($0) ? "\(Paths.short($0)): \(sig?.summary ?? "?")" : "\(Paths.short($0)) does not exist" } ?? "no program")
            guard !flags.isEmpty, item.programExists else { continue }
            let severe = flags.contains { $0.contains("temporary") || $0.contains("hidden") || $0.contains("unsigned") || $0.contains("invalid") }
            ev.find("persistence", "\(item.label) starts automatically and \(flags.joined(separator: ", "))", severity: severe ? .high : .medium,
                    cites: [o, s], confidence: severe ? 70 : 55,
                    explanation: "Legitimate software rarely starts unsigned programs, scripts or files from hidden or temporary folders at login; malware often does. Check who installed it before removing it.",
                    diagnostics: ["plist_show", "codesign_info", "spctl_assess"], subject: ["path": item.program ?? item.path, "label": item.label],
                    actions: [item.disableAction(reason: "stops it from starting; the plist is kept in quarantine and undo restores it", safety: 6, confidence: 6)])
            if sig?.apple != true { unknownForSearch.append((ev.allFindings.last!.id, item)) }
        }
        let cronOut = await cron
        let cronLines = cronOut.lines.filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !cronLines.isEmpty {
            let o = ev.observe(cronOut, "Your crontab runs: " + cronLines.prefix(5).joined(separator: " | "))
            ev.find("persistence", "\(cronLines.count) cron job(s) in your crontab", severity: .low, cites: [o], confidence: 70,
                    explanation: "Cron jobs run commands on a schedule. Make sure you recognize each one (crontab -e to edit).")
        }
        let extOut = await sysext
        let exts = SecParse.systemExtensions(extOut.stdout)
        if !exts.isEmpty {
            let o = ev.observe(extOut, "Active system extensions: " + exts.prefix(6).joined(separator: " | "))
            ev.find("persistence", "\(exts.count) third-party system extension(s) active", severity: .info, cites: [o], confidence: 90,
                    explanation: "System extensions (network filters, endpoint security, drivers) run with deep access. VPNs and security tools use them; remove the ones from apps you no longer use.",
                    actions: [pane("privacy", "Privacy & Security")])
        }
        let mdmOut = await mdm
        if mdmOut.stdout.contains("MDM enrollment: Yes") {
            ev.find("persistence", "This Mac is managed by an organization (MDM)", severity: .info,
                    cites: [ev.observe(mdmOut, mdmOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines))], confidence: 95,
                    explanation: "Device management can install profiles, apps and settings. That's expected on a work Mac; on a personal Mac, find out who enrolled it.",
                    actions: [pane("profiles", "Device Management")])
        }

        // New since the baseline: listeners and persistence are the interesting changes.
        let facts: [String: JSONValue] = [
            "listeners": .strings(listeners.map(\.key)), "persistence": .strings(persistence), "sharing": .object(sharing),
            "checks": .object(Dictionary(uniqueKeysWithValues: checks.map { ($0.name, $0.passed.map { JSONValue.string($0 ? "pass" : "fail") } ?? .string("unknown")) })),
        ]
        if let diff = ctx.diff(facts, spec: factsSpec) {
            for ch in diff.changes where ch.kind == .added && ["listeners", "persistence"].contains(ch.key) {
                let o = ev.observe("bibi history (run \(diff.baselineRun))", "\(ch.item ?? "?") was not there on \(diff.baselineDate.formatted(date: .abbreviated, time: .omitted))")
                let external = ch.key == "listeners" && !(ch.item ?? "").contains("local only")
                ev.find("change", ch.key == "listeners" ? "New listening port since last audit: \(ch.item ?? "")" : "New startup item since last audit: \(ch.item ?? "")",
                        severity: ch.key == "persistence" || external ? .high : .medium, cites: [o], confidence: 80,
                        explanation: "This appeared since the last audit. Installing or updating an app explains most changes; if you can't connect it to something you did, investigate it.",
                        diagnostics: ch.key == "listeners" ? ["lsof_listen"] : ["plist_show"])
            }
        }

        // Optional: vendor documentation for unknown persistence items (names only).
        if ctx.online {
            for (fid, item) in unknownForSearch.prefix(3) {
                ui.progress("Looking up \(item.label)...")
                let results = await WebSearch.search("\(item.label) launch agent macOS", fetcher: ctx.fetcher, limit: 2)
                guard !results.isEmpty else { continue }
                let o = ev.observe("duckduckgo: \(item.label)", results.joined(separator: " | "))
                ev.update(fid) { $0.observationIDs.append(o) }
            }
        }

        var findings = ev.sortedFindings()
        if !args.flag("no_explain") {
            findings = await ctx.explainer.explainAll(findings, observations: ev.allObservations, context: ctx.prompts.text("sec.audit.context", default: Self.context), limit: 10)
        }
        let failed = checks.filter { $0.passed == false }.map(\.name)
        let counts = Dictionary(grouping: findings.filter { $0.severity > .info }) { $0.severity }.mapValues(\.count)
        return SkillResult(
            summary: "\(checks.filter { $0.passed == true }.count) of \(checks.count) checks passed. \(counts[.high] ?? 0) high, \(counts[.medium] ?? 0) medium, \(counts[.low] ?? 0) low."
                + (failed.isEmpty ? "" : " Failed: \(failed.joined(separator: ", ")).")
                + (ctx.online ? "" : " (offline: pending updates and vendor lookups skipped; use --online)"),
            observations: ev.allObservations, findings: findings, facts: facts,
            notes: ["listening ports of root-owned daemons are only visible with admin rights (diagnostic: lsof_listen_all)"])
    }
}
