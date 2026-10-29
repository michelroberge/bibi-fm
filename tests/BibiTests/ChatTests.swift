import BibiCore
import BibiSkills
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

func next(done: Bool = false, steps: [(String, [String])] = [], reply: String = "") -> JSONValue {
    .object(["done": .bool(done), "reply": .string(reply),
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
        let harness = Harness(skills: skills, store: RunStore(root: tmp + "/runs"), policy: testPolicy(), graph: graph,
                              apps: testApps(tmp)) { model }
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
        // A short output is one note as it is; the model answers from the notes, not the raw output.
        #expect(model.last("ChatAnswer").contains("What the steps found"))
        #expect(model.last("ChatAnswer").contains("hello from bibi"))
        #expect(chat.state(run).notes?.map(\.text) == ["hello from bibi"])
        #expect(graph.stats(GraphSync.root)["auto"] == nil)
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

    @Test func longOutputsBecomeGroundedNotes() async throws {
        let long = (1...120).map { "w\($0)" }.joined(separator: " ")
        let model = ScriptedModel([
            "ChatTurn": [turn("print", reply: "Printing.", steps: [("command", ["echo", long])])],
            // One line is in the output; the other is the model's invention.
            "Extract": [.object(["lines": .strings(["w7 w8 w9", "the output has 999 words"])])],
            "ChatAnswer": [turn("print", reply: "Done.")],
            "Compact": [compactAnswer],
        ])
        let (chat, _, _) = engine(model)
        let run = try chat.start()
        await chat.send(run, "print the words", emit: Events().emit)
        let a = try #require(run.report()?.actions.first)
        _ = try await chat.decide(run, ChatDecision(approve: [a.id]), admin: RecordingAdminRunner(), emit: Events().emit)
        #expect(model.count("Extract") == 1)
        #expect(chat.state(run).notes?.map(\.text) == ["w7 w8 w9"])
        let prompt = model.last("ChatAnswer")
        // The notes carry the line; the raw output only reaches the model clipped (its start and end), never whole.
        #expect(prompt.contains("What the steps found") && prompt.contains("w7 w8 w9") && !prompt.contains("w60 w61 w62"))
        // The whole output is still in the transcript.
        #expect(chat.transcript(run).contains { $0.role == "result" && $0.text.contains("w120") })
    }

    @Test func lookRunsReadOnlyStepsUntilItCanAnswer() async throws {
        let model = ScriptedModel([
            "ChatTurn": [turn("check", reply: "Checking.", steps: [("command", ["echo", "first"])])],
            "Next": [next(steps: [("command", ["echo", "second"])]), next(done: true)],
            "ChatAnswer": [turn("check", reply: "first and second.")],
            "Compact": [compactAnswer],
        ])
        let (chat, _, graph) = engine(model)
        let run = try chat.start()
        await chat.send(run, "check first and second", look: true, emit: Events().emit)
        // Both steps ran without a card; the answer came from both; bibi's own approvals aren't the user's.
        #expect(run.journalEntries.filter { $0.event == .executed }.count == 2)
        #expect(chat.state(run).pending == nil)
        #expect(chat.transcript(run).map(\.role) == ["user", "bibi", "result", "result", "bibi"])
        #expect(chat.transcript(run).last?.text == "first and second.")
        #expect(model.count("Next") == 2 && model.count("ChatAnswer") == 1)
        #expect(model.last("ChatAnswer").contains("first") && model.last("ChatAnswer").contains("second"))
        #expect(model.last("Next").contains("What the steps found") && model.last("Next").contains("first"))
        #expect(graph.stats(GraphSync.root)["auto"] == 2 && graph.stats(GraphSync.root)["approved"] == nil)
        let intent = try #require(graph.node(chat.state(run).intent ?? ""))
        #expect(intent.props["signature"]?.string == "command:echo>command:echo")
    }

    @Test func lookStopsAtAStepThatChangesTheMac() async throws {
        try "x".write(toFile: tmp + "/gone", atomically: true, encoding: .utf8)
        let model = ScriptedModel([
            "ChatTurn": [turn("check", reply: "Checking.", steps: [("command", ["echo", "first"])])],
            "Next": [next(steps: [("command", ["rm", tmp + "/gone"])], reply: "Then I'd remove it.")],
            "ChatAnswer": [turn("check", reply: "never")],
            "Compact": [compactAnswer],
        ])
        let (chat, _, _) = engine(model)
        let run = try chat.start()
        await chat.send(run, "check and clean", look: true, emit: Events().emit)
        #expect(run.journalEntries.filter { $0.event == .executed }.count == 1)
        let pending = try #require(chat.state(run).pending)
        let card = run.report()?.findings.first { $0.id == pending }?.recommendations ?? []
        #expect(card.map(\.call.spec) == ["trash_path"])
        #expect(chat.transcript(run).last?.text == "Then I'd remove it.")
        #expect(model.count("ChatAnswer") == 0)
        #expect(FileManager.default.fileExists(atPath: tmp + "/gone"))
        // The user decides; the answer follows.
        _ = try await chat.decide(run, ChatDecision(approve: [], skip: card.map(\.id)), admin: RecordingAdminRunner(), emit: Events().emit)
        #expect(chat.state(run).pending == nil)
    }

    @Test func lookNeverRepeatsAStepAndStopsAtTheCap() async throws {
        let model = ScriptedModel([
            "ChatTurn": [turn("check", reply: "Checking.", steps: [("command", ["echo", "one"])])],
            "Next": [next(steps: [("command", ["uname"])]), next(steps: [("command", ["hostname"])]),
                     next(steps: [("command", ["whoami"])]), next(steps: [("command", ["date"])])],
            "ChatAnswer": [turn("check", reply: "done")],
            "Compact": [compactAnswer],
        ])
        let (chat, _, _) = engine(model)
        let run = try chat.start()
        await chat.send(run, "check everything", look: true, emit: Events().emit)
        // Three rounds at most, then the answer.
        #expect(run.journalEntries.filter { $0.event == .executed }.count == 4)
        #expect(model.count("Next") == 3 && model.count("ChatAnswer") == 1)

        let again = ScriptedModel([
            "ChatTurn": [turn("check", reply: "Checking.", steps: [("command", ["echo", "one"])])],
            "Next": [next(steps: [("command", ["echo", "one"])])],
            "ChatAnswer": [turn("check", reply: "done")],
            "Compact": [compactAnswer],
        ])
        let (chat2, _, _) = engine(again)
        let run2 = try chat2.start()
        await chat2.send(run2, "check it", look: true, emit: Events().emit)
        // The same step again adds nothing: the loop ends and bibi answers.
        #expect(run2.journalEntries.filter { $0.event == .executed }.count == 1)
        #expect(again.count("Next") == 1 && again.count("ChatAnswer") == 1)

        let flags = ScriptedModel([
            "ChatTurn": [turn("check", reply: "Checking.", steps: [("command", ["echo", "one"])])],
            "Next": [next(steps: [("command", ["echo", "two"])]), next(steps: [("command", ["echo", "three"])])],
            "ChatAnswer": [turn("check", reply: "done")],
            "Compact": [compactAnswer],
        ])
        let (chat3, _, _) = engine(flags)
        let run3 = try chat3.start()
        await chat3.send(run3, "check it", look: true, emit: Events().emit)
        // The same program with new arguments runs twice at most: a small model re-runs ps forever otherwise.
        #expect(run3.journalEntries.filter { $0.event == .executed }.count == 2)
        #expect(flags.count("Next") == 2 && flags.count("ChatAnswer") == 1)
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
        let harness = Harness(skills: [], store: RunStore(root: tmp + "/runs"), policy: testPolicy(), graph: graph, apps: testApps(tmp)) {
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

    @Test func unaskedLeftoversAreRepairedNotProposed() async throws {
        let model = ScriptedModel(["ChatTurn": [
            turn("send email", reply: "Email sent.", steps: [("action:mail_send", ["mail", "-s \"Repo\"", "to=bob@example.com"]),
                                                             ("action:reveal", ["path=" + tmp])]),
            turn("send email", reply: "What should the email say?"),
        ]])
        let (chat, _, graph) = engine(model)
        // A past request sharing one word that answered with a step this request's words don't select.
        graph.upsert(GraphNode(id: "intent:old", kind: "intent", name: "copy paste", text: "why does copy paste fail in cockpit",
                               props: ["outcome": .string("ok"), "steps": .array([.object(["tool": .string("action:reveal"),
                                                                                              "args": .strings(["path=" + tmp])])])]))
        let run = try chat.start()
        await chat.send(run, "send an email to bob@example.com about the cockpit repo", emit: Events().emit)
        #expect(!model.last("ChatTurn").contains("why does copy paste"))
        #expect(model.count("Translate") == 0)
        // The email step was refused; the reveal alone isn't proposed: the model gets to repair the email instead.
        #expect(run.report()?.actions.isEmpty ?? true)
        #expect(model.count("ChatTurn") == 2)
        #expect(model.last("ChatTurn").contains("reveal: not part of this request"))
    }

    @Test func requestsAreNotRememberedAsDone() async throws {
        let claim: JSONValue = .object(["summary": .string("An email was sent."), "facts": .array([
            .object(["subject": .string("email sent"), "statement": .string("An email was sent to bob@example.com about the repo.")]),
        ])])
        let model = ScriptedModel(["ChatTurn": [turn("send email", reply: "I'll check.", steps: [("command", ["echo", "hi"])])],
                                   "Compact": [claim]])
        let (chat, _, graph) = engine(model)
        let run = try chat.start()
        for _ in 0..<3 { await chat.send(run, "send an email to bob@example.com about the repo", emit: Events().emit) }
        #expect(graph.nodes(kind: "fact").isEmpty)
    }

    @Test func requestsAreMatchedInEnglish() async throws {
        let english = "send an email to bob@example.com to tell him to look at the repo"
        let model = ScriptedModel(["Translate": [.object(["english": .string(english)])],
                                   "ChatTurn": [turn("send email", reply: "What should it say?")]])
        let (chat, _, graph) = engine(model)
        let run = try chat.start()
        let french = "envoie un courriel à bob@example.com pour lui dire d'aller voir le dépôt"
        await chat.send(run, french, emit: Events().emit)
        #expect(model.count("Translate") == 1)
        let intent = try #require(graph.node(chat.state(run).intent ?? ""))
        #expect(intent.text == english && intent.props["question"]?.string == french)
        // The model still answers the user's own words.
        #expect(model.last("ChatTurn").contains(french))
    }

    @Test func launchingAnAppOpensIt() async throws {
        let home = tempDir()
        for app in ["Zorkle Studio.app", "Tools/Zorkle Mixer.app", "Zorkle Studio.app/Contents/Zorkle Helper.app"] {
            try FileManager.default.createDirectory(atPath: home + "/Applications/" + app, withIntermediateDirectories: true)
        }
        #expect(OpenApp.find("zorklestudio", home: home) == home + "/Applications/Zorkle Studio.app")
        #expect(OpenApp.find("Zorkle Studio.app", home: home) != nil)
        #expect(OpenApp.find("zorkle mixer", home: home) == home + "/Applications/Tools/Zorkle Mixer.app")  // in a subfolder
        #expect(OpenApp.candidates("zorkle", home: home).count == 2)  // ambiguous: not opened, both named
        #expect(OpenApp.find("zorkle helper", home: home) == nil)  // helpers inside bundles aren't apps
        var policy = testPolicy()
        policy.home = home
        let env = ActionEnv(policy: policy, admin: RecordingAdminRunner())
        #expect(OpenApp().normalize(["app": "zorklestudio"], env)["app"] == "Zorkle Studio")
        #expect(throws: ActionError.self) { try OpenApp().validate(["app": "zorkle"], env) }
        #expect(throws: ActionError.self) { try OpenApp().validate(["app": "no such app anywhere"], env) }

        let model = ScriptedModel([
            "ChatTurn": [turn("launch safari", reply: "Opening it.", steps: [("action:open_app", ["safari"])])],
            "Compact": [compactAnswer],
        ])
        let (chat, _, _) = engine(model)
        #expect(chat.retrieval("launch garageband").tools.contains("action:open_app"))
        let run = try chat.start()
        await chat.send(run, "launch safari", emit: Events().emit)
        #expect(model.last("ChatTurn").contains("action:open_app app=App Name"))
        // A bare name is the app parameter, and the card shows the app's own name.
        let a = try #require(run.report()?.findings.first?.recommendations.first)
        #expect(a.call.spec == "open_app" && a.call.params["app"] == "Safari")
    }

    @Test func whatHappenedOnThisMacIsAHealthCheck() {
        let (chat, _, _) = engine(ScriptedModel([:]), skills: [SysHealth(), NetIdentify()])
        let r = chat.retrieval("What happened on this mac in the last 24 hours")
        #expect(r.skills == ["sys.health"])
        #expect(r.examples.contains("intent:seed-22"))
        // Time spans and "this Mac" match nothing on their own: not an app's "undo the last change", not a MAC address.
        #expect(Similarity.hits("in the last 24 hours", "Undo the last change.") == 0)
        #expect(Similarity.hits("what's on this mac", "identify a device by mac address") == 0)
        #expect(Similarity.hits("who is mac 00:dd:1f:e2:aa:44", "identify a device by mac address") == 1)
    }
}
