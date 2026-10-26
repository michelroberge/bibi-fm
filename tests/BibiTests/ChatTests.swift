import BibiCore
import Foundation
import Testing

/// Answers each schema from its own queue (the last answer repeats), and records prompts by schema.
final class ScriptedModel: LanguageModel, @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [JSONValue]]
    private(set) var prompts: [String: [String]] = [:]

    init(_ queues: [String: [JSONValue]]) { self.queues = queues }

    func respond(_ prompt: String, instructions: String, schema: Schema) async throws -> JSONValue {
        try lock.withLock {
            prompts[schema.name, default: []].append(prompt)
            guard var q = queues[schema.name], let first = q.first else { throw LLMError("no answer for \(schema.name)") }
            if q.count > 1 { q.removeFirst() }
            queues[schema.name] = q
            return first
        }
    }

    func last(_ schema: String) -> String { lock.withLock { prompts[schema]?.last ?? "" } }
    func count(_ schema: String) -> Int { lock.withLock { prompts[schema]?.count ?? 0 } }
}

func turn(_ intent: String, reply: String, steps: [(String, [String])] = []) -> JSONValue {
    .object(["intent": .string(intent), "reply": .string(reply),
             "steps": .array(steps.map { .object(["tool": .string($0.0), "args": .strings($0.1), "purpose": .string("test")]) })])
}

let compactAnswer: JSONValue = .object(["summary": .string("The user checks things."),
                                        "facts": .array([.object(["subject": .string("greeting"), "statement": .string("The Mac says hello")])])])

final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [(String, String)] = []
    func add(_ t: String, _ m: String) { lock.withLock { items.append((t, m)) } }
    func of(_ type: String) -> [String] { lock.withLock { items.filter { $0.0 == type }.map(\.1) } }
    var emit: ChatEmit { { [self] in add($0, $1) } }
}

@Suite struct ChatTests {
    let tmp = tempDir()

    func engine(_ model: ScriptedModel, skills: [any Skill] = []) -> (ChatEngine, Harness, GraphStore) {
        let graph = try! GraphStore(path: tmp + "/bibi.db")
        let harness = Harness(skills: skills, store: RunStore(root: tmp + "/runs"), policy: testPolicy(), graph: graph) { model }
        return (ChatEngine(harness: harness, graph: graph, embedder: NoEmbedder()), harness, graph)
    }

    @Test func proposeApproveExecuteAnswer() async throws {
        let model = ScriptedModel([
            "ChatTurn": [turn("say hello", reply: "I'll run echo.", steps: [("command", ["echo", "hello from bibi"])])],
            "ChatAnswer": [turn("say hello", reply: "The Mac said: hello from bibi.")],
            "Compact": [compactAnswer],
        ])
        let (chat, _, graph) = engine(model)
        let run = try chat.start()
        let events = Events()
        await chat.send(run, "please say hello", emit: events.emit)

        let report = try #require(run.report())
        let action = try #require(report.findings.first?.recommendations.first)
        #expect(action.call.spec == "run_command" && action.kind == "read-only" && action.safety == 10)
        #expect(chat.state(run).pending == "F1")
        #expect(chat.state(run).title == "please say hello")
        #expect(graph.stats(GraphSync.root)["proposed"] == 1)

        let results = try await chat.decide(run, ChatDecision(approve: [action.id]), admin: RecordingAdminRunner(), emit: events.emit)
        #expect(results.first?.ok == true && results.first?.output == "hello from bibi")
        // The output is evidence in the report, the follow-up answered from it, and the intent learned what worked.
        #expect(run.report()?.observations.first?.text == "hello from bibi")
        #expect(model.last("ChatAnswer").contains("Results of the steps the user approved"))
        #expect(model.last("ChatAnswer").contains("hello from bibi"))
        let transcript = chat.transcript(run)
        #expect(transcript.map(\.role) == ["user", "bibi", "result", "bibi"])
        #expect(transcript.last?.text == "The Mac said: hello from bibi.")
        let intent = try #require(graph.node(chat.state(run).intent ?? ""))
        #expect(intent.props["outcome"]?.string == "ok")
        #expect(intent.props["signature"]?.string == "command:echo")
        #expect(graph.stats(GraphSync.root)["approved"] == 1 && graph.stats(GraphSync.root)["executed"] == 1)
        #expect(run.journalEntries.contains { $0.event == .executed && $0.frontend == "chat" })
        // Already-run actions can't run twice.
        await #expect(throws: ActionError.self) {
            try await chat.decide(run, ChatDecision(approve: [action.id]), admin: RecordingAdminRunner(), emit: events.emit)
        }
    }

    @Test func refusedStepsAreExplained() async throws {
        let model = ScriptedModel([
            "ChatTurn": [turn("delete logs", reply: "Deleting.",
                              steps: [("command", ["sh", "-c", "rm -rf /tmp/x"]), ("command", ["rm", tmp + "/gone"])])],
        ])
        let (chat, _, _) = engine(model)
        let run = try chat.start()
        let events = Events()
        try "x".write(toFile: tmp + "/gone", atomically: true, encoding: .utf8)
        await chat.send(run, "delete the logs", emit: events.emit)
        let actions = run.report()?.actions ?? []
        // The shell is refused; rm became a reversible trash_path.
        #expect(actions.map(\.call.spec) == ["trash_path"])
        #expect(actions.first?.reversible == true)
        #expect(chat.transcript(run).contains { $0.role == "note" && $0.text.contains("sh -c") })
    }

    @Test func skipWithReasonTunesGuidance() async throws {
        let model = ScriptedModel(["ChatTurn": [turn("show logs", reply: "Reading logs.",
                                                     steps: [("command", ["log", "show", "--last", "1m"])])]])
        let (chat, _, graph) = engine(model)
        let run = try chat.start()
        await chat.send(run, "what's in the logs", emit: Events().emit)
        let a = try #require(run.report()?.actions.first)
        let results = try await chat.decide(run, ChatDecision(approve: [], skip: [a.id], reason: "too slow, use --last 10s"),
                                            admin: RecordingAdminRunner(), emit: Events().emit)
        #expect(results.isEmpty)
        #expect(graph.stats(GraphSync.root)["skipped"] == 1)
        #expect(PromptBook(graph).text("skill.generic", default: "").contains("Avoid: too slow, use --last 10s"))
        #expect(chat.state(run).pending == nil)
        // The next turn's instructions carry the note.
        await chat.send(run, "again", emit: Events().emit)
        #expect(model.count("ChatTurn") == 2)
    }

    @Test func compactsLongConversations() async throws {
        let model = ScriptedModel(["ChatTurn": [turn("chat", reply: "ok")], "Compact": [compactAnswer]])
        let (chat, _, graph) = engine(model)
        let run = try chat.start()
        for i in 0..<4 { await chat.send(run, "message \(i): the Mac says hello", emit: Events().emit) }
        let state = chat.state(run)
        #expect(state.recent.count <= ChatEngine.keepMessages)
        #expect(state.summary == "The user checks things.")
        #expect(chat.transcript(run).count == 8)
        #expect(graph.nodes(kind: "fact").first?.text == "The Mac says hello")
        // The summary, not the old messages, goes to the model.
        #expect(model.last("ChatTurn").contains("The user checks things."))
        #expect(!model.last("ChatTurn").contains("message 0"))
    }

    @Test func repeatedRequestsBecomeASkill() async throws {
        let dirs = [tmp + "/a", tmp + "/b", tmp + "/c"]
        for d in dirs { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let model = ScriptedModel([
            "ChatTurn": dirs.map { d in turn("folder size", reply: "Measuring.", steps: [("command", ["du", "-sh", d])]) },
            "ChatAnswer": [turn("folder size", reply: "Done.")],
            "Compact": [compactAnswer],
            "SkillDraft": [.object(["name": .string("folder size"), "help": .string("Show how big a folder is.")])],
            "Summary": [.object(["summary": .string("It is small.")])],
        ])
        let (chat, harness, graph) = engine(model)
        let events = Events()
        for d in dirs {
            let run = try chat.start()
            await chat.send(run, "how big is the folder " + Paths.name(d), emit: events.emit)
            let a = try #require(run.report()?.actions.first)
            _ = try await chat.decide(run, ChatDecision(approve: [a.id]), admin: RecordingAdminRunner(), emit: events.emit)
        }
        let candidate = try #require(graph.nodes(kind: "skill", status: "candidate").first)
        #expect(candidate.name == "learned.folder-size")
        #expect(candidate.props["params"]?.strings == ["path"])
        #expect(events.of("candidate").count == 1)
        #expect(harness.skill(named: "learned.folder-size") == nil)

        // Accepting registers it; running it measures the folder given as --path.
        try SkillLibrary.decide(candidate.id, "accept", graph: graph, harness: harness)
        let skill = try #require(harness.skill(named: "learned.folder-size"))
        let (_, result) = try await harness.run(skill, argv: ["--path", dirs[0]], reporter: SilentReporter())
        #expect(result.observations.first?.source.contains(dirs[0]) == true)
        #expect(result.summary == "It is small.")

        // Dismissed or already-learned clusters aren't proposed again.
        try SkillLibrary.decide(candidate.id, "disable", graph: graph, harness: harness)
        #expect(harness.skill(named: "learned.folder-size") == nil)
        #expect(throws: ActionError.self) { try SkillLibrary.decide(candidate.id, "dismiss", graph: graph, harness: harness) }
    }

    @Test func learnedWriteStepsNeedApproval() async throws {
        let graph = try GraphStore(path: tmp + "/bibi.db")
        let steps = [PlannedStep(tool: "command", args: ["ls", "{path}"]), PlannedStep(tool: "command", args: ["touch", "{path}/new"])]
        graph.upsert(GraphNode(id: "skill:learned.touch", kind: "skill", name: "learned.touch", text: "Touch a file",
                               props: ["source": .string("learned"), "help": .string("Touch a file"), "params": .strings(["path"]),
                                       "steps": try JSON.decode(JSONValue.self, from: JSON.string(steps))]))
        let harness = Harness(skills: [], store: RunStore(root: tmp + "/runs"), policy: testPolicy(), graph: graph) {
            ScriptedModel(["Summary": [.object(["summary": .string("listed")])]])
        }
        let skill = try #require(harness.skill(named: "learned.touch"))
        let (_, result) = try await harness.run(skill, argv: ["--path", tmp], reporter: SilentReporter())
        #expect(result.observations.count == 1)
        #expect(result.actions.map(\.call.spec) == ["run_command"])
        #expect(!Paths.exists(tmp + "/new"))
    }

    @Test func builtinsAreInTheGraph() throws {
        let graph = try GraphStore(path: tmp + "/bibi.db")
        _ = Harness(skills: [FakeSkill(file: "/x")], store: RunStore(root: tmp + "/runs"), graph: graph) { FakeModel() }
        #expect(graph.node("skill:test.fake")?.props["source"]?.string == "builtin")
        #expect(graph.neighbors("skill:test.fake", kind: "child_of", depth: 2).map(\.id) == ["skill:test", "skill:generic"])
        #expect(graph.node("action:run_command") != nil)
        // A skill that disappears is retired, not deleted.
        _ = Harness(skills: [], store: RunStore(root: tmp + "/runs"), graph: graph) { FakeModel() }
        #expect(graph.node("skill:test.fake")?.status == "retired")
    }

    @Test func searchAndDelete() async throws {
        let model = ScriptedModel(["ChatTurn": [turn("chat", reply: "The firewall question is noted.")], "Compact": [compactAnswer]])
        let (chat, harness, graph) = engine(model)
        let a = try chat.start(), b = try chat.start()
        await chat.send(a, "is my firewall on?", emit: Events().emit)
        await chat.send(b, "how much disk space is free", emit: Events().emit)
        #expect(Set(chat.search("firewall").map(\.run.id)) == [a.id, b.id])  // b's reply mentions it too
        #expect(chat.search("DISK free").map(\.run.id) == [b.id])
        #expect(chat.search("disk").first?.snippet?.contains("disk space") == true)
        #expect(chat.search("").count == 2)

        let intents = graph.nodes(kind: "intent").filter { $0.props["seed"] == nil }.count
        try chat.delete(a)
        #expect(harness.store.find(a.id) == nil)
        #expect(graph.node("conversation:" + a.id) == nil)
        #expect(chat.conversations().map(\.id) == [b.id])
        // What bibi learned stays.
        #expect(graph.nodes(kind: "intent").filter { $0.props["seed"] == nil }.count == intents)
        #expect(throws: ActionError.self) { try chat.delete(try #require(harness.store.list(skill: "chat").first.map { _ in
            try harness.store.create(skill: "storage.optimize", args: [], online: false, version: "t") })) }
    }
}

