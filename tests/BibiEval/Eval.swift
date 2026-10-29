import BibiCore
import BibiSkills
import Foundation

struct EvalOptions {
    /// Only cases whose request or tags contain this.
    var filter: String?
    var json = false
    var verbose = false
    /// Lets bibi look (run read-only steps) in every case, not only the ones that ask for it.
    var look = false

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--filter": i += 1; filter = i < args.count ? args[i] : nil
            case "--json": json = true
            case "--verbose", "-v": verbose = true
            case "--look": look = true
            default: FileHandle.standardError.write(Data("bibi-eval: unknown option \(args[i])\n".utf8))
            }
            i += 1
        }
    }
}

/// What one case produced.
struct EvalResult: Codable {
    var request: String
    var tags: [String]
    var expect: [String]
    var proposed: [String]
    var pass: Bool
    var reply: String
    var calls: Int
    var seconds: Double
    var maxPromptChars: Int
    var maxTokens: Int
    var overflows: Int
    var notes: [String]
}

/// Collects what chat emits, as the web UI would see it.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [(String, String)] = []
    func add(_ t: String, _ m: String) { lock.withLock { items.append((t, m)) } }
    var messages: [ChatMessage] { lock.withLock { items.filter { $0.0 == "message" }.compactMap { try? JSON.decode(ChatMessage.self, from: $0.1) } } }
    var emit: ChatEmit { { [self] in add($0, $1) } }
}

struct Eval {
    let options: EvalOptions
    init(_ options: EvalOptions) { self.options = options }

    func run() async -> Int32 {
        if let why = FoundationModel.unavailableReason() {
            print("bibi-eval: the on-device model can't be used: \(why)")
            return 2
        }
        let cases = EvalCases.all.filter { c in options.filter.map { f in c.request.localizedCaseInsensitiveContains(f) || c.tags.contains(f) } ?? true }
        guard !cases.isEmpty else { print("bibi-eval: no case matches \(options.filter ?? "")"); return 2 }

        let home = Paths.bibiHome
        let graph: GraphStore
        do { graph = try GraphStore(path: home + "/bibi.db") } catch { print("bibi-eval: \(error)"); return 1 }
        let harness = Harness(skills: AllSkills.list, store: RunStore(root: home + "/runs"), graph: graph, apps: .system) { FoundationModel() }
        let chat = ChatEngine(harness: harness, graph: graph)
        print("bibi-eval: \(cases.count) case(s), model calls go to \(home)/runs/chat/<id>/model.jsonl\n")

        var results: [EvalResult] = []
        for c in cases {
            let r = await one(c, chat)
            results.append(r)
            print(line(r))
            if options.verbose {
                print("      reply: \(Text.oneLine(r.reply, max: 200))")
                for n in r.notes { print("      \(n)") }
            }
        }
        print("\n" + totals(results))
        let dir = FileManager.default.currentDirectoryPath + "/.build/eval"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/last.json"
        if let data = try? JSON.prettyEncoder.encode(results) {
            FileManager.default.createFile(atPath: path, contents: data)
            print("written \(path)")
        }
        if options.json, let data = try? JSON.prettyEncoder.encode(results), let s = String(data: data, encoding: .utf8) { print(s) }
        return results.allSatisfy(\.pass) ? 0 : 1
    }

    func one(_ c: EvalCase, _ chat: ChatEngine) async -> EvalResult {
        let events = Collected()
        var notes: [String] = []
        let start = Date()
        guard let run = try? chat.start() else {
            return EvalResult(request: c.request, tags: c.tags, expect: c.expect, proposed: [], pass: false, reply: "", calls: 0,
                              seconds: 0, maxPromptChars: 0, maxTokens: 0, overflows: 0, notes: ["could not start a chat"])
        }
        await chat.send(run, c.request, explore: c.explore, look: c.look || options.look, emit: events.emit)
        let seconds = Date().timeIntervalSince(start)

        // What ran or was proposed this turn, as step signatures, in order.
        let state = chat.state(run)
        let report = run.report()
        let ran = run.journalEntries.filter { $0.event == .executed }.compactMap(\.actionID)
        let open = report?.findings.first { $0.id == state.pending }?.recommendations ?? []
        let proposed = (ran.compactMap { id in report?.action(id) } + open).map { PlannedStep.from($0).signature }
        let reply = events.messages.last { $0.role == "bibi" }?.text ?? ""
        for m in events.messages where m.role == "note" { notes.append("note: " + Text.oneLine(m.text, max: 160)) }

        var pass = c.expect.allSatisfy(proposed.contains)
        if c.expect.isEmpty && !proposed.isEmpty { pass = false; notes.append("expected no steps") }
        if !c.answerHas.isEmpty, c.look || options.look, !c.answerHas.contains(where: { reply.localizedCaseInsensitiveContains($0) }) {
            pass = false; notes.append("answer lacks \(c.answerHas)")
        }
        let log = run.modelEntries
        return EvalResult(request: c.request, tags: c.tags, expect: c.expect, proposed: proposed, pass: pass, reply: reply,
                          calls: log.count, seconds: seconds, maxPromptChars: log.map(\.prompt.count).max() ?? 0,
                          maxTokens: log.compactMap(\.tokens).max() ?? 0, overflows: log.filter { $0.overflow == true }.count, notes: notes)
    }

    func line(_ r: EvalResult) -> String {
        let mark = r.pass ? "ok  " : "FAIL"
        let steps = r.proposed.isEmpty ? "(no steps)" : r.proposed.joined(separator: " ")
        return String(format: "%@ %5.1fs calls %2d tok %5d ovf %d  %@  | %@", mark, r.seconds, r.calls, r.maxTokens, r.overflows,
                      Text.clip(steps, max: 44).padding(toLength: 44, withPad: " ", startingAt: 0), Text.oneLine(r.request, max: 70))
    }

    func totals(_ rs: [EvalResult]) -> String {
        let n = max(1, rs.count), passed = rs.filter(\.pass).count
        let calls = Double(rs.map(\.calls).reduce(0, +)) / Double(n), secs = rs.map(\.seconds).reduce(0, +) / Double(n)
        return String(format: "pass %d/%d  calls/case %.1f  s/case %.1f  overflows %d  max tokens %d", passed, rs.count, calls, secs,
                      rs.map(\.overflows).reduce(0, +), rs.map(\.maxTokens).max() ?? 0)
    }
}
