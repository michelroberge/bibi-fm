import BibiCore
import Foundation
import Testing

/// A built-in skill chat matches on its keywords.
struct DiskSkill: Skill {
    let name = "test.disk"
    let help = "Checks the drive"
    var keywords: String { "storage" }
    var params: [Param] { [] }
    func run(_ args: Args, _ ctx: SkillContext) async throws -> SkillResult { SkillResult(summary: "ok") }
}

func draft(_ steps: [(String, [String])], params: [String] = []) -> JSONValue {
    .object(["name": .string("folder size"), "help": .string("Shows how big a folder is."), "keywords": .string("folder size big"),
             "params": .strings(params),
             "steps": .array(steps.map { .object(["tool": .string($0.0), "args": .strings($0.1), "purpose": .string("test")]) })])
}

@Suite struct TuningTests {
    let tmp = tempDir()

    func setup(_ model: ScriptedModel = ScriptedModel([:])) -> (GraphTuning, ChatEngine, Harness, GraphStore) {
        let graph = try! GraphStore(path: tmp + "/bibi.db")
        let harness = Harness(skills: [DiskSkill()], store: RunStore(root: tmp + "/runs"), policy: testPolicy(), graph: graph,
                              apps: testApps(tmp)) { model }
        return (GraphTuning(graph: graph, harness: harness), ChatEngine(harness: harness, graph: graph, embedder: NoEmbedder()), harness, graph)
    }

    @Test func overridesSurviveSyncAndReset() throws {
        let (tuning, chat, _, graph) = setup()
        #expect(chat.retrieval("storage usage").skills == ["test.disk"])
        let v = try tuning.override("test.disk", keywords: "space left")
        #expect(v.keywords == "space left" && v.defaultKeywords == "storage" && v.tuned == ["keywords"])
        #expect(chat.retrieval("how much space left").skills == ["test.disk"])
        #expect(chat.retrieval("storage usage").skills.isEmpty)

        // bibi starting again re-syncs the code's keywords as the default; the override stays.
        _ = Harness(skills: [DiskSkill()], store: RunStore(root: tmp + "/runs"), graph: graph) { FakeModel() }
        let node = try #require(graph.node("skill:test.disk"))
        #expect(GraphSync.keywords(node) == "space left" && node.props["keywords"]?.string == "storage")

        let reset = try tuning.override("test.disk", keywords: "")
        #expect(reset.keywords == "storage" && reset.tuned.isEmpty)
        #expect(graph.stats("skill:test.disk")["tuned"] == 2)
    }

    @Test func disabledExamplesAreLeftOut() throws {
        let (tuning, chat, _, graph) = setup()
        let seed = try #require(graph.nodes(kind: "intent").first { $0.text == "free up disk space" })
        #expect(chat.retrieval("free up disk space").examples.contains(seed.id))
        try tuning.updateExample("generic", id: seed.id, text: "free up space on the disk", status: "disabled")
        #expect(!chat.retrieval("free up disk space").examples.contains(seed.id))
        // A seed's edits are overrides, and stay when the seeds are synced again.
        _ = Harness(skills: [DiskSkill()], store: RunStore(root: tmp + "/runs"), graph: graph) { FakeModel() }
        let again = try #require(graph.node(seed.id))
        #expect(again.status == "disabled" && again.text == "free up disk space" && GraphSync.text(again) == "free up space on the disk")
    }

    @Test func manualAndLearnedExamples() throws {
        let (tuning, chat, _, graph) = setup()
        let v = try tuning.addExample("test.disk", text: "how full is my drive", steps: [PlannedStep(tool: "skill:test.disk", args: [])])
        let manual = try #require(v.examples.first { $0.source == "manual" })
        #expect(manual.weight == 1)
        #expect(chat.retrieval("how full is my drive").examples == [manual.id])
        // Manual examples teach retrieval, never the miner.
        #expect(SkillMiner(graph: graph, model: FakeModel(), prompts: PromptBook(graph)).cluster(for: try #require(graph.node(manual.id))).isEmpty)
        #expect(throws: ActionError.self) { try tuning.addExample("test.disk", text: "x", steps: [PlannedStep(tool: "shell", args: ["ls"])]) }

        graph.upsert(GraphNode(id: "intent:asked", kind: "intent", name: "is the drive full", text: "is the drive full",
                               props: ["outcome": .string("ok")]))
        graph.link("skill:test.disk", "intent:asked", "example")
        graph.link("intent:asked", "skill:test.disk", "matched", weight: 3)
        #expect(try tuning.view("test.disk").examples.first?.id == "intent:asked")  // most matched first

        try tuning.removeExample("test.disk", id: "intent:asked")
        let after = try tuning.removeExample("test.disk", id: manual.id)
        #expect(after.examples.isEmpty)
        #expect(graph.node(manual.id) == nil)
        #expect(graph.node("intent:asked") != nil && graph.edges(from: "intent:asked", kind: "matched").isEmpty)
    }

    @Test func stepsAreChecked() throws {
        let (tuning, _, harness, graph) = setup()
        let problem = { (s: PlannedStep, p: [String]) in
            GraphTuning.problem(s, params: p, registry: harness.registry, policy: harness.policy, graph: graph)
        }
        #expect(problem(PlannedStep(tool: "command", args: ["du", "-sh", "{path}"]), ["path"]) == nil)
        #expect(problem(PlannedStep(tool: "command", args: ["du", "-sh", "{path}"]), [])?.contains("{path} isn't a parameter") == true)
        #expect(problem(PlannedStep(tool: "command", args: ["sh", "-c", "ls"]), []) != nil)
        #expect(problem(PlannedStep(tool: "action:nope", args: []), [])?.contains("no such action") == true)
        #expect(problem(PlannedStep(tool: "skill:test.disk", args: []), []) == nil)
        #expect(problem(PlannedStep(tool: "shell", args: ["ls"]), [])?.contains("unknown tool") == true)
        #expect(throws: ActionError.self) { try tuning.setSteps("test.disk", steps: [PlannedStep(tool: "command", args: ["ls"])], params: []) }
    }

    @Test func advancedEditorGuardsWhatBibiRebuilds() throws {
        let (tuning, _, _, graph) = setup()
        #expect(throws: ActionError.self) { try tuning.updateNode("skill:test.disk", props: [:]) }
        #expect(try tuning.updateNode("skill:test.disk", status: "disabled").node.status == "disabled")
        #expect(throws: ActionError.self) { try tuning.updateNode(GraphSync.root, status: "disabled") }
        #expect(throws: ActionError.self) { try tuning.deleteNode(GraphSync.root) }
        #expect(throws: ActionError.self) { try tuning.deleteNode("skill:test") }
        #expect(throws: ActionError.self) { try tuning.edge("skill:test.disk", "skill:test", "likes", weight: nil, remove: false) }

        graph.upsert(GraphNode(id: "fact:a", kind: "fact", name: "disk", text: "The disk is 1 TB"))
        try tuning.updateNode("fact:a", text: "The disk is 2 TB")
        #expect(graph.node("fact:a")?.text == "The disk is 2 TB")
        try tuning.edge("fact:a", "skill:test.disk", "from", weight: 4, remove: false)
        #expect(try tuning.node("fact:a").out.map(\.weight) == [4])
        try tuning.edge("fact:a", "skill:test.disk", "from", weight: nil, remove: true)
        try tuning.deleteNode("fact:a")
        #expect(graph.node("fact:a") == nil)

        // A prompt's text becomes a new version, so it can still be rolled back.
        let book = PromptBook(graph)
        _ = book.text("test.prompt", default: "Be brief.")
        try tuning.updateNode("prompt:test.prompt", text: "Be very brief.")
        #expect(book.versions("test.prompt").count == 2 && book.text("test.prompt", default: "Be brief.") == "Be very brief.")
    }

    @Test func describedSkillBecomesACandidate() async throws {
        let model = ScriptedModel(["SkillDraft": [draft([("command", ["du", "-sh", "{path}"]), ("shell", ["ls"]),
                                                          ("command", ["sh", "-c", "ls"])], params: ["path", "unused"])]])
        let (_, _, harness, graph) = setup(model)
        let author = try #require(harness.skill(named: "skills.create"))
        let (_, result) = try await harness.run(author, argv: ["show", "how", "big", "a", "folder", "is"], reporter: SilentReporter())
        #expect(model.last("SkillDraft").contains("The user wants a skill that: show how big a folder is"))
        let id = try #require(result.facts["candidate"]?.string)
        let node = try #require(graph.node(id))
        #expect(node.status == "candidate" && node.name == "learned.folder-size" && node.props["origin"]?.string == "described")
        #expect(SkillMiner.steps(node) == [PlannedStep(tool: "command", args: ["du", "-sh", "{path}"], purpose: "test")])
        #expect(node.props["params"]?.strings == ["path"])
        #expect(result.notes.count == 2)
        // Nothing runs until the user keeps it.
        #expect(harness.skill(named: "learned.folder-size") == nil)
        try SkillLibrary.decide(id, "accept", graph: graph, harness: harness)
        #expect(harness.skill(named: "learned.folder-size")?.params.map(\.key) == ["path"])
    }

    @Test func nothingUsableOrADryRunSavesNothing() async throws {
        let model = ScriptedModel(["SkillDraft": [draft([("shell", ["ls"])]), draft([("command", ["df", "-h"])])]])
        let (_, _, harness, graph) = setup(model)
        let author = try #require(harness.skill(named: "skills.create"))
        let (_, bad) = try await harness.run(author, argv: ["anything"], reporter: SilentReporter())
        #expect(bad.facts["candidate"] == nil && bad.findings.first?.title == "No skill drafted")
        let (_, dry) = try await harness.run(author, argv: ["free", "space"], reporter: SilentReporter(), options: RunOptions(dryRun: true))
        #expect(dry.facts["candidate"] == nil && dry.findings.first?.title == "Drafted skill: folder size")
        #expect(!graph.nodes(kind: "skill").contains { $0.props["source"]?.string == "learned" })
    }

    @Test func chatShowsTheDraftedSkillsCard() async throws {
        let model = ScriptedModel([
            "ChatTurn": [turn("create a skill", reply: "I'll draft it.", steps: [("skill:skills.create", ["show how big a folder is"])])],
            "ChatAnswer": [turn("create a skill", reply: "Drafted folder size.")],
            "SkillDraft": [draft([("command", ["du", "-sh", "{path}"])], params: ["path"])],
            "Compact": [compactAnswer],
        ])
        let (_, chat, _, _) = setup(model)
        let run = try chat.start()
        let events = Events()
        await chat.send(run, "create a skill that shows how big a folder is", emit: events.emit)
        let action = try #require(run.report()?.findings.first?.recommendations.first)
        #expect(action.call.params["skill"] == "skills.create")
        _ = try await chat.decide(run, ChatDecision(approve: [action.id]), admin: RecordingAdminRunner(), emit: events.emit)
        #expect(chat.state(run).candidates == ["skill:learned.folder-size"])
        #expect(events.of("candidate").count == 1)
    }
}
