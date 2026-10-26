import BibiCore
import BibiSkills
import BibiWeb
import Foundation

/// Options every skill command accepts, removed from argv before the skill's own parameters are parsed.
struct Common {
    var verbose = false
    var dryRun = false
    var select: String?
    var online: Bool?
    var web = false
    var since: String?

    static let help = """
      -v, --verbose           show model verdicts and debug output
      --dry-run               show what would run without changing anything
      --select CHOICE         answer the action prompt up front: '1,2,5', 'all' or 'none'
      --online                allow internet lookups (advisories, versions, vendor docs)
      --web                   show the results in the web UI
      --since AGE|RUN         baseline to compare with: 7d, 24h or a run id (default: about a week ago)
    """

    /// Splits argv into common options and the rest.
    static func extract(_ argv: [String]) throws -> (Common, [String]) {
        var c = Common(), rest: [String] = []
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < argv.count else { throw ArgError("\(flag) needs a value") }
            return argv[i]
        }
        while i < argv.count {
            let a = argv[i]
            switch a {
            case "-v", "--verbose": c.verbose = true
            case "--dry-run": c.dryRun = true
            case "--select": c.select = try value(a)
            case "--online": c.online = true
            case "--web": c.web = true
            case "--since": c.since = try value(a)
            default:
                if a.hasPrefix("--select=") { c.select = String(a.dropFirst(9)) }
                else if a.hasPrefix("--since=") { c.since = String(a.dropFirst(8)) }
                else { rest.append(a) }
            }
            i += 1
        }
        return (c, rest)
    }
}

struct CLI {
    let harness = Harness(skills: AllSkills.list) {
        if let reason = FoundationModel.unavailableReason() { return UnavailableModel(reason) }
        return FoundationModel()
    }

    func main(_ argv: [String]) async -> Int32 {
        guard let first = argv.first else { return list(nil) }
        let rest = Array(argv.dropFirst())
        do {
            switch first {
            case "-h", "--help", "help": return usage()
            case "--version": print("bibi \(Bibi.version)"); return 0
            case "list": return list(nil)
            case "ui": return try await ui(rest)
            case "history": return history(rest)
            case "undo": return await undo(rest)
            case "diff": return diff(rest)
            default: break
            }
            if let skill = harness.skill(named: first) { return try await run(skill, rest) }
            if harness.skills.keys.contains(where: { $0.hasPrefix(first + ".") }) { return list(first) }
            fputs("bibi: unknown command '\(first)'. Run 'bibi list'.\n", stderr)
            return 2
        } catch let e as ArgError {
            fputs("bibi: \(e)\n", stderr)
            return 2
        } catch {
            fputs("bibi: \(error)\n", stderr)
            return 1
        }
    }

    func usage() -> Int32 {
        print("""
        bibi: a local agent powered by Apple's on-device Foundation Model.

        Usage:
          bibi list                      list commands
          bibi <command> [arguments]     run a command (bibi <command> --help for its options)
          bibi ui                        open the web UI
          bibi history [command]         list saved runs; bibi history show <run> for details
          bibi undo <run> [--select 1,2] undo actions taken in a run
          bibi diff <command> [--since]  compare the latest run with an earlier one
        """)
        return 0
    }

    func list(_ namespace: String?) -> Int32 {
        print("Commands:")
        var current = ""
        for s in harness.sortedSkills where namespace == nil || s.namespace == namespace {
            if s.namespace != current {
                print("\n  \(s.namespace)")
                current = s.namespace
            }
            let web = s.usesWeb ? "  [web]" : ""
            let admin = s.actionSpecs.contains { $0.privilege == .admin } ? "  [admin]" : ""
            print("    \(s.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(s.help)\(web)\(admin)")
        }
        print("\nRun 'bibi <command> --help' for details. [web] = may contact internet services; [admin] = some actions ask for your password.")
        print("Also: bibi ui, bibi history, bibi undo, bibi diff")
        return 0
    }

    // MARK: running a skill

    func run(_ skill: any Skill, _ argv: [String]) async throws -> Int32 {
        if argv.contains("-h") || argv.contains("--help") {
            print("usage: bibi \(skill.name) [options]\n\n\(skill.help)\n\n\(helpText(skill.params))\n\(Common.help)")
            return 0
        }
        let (common, skillArgv) = try Common.extract(argv)
        if common.web { return try await ui(["--run", skill.name] + skillArgv + (common.online == true ? ["--online"] : [])) }
        let ui = TerminalReporter(verbose: common.verbose)
        if let reason = FoundationModel.unavailableReason() { ui.error("note: fm unavailable (\(reason)); showing rule-based results only") }
        let options = RunOptions(online: common.online, dryRun: common.dryRun, verbose: common.verbose, since: common.since)
        let record: RunRecord, result: SkillResult
        do {
            (record, result) = try await harness.run(skill, argv: skillArgv, reporter: ui, options: options)
        } catch is CancellationError {
            ui.error("\nInterrupted.")
            return 130
        }
        ui.info(result.summary)
        for n in result.notes { ui.info("note: \(n)") }
        ui.report(result)
        let actions = result.actions
        ui.info(ui.c("2", "\nSaved as run \(record.id) (bibi history show \(record.id); bibi ui to browse)"))
        guard !actions.isEmpty else {
            ui.info("No actions recommended.")
            return 0
        }
        return await approve(actions, result: result, record: record, skill: skill, common: common, ui: ui)
    }

    /// The terminal approval loop: pick by number, inspect with `d N`, preview with `p N,M`.
    func approve(_ actions: [BoundAction], result: SkillResult, record: RunRecord, skill: any Skill, common: Common,
                 ui: TerminalReporter) async -> Int32 {
        let env = harness.env(admin: SudoRunner(), reporter: ui)
        var choice = common.select
        var picked: [Int] = []
        while true {
            if choice == nil {
                guard isatty(0) == 1 else {
                    ui.info("Not interactive and no --select given; nothing run.")
                    return 0
                }
                choice = ui.ask("\nRun which? (e.g. 1,2,5 / all / none; d 2 = details, p 1,2 = preview): ")
            }
            let text = choice!.trimmingCharacters(in: .whitespaces)
            choice = nil
            if text.hasPrefix("d ") || text.hasPrefix("p ") {
                do {
                    let idx = try Selection.parse(String(text.dropFirst(2)), count: actions.count)
                    for i in idx {
                        let a = actions[i]
                        if text.hasPrefix("d ") {
                            ui.heading("\(i + 1). \(a.title)")
                            if let f = result.findings.first(where: { $0.id == a.findingID }) { ui.finding(f, result, brief: false) }
                        } else {
                            let p = harness.preview([a], env: env, run: record)[0]
                            ui.info("\(i + 1). \(a.title)\(p.privilege == .admin ? "  [admin]" : "")\(p.reversible ? "  [undoable]" : "")")
                            if let e = p.error { ui.error("   cannot run: \(e)") }
                            for s in p.steps { ui.info("   - \(s)") }
                        }
                    }
                } catch {
                    ui.error("\(error)")
                }
                continue
            }
            do {
                picked = try Selection.parse(text, count: actions.count)
                break
            } catch {
                ui.error("\(error)")
                if common.select != nil { return 2 }
            }
        }
        guard !picked.isEmpty else {
            ui.info("Nothing run.")
            return 0
        }
        var chosen = picked.map { actions[$0] }
        var adminOK = false
        let admin = chosen.filter { $0.privilege == .admin }
        if !admin.isEmpty && !common.dryRun {
            if isatty(0) != 1 {
                ui.error("Skipping \(admin.count) action(s) that need administrator rights (run interactively to approve them).")
            } else {
                ui.info(ui.c("33", "\n\(admin.count) action(s) need administrator rights: " + admin.map(\.title).joined(separator: "; ")))
                adminOK = ui.ask("sudo will ask for your password for each one. Continue with these? [y/N] ").lowercased().hasPrefix("y")
            }
            if !adminOK { chosen.removeAll { $0.privilege == .admin } }
        }
        let results = await harness.execute(chosen, run: record, env: env, adminConfirmed: adminOK, dryRun: common.dryRun,
                                            frontend: "terminal")
        if common.dryRun { for r in results { ui.info("\(r.title): \(r.message)") } }
        for r in results where r.output != nil {
            ui.heading(r.title)
            ui.info(String(r.output!.prefix(4000)))
        }
        if !common.dryRun, results.contains(where: \.ok) {
            if let line = await skill.afterRun(result, SkillContext(model: UnavailableModel("n/a"), reporter: ui)) { ui.ok(line) }
            if results.contains(where: \.reversible) { ui.info(ui.c("2", "Undo with: bibi undo \(record.id)")) }
        }
        return results.allSatisfy(\.ok) ? 0 : 1
    }

    // MARK: history, undo, diff

    func history(_ argv: [String]) -> Int32 {
        if argv.first == "show", argv.count >= 2 {
            guard let run = harness.store.find(argv[1]) else {
                fputs("bibi: no run '\(argv[1])'\n", stderr)
                return 1
            }
            if argv.contains("--json") {
                print(String(decoding: (try? JSON.prettyEncoder.encode(run.report())) ?? Data(), as: UTF8.self))
                return 0
            }
            let ui = TerminalReporter(verbose: false)
            let m = run.meta
            ui.heading("\(m.skill) \(m.args.joined(separator: " "))  —  run \(m.id)")
            ui.info("started \(m.started.formatted()), \(m.online ? "online" : "offline")")
            if let e = m.error { ui.error("failed: \(e)") }
            if let r = run.report() {
                ui.info(r.summary)
                for f in r.findings { ui.finding(f, r, brief: true) }
            }
            let journal = run.journalEntries.filter { $0.event != .previewed }
            if !journal.isEmpty {
                ui.heading("Actions")
                for e in journal {
                    ui.info("  \(e.time.formatted(date: .omitted, time: .standard))  \(e.event.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(e.title ?? "")"
                            + (e.message.map { " — \($0)" } ?? "") + (e.error.map { " — error: \($0)" } ?? ""))
                }
            }
            let model = run.modelEntries, net = run.networkEntries
            ui.info(ui.c("2", "\n\(model.count) model call(s), \(net.count) network request(s). Files: \(run.dir)"))
            return 0
        }
        let runs = harness.store.list(skill: argv.first)
        if runs.isEmpty { print("No runs yet.") }
        for r in runs.prefix(50) {
            let m = r.meta
            let status = m.error != nil ? "failed" : "\(m.findings ?? 0) findings"
            let undo = r.undoable.isEmpty ? "" : "  (undoable)"
            print("\(m.id)  \(m.skill.padding(toLength: 18, withPad: " ", startingAt: 0)) \(status.padding(toLength: 13, withPad: " ", startingAt: 0)) \(m.args.joined(separator: " "))\(undo)")
        }
        return 0
    }

    func undo(_ argv: [String]) async -> Int32 {
        let ui = TerminalReporter(verbose: false)
        guard let id = argv.first, let run = harness.store.find(id) else {
            ui.error("usage: bibi undo <run> [--select 1,2]  (see bibi history)")
            return 2
        }
        let entries = run.undoable
        guard !entries.isEmpty else {
            ui.info("Nothing to undo in run \(run.id).")
            return 0
        }
        ui.heading("Undoable actions in run \(run.id)")
        for (i, e) in entries.enumerated() { ui.info("\(String(format: "%2d.", i + 1)) \(e.title ?? "") — \(e.message ?? "")") }
        var select = argv.firstIndex(of: "--select").flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
        if select == nil {
            guard isatty(0) == 1 else { ui.info("Not interactive and no --select given; nothing undone."); return 0 }
            select = ui.ask("\nUndo which? (e.g. 1,2 / all / none): ")
        }
        guard let idx = try? Selection.parse(select!, count: entries.count), !idx.isEmpty else {
            ui.info("Nothing undone.")
            return 0
        }
        let only = Set(idx.compactMap { entries[$0].actionID })
        var adminOK = false
        if harness.undoNeedsAdmin(run) && isatty(0) == 1 {
            adminOK = ui.ask("Some of these need administrator rights; sudo will ask for your password. Continue? [y/N] ").lowercased().hasPrefix("y")
        }
        let results = await harness.undo(run, only: only, env: harness.env(admin: SudoRunner(), reporter: ui),
                                         adminConfirmed: adminOK, frontend: "terminal")
        return results.allSatisfy(\.ok) ? 0 : 1
    }

    func diff(_ argv: [String]) -> Int32 {
        guard let (common, rest) = try? Common.extract(argv), let name = rest.first, let skill = harness.skill(named: name) else {
            fputs("usage: bibi diff <command> [--since 7d|run]\n", stderr)
            return 2
        }
        guard let latest = harness.store.list(skill: skill.name).first(where: { $0.meta.error == nil && $0.meta.finished != nil }),
              let new = latest.report() else {
            print("No runs of \(skill.name) yet.")
            return 0
        }
        guard let base = harness.store.baseline(skill: skill.name, since: common.since, excluding: latest.id), let old = base.report() else {
            print("Only one run of \(skill.name) so far; nothing to compare.")
            return 0
        }
        let changes = Baseline.diff(old: old.facts, new: new.facts, spec: skill.factsSpec)
        print("\(skill.name): run \(latest.id) compared with \(base.id) (\(base.meta.started.formatted()))")
        if changes.isEmpty { print("  nothing changed") }
        for ch in changes { print("  \(ch.kind == .added ? "+" : ch.kind == .removed ? "-" : "~") \(ch.text)") }
        return 0
    }

    // MARK: web

    func ui(_ argv: [String]) async throws -> Int32 {
        var port = 0, open = true, runArgv: [String]?
        var i = 0
        while i < argv.count {
            switch argv[i] {
            case "--port": i += 1; port = Int(argv[i]) ?? 0
            case "--no-open": open = false
            case "--run": runArgv = Array(argv[(i + 1)...]); i = argv.count
            default: throw ArgError("unknown option \(argv[i]) (bibi ui [--port N] [--no-open])")
            }
            i += 1
        }
        try await WebServer(harness: harness).serve(port: port, openBrowser: open, initialRun: runArgv)
        return 0
    }
}
