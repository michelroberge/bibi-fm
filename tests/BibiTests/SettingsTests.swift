@testable import BibiCore
@testable import BibiWeb
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@Suite struct SettingsTests {
    let tmp = tempDir()

    func setup(_ model: ScriptedModel = ScriptedModel([:]), db: String = "/bibi.db") -> (Settings, ChatEngine, GraphStore) {
        let graph = try! GraphStore(path: tmp + db)
        let harness = Harness(skills: [], store: RunStore(root: tmp + "/runs"), policy: testPolicy(), graph: graph, apps: testApps(tmp)) { model }
        return (Settings(graph: graph, harness: harness), ChatEngine(harness: harness, graph: graph, embedder: NoEmbedder()), graph)
    }

    // MARK: knobs

    @Test func knobsAreBuiltInUntilOverridden() throws {
        #expect(Knobs(nil)[.chatBudget] == 6000)
        let (s, _, graph) = setup()
        let knobs = Knobs(graph)
        #expect(knobs.override(.chatBudget) == nil)
        try s.setKnob("chat.budget", 3000)
        #expect(knobs.int(.chatBudget) == 3000)
        try s.setKnob("chat.budget", 1)  // clamped to the minimum
        #expect(knobs.int(.chatBudget) == 1500)
        try s.setKnob("chat.budget", 6000)  // the built-in value is no override
        #expect(knobs.override(.chatBudget) == nil)
        try s.setKnob("chat.repairs", 1)
        // Overrides survive reopening the database.
        #expect(Knobs(try GraphStore(path: tmp + "/bibi.db")).int(.repairCount) == 1)
        #expect(throws: ActionError.self) { try s.setKnob("no.such.knob", 1) }
        #expect(Set(Knob.all.map(\.id)).count == Knob.all.count)
    }

    @Test func settingsTableIsAddedToAnExistingDatabase() throws {
        let path = tmp + "/old.db"
        let old = try SQLiteDB(path: path)
        try old.migrate([GraphStore.migrations[0]])
        try old.query("INSERT INTO nodes(id, kind, name, created, updated) VALUES('fact:x', 'fact', 'x', 0, 0)")
        let graph = try GraphStore(path: path)
        #expect(graph.node("fact:x") != nil)
        graph.setSetting("knob.chat.budget", .number(2000))
        #expect(Knobs(graph).int(.chatBudget) == 2000)
    }

    @Test func chatUsesTheKnobs() async throws {
        // A refused command: the model gets `chat.repairs` more tries.
        let model = ScriptedModel(["ChatTurn": [turn("run a script", reply: "Running it.", steps: [("command", ["sh", "-c", "ls"])])],
                                   "Fallback": [.object(["reply": .string("no")])], "Compact": [compactAnswer]])
        let (s, chat, _) = setup(model)
        try s.setKnob("chat.repairs", 0)
        await chat.send(try chat.start(), "run my script", emit: Events().emit)
        #expect(model.count("ChatTurn") == 1)

        try s.setKnob("chat.budget", 1500)
        let dry = await chat.dryTurn("how much free disk space", askModel: false)
        #expect(dry.budget == 1500)
    }

    // MARK: prompts

    @Test func overridesKeepTheirTextAndSayWhenTheBuiltInMoved() throws {
        let (_, _, graph) = setup()
        let book = PromptBook(graph)
        #expect(book.text("x", default: "built-in A") == "built-in A")
        #expect(!book.state("x", builtIn: "built-in A").overridden)

        let mine = book.override("x", text: "mine", builtIn: "built-in A")
        #expect(book.state("x", builtIn: "built-in A").overridden)
        #expect(!book.state("x", builtIn: "built-in A").stale)
        // The code's text changes: the override stays, and is flagged.
        #expect(book.text("x", default: "built-in B") == "mine")
        #expect(book.state("x", builtIn: "built-in B").stale)

        book.revert("x", builtIn: "built-in B")
        #expect(!book.state("x", builtIn: "built-in B").overridden)
        #expect(book.text("x", default: "built-in B") == "built-in B")

        try book.activate("x", version: mine)
        #expect(book.text("x", default: "built-in B") == "mine")
        #expect(book.history("x").filter(\.active).map(\.id) == [mine])
        #expect(throws: ActionError.self) { try book.activate("x", version: "prompt:y@1") }
        // Saving the built-in text is reverting.
        book.override("x", text: "built-in B", builtIn: "built-in B")
        #expect(!book.state("x", builtIn: "built-in B").overridden)
    }

    @Test func everyPromptIsListedOnce() throws {
        let (s, _, _) = setup()
        let ids = s.harness.promptCatalog.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("chat.system") && ids.contains("chat.extract") && ids.contains("skill.generic"))
        #expect(PromptCatalog.core.allSatisfy { !$0.builtIn.isEmpty })
        let p = try s.savePrompt("chat.fallback", text: "Answer in one sentence.")
        #expect(p.overridden && p.versions?.count == 1)
        #expect(s.overview().prompts == 1)
        #expect(try !s.revertPrompt("chat.fallback").overridden)
    }

    // MARK: tools and policy

    @Test func userCommandListsNeverUnlockBibisRules() {
        var policy = testPolicy()
        policy.allowCommands = ["frobnicate", "rm", "sh"]
        policy.blockCommands = ["ls"]
        let classify = { CommandPolicy.classify($0, policy: policy, exists: { _ in true }) }
        #expect(classify(["frobnicate", "-v"]).cls == .readOnly)
        #expect(classify(["frobnicate", "|", "grep", "x"]).refusal != nil)
        #expect(classify(["sh", "-c", "ls"]).refusal != nil)
        #expect(classify(["rm", "/tmp/x"]).rewrite.first?.spec == "trash_path")
        #expect(classify(["ls", "-la"]).refusal?.contains("blocked") == true)
        #expect(CommandPolicy.notAllowable("rm") != nil && CommandPolicy.notAllowable("python3") != nil)
        #expect(CommandPolicy.notAllowable("ioreg") == nil)
    }

    @Test func settingsRefusesToAllowCommandsThatChangeThings() throws {
        let (s, _, _) = setup()
        #expect(throws: ActionError.self) { try s.setPolicy(allow: ["mv"], block: []) }
        try s.setPolicy(allow: ["frobnicate"], block: ["ls"])
        #expect(s.harness.policy.allowCommands == ["frobnicate"])
        #expect(s.checkCommand("ls -la").refusal != nil)
        #expect(s.checkCommand("df -h '/Volumes/My Disk'").argv == ["df", "-h", "/Volumes/My Disk"])
    }

    @Test func aTurnedOffActionIsNeitherOfferedNorRun() async throws {
        let (s, chat, _) = setup()
        #expect(chat.retrieval("open the app Safari").tools.contains("action:open_app"))
        try s.setAction("open_app", enabled: false)
        #expect(!chat.retrieval("open the app Safari").tools.contains("action:open_app"))
        let plan = await chat.bind([PlannedStep(tool: "action:open_app", args: ["app=Safari"])], run: nil, said: "Safari", request: "open Safari")
        #expect(plan.actions.isEmpty)
        #expect(plan.refusals.first?.contains("turned off") == true)
    }

    // MARK: test bench

    @Test func theTestBenchSavesNothing() async throws {
        let model = ScriptedModel(["ChatTurn": [turn("check free space", reply: "Checking.", steps: [("command", ["df", "-h", "/"])])]])
        let (s, chat, graph) = setup(model)
        let intents = graph.nodes(kind: "intent").count, events = graph.eventCount()
        let r = await chat.dryTurn("how much free disk space do I have?", askModel: true)
        #expect(r.error == nil)
        #expect(r.steps?.count == 1)
        #expect(r.sections.contains { $0.title == "Tools" })
        #expect(r.prompt.contains("how much free disk space"))
        #expect(r.tokens.total > 0)
        #expect(graph.nodes(kind: "intent").count == intents)
        // Only the built-in prompt versions a first read creates (as any turn would); nothing about the request.
        #expect(graph.events(limit: 50).filter { $0.kind != "revised" }.count == events)
        #expect(s.harness.store.list().isEmpty)
    }

    // MARK: cleanup, backups, export

    @Test func cleanupCountsWhatItRemovesAndKeepsBuiltIns() throws {
        let (s, _, graph) = setup()
        try s.saveFact(id: nil, subject: "backup disk", statement: "Time Machine uses Vault")
        try s.setKnob("chat.budget", 3000)
        try s.savePrompt("chat.fallback", text: "Short answers.")
        try s.setAction("open_url", enabled: false)
        try s.createSkill(name: "free space", help: "Shows free space", keywords: "space", params: [],
                          steps: [PlannedStep(tool: "command", args: ["df", "-h", "/"])])
        let seeds = graph.nodes(kind: "intent").filter { $0.props["seed"] != nil }.count
        #expect(seeds > 0)
        for op in CleanupOp.allCases where op != .factory {
            let dry = s.cleanup(op, dryRun: true)
            #expect(s.cleanup(op, dryRun: false).count == dry.count, "\(op)")
            #expect(s.cleanup(op, dryRun: true).count == 0 || op == .statistics || op == .promptHistory, "\(op) left something")
        }
        #expect(s.overview().total == 0)
        #expect(graph.nodes(kind: "intent").filter { $0.props["seed"] != nil }.count == seeds)
        #expect(s.harness.skill(named: "learned.free-space") == nil)

        _ = s.cleanup(.factory, dryRun: false)
        #expect(graph.node(GraphSync.root) != nil)
        #expect(graph.nodes(kind: "intent").filter { $0.props["seed"] != nil }.count == seeds)
        #expect(graph.node("action:open_url") != nil)
    }

    @Test func backupAndRestoreRoundTrip() throws {
        let (s, _, graph) = setup()
        try s.setKnob("chat.budget", 3000)
        let b = try s.backup()
        try s.setKnob("chat.budget", nil)
        #expect(Knobs(graph).override(.chatBudget) == nil)
        try s.restore(b.name)
        #expect(Knobs(graph).int(.chatBudget) == 3000)
        #expect(s.backups().count == 2)  // the restored one and the safety copy taken before restoring
        #expect(throws: ActionError.self) { try s.restore("../bibi.db") }
    }

    @Test func anExportHoldsOnlyOverridesAndReproducesThem() throws {
        let (a, _, _) = setup()
        try a.setKnob("retrieval.skills", 2)
        try a.savePrompt("chat.translate", text: "Translate to English.")
        try a.setPolicy(allow: ["frobnicate"], block: [])
        try a.setAction("open_url", enabled: false)
        try a.saveFact(id: nil, subject: "home", statement: "The office is upstairs")
        let file = a.export(learned: true)
        #expect(file["knobs"]?.object?.keys.sorted() == ["retrieval.skills"])
        #expect(file["prompts"]?.object?.keys.sorted() == ["chat.translate"])

        let (b, _, graph) = setup(db: "/other.db")
        let r = try b.importOverrides(file)
        #expect(r.knobs == 1 && r.prompts == 1 && r.nodes == 1)
        #expect(Knobs(graph).int(.rankSkills) == 2)
        #expect(try b.prompt("chat.translate").text == "Translate to English.")
        #expect(b.policy().allow == ["frobnicate"])
        #expect(graph.node("action:open_url")?.status == "disabled")
        #expect(b.overview().total == a.overview().total)
        #expect(throws: ActionError.self) { try b.importOverrides(.object([:])) }
    }

    // MARK: web

    static let auth: HTTPFields = [HTTPField.Name("X-Bibi-Token")!: "secret", .contentType: "application/json"]

    @Test func settingsRoutes() async throws {
        let graph = try GraphStore(path: tmp + "/web.db")
        let harness = Harness(skills: [], store: RunStore(root: tmp + "/runs"), policy: testPolicy(), graph: graph, apps: testApps(tmp)) {
            ScriptedModel(["Fallback": [.object(["reply": .string("hi")])]])
        }
        let router = WebServer(harness: harness, token: "secret").makeRouter(manager: RunManager(harness: harness))
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        try await app.test(.live) { client in
            func call(_ uri: String, _ method: HTTPRequest.Method = .get, _ body: String? = nil) async throws -> (HTTPResponse.Status, JSONValue) {
                try await client.execute(uri: uri, method: method, headers: Self.auth, body: body.map { ByteBuffer(string: $0) }) { r in
                    (r.status, (try? JSON.decoder.decode(JSONValue.self, from: Data(r.body.readableBytesView))) ?? .null)
                }
            }
            #expect(try await call("/api/settings/overview").0 == .ok)
            let knobs = try await call("/api/settings/knobs", .post, #"{"id":"chat.budget","value":2500}"#)
            #expect(knobs.1.array?.first { $0["knob"]?["id"]?.string == "chat.budget" }?["overridden"] == .bool(true))
            #expect(try await call("/api/settings/knobs", .post, #"{"id":"nope","value":1}"#).0 == .badRequest)
            let tried = try await call("/api/settings/prompts/chat.fallback/try", .post, #"{"text":"Be brief.","input":"hello"}"#)
            #expect(tried.1["answer"]?["reply"]?.string == "hi")
            #expect(try await call("/api/settings/prompts/chat.repair/try", .post, #"{"input":"x"}"#).0 == .badRequest)
            let bench = try await call("/api/settings/test", .post, #"{"request":"free disk space"}"#)
            #expect(bench.1["tools"]?.array?.isEmpty == false)
            let check = try await call("/api/settings/policy/test", .post, #"{"command":"ls | grep x"}"#)
            #expect(check.1["refusal"] != nil && check.1["refusal"] != .null)
            let cleanup = try await call("/api/settings/cleanup/knobs", .post, "{}")
            #expect(cleanup.1["count"] == .number(1))
            #expect(cleanup.1["backup"]?.string?.hasPrefix("bibi-") == true)
            #expect(try await call("/api/settings/cleanup/nope", .post, "{}").0 == .notFound)
            #expect(try await call("/api/diff?skill=x").0 == .notFound)
        }
    }
}
