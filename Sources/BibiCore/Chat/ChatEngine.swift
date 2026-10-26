import Foundation

/// Where chat sends what happens: (type, text). Types: message (a ChatMessage as JSON), delta (the reply so far),
/// candidate (a learned-skill candidate as JSON), progress/info/ok/error/heading (from running steps).
public typealias ChatEmit = @Sendable (_ type: String, _ text: String) -> Void

/// The user's decisions on a proposal.
public struct ChatDecision: Sendable {
    public var approve: [String]
    public var skip: [String]
    public var reason: String?
    public var adminConfirmed: Bool
    public var dryRun: Bool

    public init(approve: [String], skip: [String] = [], reason: String? = nil, adminConfirmed: Bool = false, dryRun: Bool = false) {
        self.approve = approve; self.skip = skip; self.reason = reason; self.adminConfirmed = adminConfirmed; self.dryRun = dryRun
    }
}

/// "Chat with bibi": the generic skill. Each conversation is a run (skill `chat`) whose proposals are findings with
/// recommendations, so approval, execution, the journal, undo and history work exactly as for other runs.
///
/// One turn: retrieve skills, examples and facts from the graph → ask the model for a reply and steps → turn steps
/// into actions bibi's rules have checked → wait for approval → run → answer from the results → compact the
/// conversation → record statistics → maybe draft a learned skill.
public final class ChatEngine: Sendable {
    public let harness: Harness
    public let graph: GraphStore
    let embedder: any Embedder
    /// Characters of prompt per turn (the on-device model has ~4k tokens for instructions, prompt, schema and answer).
    let budget: Int
    /// Messages kept verbatim; older ones are compacted into the summary.
    public static let keepMessages = 4

    public init(harness: Harness, graph: GraphStore, embedder: any Embedder = SentenceEmbedder(), budget: Int = 6000) {
        self.harness = harness; self.graph = graph; self.embedder = embedder; self.budget = budget
    }

    var prompts: PromptBook { PromptBook(graph) }

    static let systemInstructions = """
    You are bibi, an assistant running on the user's Mac. You answer questions about this Mac and do things on it, including with its apps: email, calendar, reminders, contacts, calls, messages and any other listed app.
    You cannot see the Mac yourself. To find something out or change something, propose steps: the user approves them, they run, and you get their results.
    For an app, use a listed action or app tool. Write people and dates exactly as the user wrote them (a name, an address, "tomorrow 3pm"); bibi looks names up in Contacts and turns dates into exact times. Only include people the user named. For an email or message, write its text from what the user asked, in the user's language.
    steps: when the answer depends on this Mac (disk, versions, processes, settings, files, network) and it isn't in the results above, list the steps that find out or make the change, at most 4. Proposing steps is how you ask permission: never say you can't check, and never guess the state of the Mac.
    Usually one or two steps are enough; only include steps that serve this request. For a quick fact (free space, versions, what is running, a setting), one read-only command is best. Skills are slow, thorough analyses: use one only when the user wants a full check or cleanup. Use a listed action when it does exactly what was asked; otherwise use tool command. Never propose a change the user didn't ask for.
    No steps: when you can answer from the conversation and results, or to ask one short question when the request is ambiguous. Never invent command output or numbers.
    For a command, args is the program and then each argument separately, like ["df", "-h"]. There is no shell: no pipes, redirections, ; or &&, no $(...). Use absolute paths or ~. Start with sudo only when administrator rights are needed. Prefer read-only commands. Deleted files go to the Trash.
    reply: short and plain. When proposing, say what the steps will do. When answering from results, give the numbers that matter.
    """

    static let compactInstructions = """
    You keep the running summary of a conversation between a user and bibi, an assistant on their Mac.
    summary: the old summary updated with the new messages, at most 120 words: what the user wants, what ran, what was found, what is still open.
    Only write what the summary and messages say; add nothing else.
    facts: durable facts about this Mac or the user that a command result or the user stated in these messages, at most five, each copied closely from the message. None if there are none.
    """

    /// Registry actions chat can offer: how to fill their parameters, and the words that make them relevant.
    /// An action is only offered when the request uses one of its words (or a retrieved example used it):
    /// a small model picks whatever is listed.
    static let actionHints: [String: (hint: String, words: String)] = [
        "trash_path": ("path=/absolute/path", "delete remove trash erase get rid"),
        "reveal": ("path=/absolute/path", "show reveal finder locate where"),
        "open_url": ("url=https://...", "open website web page url link browser"),
        "open_settings_pane": ("pane=" + OpenSettingsPane.panes.keys.sorted().joined(separator: "|"),
                               "settings preferences pane open privacy firewall sharing battery login"),
        "tool_cleanup": ("tool=" + Tools.commands.keys.sorted().joined(separator: "|"),
                         "clean cleanup cache caches prune purge " + Tools.commands.keys.joined(separator: " ")),
    ].merging(Recipes.hints) { a, _ in a }

    static func turnSchema(_ tools: [String]) -> Schema {
        Schema("ChatTurn", [
            .init("intent", .string, "a short phrase for what the user wants, like 'check free disk space'"),
            .init("steps", .array(.object(Schema("Step", [
                .init("tool", .choice(tools)),
                .init("args", .array(.string, max: 16), "command: the program, then each argument; action: key=value; skill: its options"),
                .init("purpose", .string, "a few words: why this step"),
            ])), max: 4), "empty when you can answer without running anything"),
            .init("reply", .string, "with steps: one sentence on what they will check or do (their results aren't known yet); without steps: your answer"),
        ])
    }

    static let answerSchema = Schema("ChatAnswer", [
        .init("intent", .string, "a short phrase for what the user wanted"),
        .init("reply", .string, "your answer from the results"),
    ])

    static let compactSchema = Schema("Compact", [
        .init("summary", .string, "at most 120 words"),
        .init("facts", .array(.object(Schema("Fact", [.init("subject", .string, "a few words"), .init("statement", .string, "one sentence")])), max: 5)),
    ])

    // MARK: conversations

    public func start() throws -> RunRecord {
        let run = try harness.store.create(skill: "chat", args: [], online: false, version: Bibi.version)
        run.save(SkillResult(summary: "New chat"))
        run.saveFile("chat.json", ChatState(id: run.id, title: "New chat"))
        graph.upsert(GraphNode(id: "conversation:" + run.id, kind: "conversation", name: "New chat"))
        return run
    }

    public func conversations() -> [RunRecord] { harness.store.list(skill: "chat") }

    /// Chats whose title or messages contain every word of `query` (case-insensitive), newest first, with a
    /// snippet of the first matching message.
    public func search(_ query: String) -> [(run: RunRecord, snippet: String?)] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return conversations().map { ($0, nil) } }
        return conversations().compactMap { r in
            let texts = [r.meta.summary ?? ""] + transcript(r).map(\.text)
            let all = texts.joined(separator: "\n").lowercased()
            guard words.allSatisfy(all.contains) else { return nil }
            let hit = texts.dropFirst().first { $0.lowercased().contains(words[0]) }
            return (r, hit.map { Self.snippet($0, around: words[0]) })
        }
    }

    static func snippet(_ text: String, around word: String, radius: Int = 50) -> String {
        let flat = Text.oneLine(text, max: 10_000)
        guard let r = flat.lowercased().range(of: word) else { return Text.oneLine(flat, max: radius * 2) }
        let start = flat.index(r.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }

    /// Deletes a chat: its run (transcript, report, journal) and its conversation node. What bibi learned from it
    /// (statistics, example requests, facts) stays.
    public func delete(_ run: RunRecord) throws {
        guard run.meta.skill == "chat" else { throw ActionError("\(run.id) is not a chat") }
        try harness.store.delete(run)
        graph.delete("conversation:" + run.id)
    }

    public func state(_ run: RunRecord) -> ChatState {
        run.loadFile("chat.json", ChatState.self) ?? ChatState(id: run.id, title: run.meta.summary ?? "Chat")
    }

    public func transcript(_ run: RunRecord) -> [ChatMessage] { run.lines("transcript.jsonl", ChatMessage.self) }

    func save(_ run: RunRecord, _ state: ChatState) { run.saveFile("chat.json", state) }

    func say(_ run: RunRecord, _ state: inout ChatState, _ m: ChatMessage, _ emit: ChatEmit) {
        run.appendLine("transcript.jsonl", m)
        state.recent.append(m)
        emit("message", JSON.string(m))
    }

    func model(_ run: RunRecord) -> any LanguageModel { RecordingModel(harness.model) { run.model($0) } }

    // MARK: a user message

    public func send(_ run: RunRecord, _ text: String, emit: @escaping ChatEmit) async {
        var state = state(run)
        let question = Text.clip(text.trimmingCharacters(in: .whitespacesAndNewlines), max: 2000)
        guard !question.isEmpty else { return }
        if state.turns == 0 {
            state.title = Text.oneLine(question, max: 60)
            var report = run.report() ?? SkillResult(summary: state.title)
            report.summary = state.title
            run.save(report)
            graph.update("conversation:" + run.id) { $0.name = state.title }
        }
        state.turns += 1
        state.results = []
        state.pending = nil
        say(run, &state, ChatMessage("user", question), emit)
        await think(run, &state, question: question, emit: emit)
        await compact(run, &state)
        save(run, state)
    }

    /// One model turn. `question` is nil for the follow-up that answers from results.
    func think(_ run: RunRecord, _ state: inout ChatState, question: String?, emit: @escaping ChatEmit) async {
        let focus = question ?? state.recent.last(where: { $0.role == "user" })?.text ?? ""
        let v = embedder.vector(focus)
        harness.apps.catalog.refresh(graph: graph)
        let skills = rankSkills(focus, v)
        let shown = question == nil ? [] : exampleIntents(focus)
        let tools = toolCatalog(skills, request: focus, examples: shown, vector: v)

        // An unfinished request from the last turn: the user's message may be the missing piece.
        let draft = question == nil ? nil : state.draft
        if question != nil { state.draft = nil }

        var ctx = ContextBuilder()
        ctx.add("Tools", tools.text, priority: 0, maxChars: 2500)
        ctx.add("Conversation so far", state.summary, priority: 3, maxChars: 1200)
        let known = facts(focus, v)
        ctx.add("Known facts", known, priority: 4, maxChars: 600)
        if question != nil {
            ctx.add("Examples of requests and the steps that answered them", examples(shown), priority: 1, maxChars: 700)
        }
        let recent = recentText(state, dropLastUser: question != nil)
        ctx.add("Recent messages", recent, priority: 2, maxChars: 2000)
        ctx.add("Results of the steps the user approved", state.results.joined(separator: "\n\n"), priority: 0, maxChars: 2500)
        ctx.add("Commands that check the latest findings", (state.hints ?? []).joined(separator: "\n"), priority: 1, maxChars: 900)
        ctx.add("Unfinished request (the user's message may answer it; then propose the completed steps)", draft ?? "", priority: 0,
                maxChars: 1200)
        ctx.add(question == nil ? "Task" : "User",
                question ?? "Answer the user's last request from these results: quote or summarize the output lines that answer it, with the numbers that matter. If they don't answer it, say what is missing.",
                priority: 0)

        let generic = prompts.active("skill.generic", default: "")
        let system = prompts.text("chat.system", default: Self.systemInstructions)
        let instructions = generic.text.isEmpty ? system : system + "\n" + generic.text
        // After results, only answer: a small model asked to answer and plan at once re-proposes instead of answering.
        let schema = question == nil ? Self.answerSchema : Self.turnSchema(tools.ids)
        guard var answer = await ask(run, &state, ctx, instructions: instructions, schema: schema, emit: emit) else { return }

        let phrase = (answer["intent"]?.string ?? "").ifEmpty(Text.oneLine(focus, max: 80))
        var steps = Self.steps(answer)
        var reply = (answer["reply"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if let question {
            let id = "intent:\(run.id)-\(state.turns)"
            graph.upsert(GraphNode(id: id, kind: "intent", name: phrase, text: question,
                                   props: ["question": .string(question), "intent": .string(phrase), "conversation": .string(run.id)]))
            if let iv = embedder.vector(phrase) { graph.setVector(id, iv) }
            graph.link("conversation:" + run.id, id, "contains")
            graph.record("asked", node: id, conversation: run.id)
            state.intent = id
        }

        // People and addresses must come from the conversation (or Contacts), never from the model's imagination.
        let said = [question ?? "", recent, state.summary, known, draft ?? "", state.results.joined(separator: "\n")].joined(separator: "\n")
        var plan = Planner.Result(), tried = steps
        for attempt in 0...Self.repairs where !steps.isEmpty {
            tried = steps
            plan = await bind(steps, run: run, said: said)
            guard !plan.refusals.isEmpty, attempt < Self.repairs else { break }
            // Let the model fix what the request already answers; what only the user knows becomes a question.
            emit("delta", "Filling in what's missing…")
            var fix = ctx
            fix.add("Problems with the steps you proposed", Self.problems(steps, plan.refusals), priority: 0, maxChars: 1500)
            guard let again = await ask(run, &state, fix, instructions: instructions, schema: schema, emit: emit) else { return }
            answer = again
            steps = Self.steps(answer)
            reply = (answer["reply"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var finding: String?
        if !plan.actions.isEmpty {
            finding = addProposal(run, title: phrase, explanation: reply, actions: plan.actions)
            state.pending = finding
            let owner = owner(of: tried)
            let g = prompts.active("skill." + (graph.node(owner)?.name ?? "generic"), default: guidanceDefault(owner))
            state.skill = owner
            state.guidance = g.version.isEmpty ? nil : g.version
            graph.record("proposed", node: owner, conversation: run.id)
            if let gv = state.guidance { graph.record("proposed", node: gv, conversation: run.id) }
        }
        if !plan.refusals.isEmpty {
            if finding == nil {
                // Nothing runnable yet: keep what was tried so the user's answer can complete it, and ask.
                state.draft = Self.problems(tried, plan.refusals, request: question ?? focus)
                if !(steps.isEmpty && reply.hasSuffix("?")) { reply = Self.askFor(plan.refusals) }
            } else {
                let why = plan.refusals.map { "- " + $0 }.joined(separator: "\n")
                say(run, &state, ChatMessage("note", "bibi left out some of the proposed steps:\n" + why), emit)
            }
        }
        if finding != nil && (Self.claimsResults(reply, question: focus) || !Self.readsAsPlan(reply)) {
            // The model sometimes answers as if the steps had already run; nothing has run yet.
            reply = "I'll check with the step(s) below."
        }
        if reply.isEmpty { reply = finding == nil ? "I don't have an answer for that." : "Here is what I'd run." }
        say(run, &state, ChatMessage("bibi", reply, finding: finding), emit)
    }

    /// How many times the model may fix refused steps before bibi asks the user.
    static let repairs = 2

    /// One model call, shortening the prompt when it overflows the context. Says what went wrong and returns nil
    /// when it can't answer.
    func ask(_ run: RunRecord, _ state: inout ChatState, _ ctx: ContextBuilder, instructions: String, schema: Schema,
             emit: @escaping ChatEmit) async -> JSONValue? {
        let model = model(run)
        var budget = self.budget
        for _ in 0..<4 {
            do {
                return try await model.stream(ctx.build(budget: budget).text, instructions: instructions, schema: schema) { partial in
                    if let r = partial["reply"]?.string, !r.isEmpty { emit("delta", r) }
                }
            } catch let e as LLMError where e.contextOverflow {
                budget = budget * 2 / 3
            } catch {
                say(run, &state, ChatMessage("note", "The model failed: \(error)"), emit)
                return nil
            }
        }
        say(run, &state, ChatMessage("note", "This doesn't fit the model's context even when shortened; start a new chat."), emit)
        return nil
    }

    static func steps(_ answer: JSONValue) -> [PlannedStep] {
        (answer["steps"]?.array ?? []).compactMap { s in
            guard let tool = s["tool"]?.string else { return nil }
            return PlannedStep(tool: tool, args: s["args"]?.strings ?? [], purpose: s["purpose"]?.string ?? "")
        }
    }

    /// Checks proposed steps: names become addresses, then bibi's rules bind them. Steps already proposed in this
    /// chat (run or skipped) aren't offered again.
    func bind(_ steps: [PlannedStep], run: RunRecord, said: String) async -> Planner.Result {
        let planner = Planner(registry: harness.registry, env: harness.env(admin: NoAdminRunner(), reporter: SilentReporter()),
                              skill: { [harness] in harness.skill(named: $0) })
        let people = await Recipes.resolveRecipients(steps, contacts: harness.apps.contacts, said: said)
        var plan = planner.bind(people.steps)
        plan.refusals = people.refusals + plan.refusals
        // A step dropped for its recipient may have other problems too: report them now, so one repair fixes all.
        for s in people.dropped {
            if case .failure(let e) = planner.bind(s), !e.description.contains("is not an email address"),
               !e.description.contains("is not a phone number") { plan.refusals.append(e.description) }
        }
        let earlier = Set((run.report()?.actions ?? []).map { JSON.string($0.call) })
        plan.actions.removeAll { earlier.contains(JSON.string($0.call)) }
        return plan
    }

    /// The steps and what is wrong with them, for the model to fix (or for the next turn, with the request).
    static func problems(_ steps: [PlannedStep], _ refusals: [String], request: String? = nil) -> String {
        var lines = request.map { ["Request: " + Text.oneLine($0, max: 300)] } ?? []
        lines += steps.map { "Step: \($0.tool) \(JSON.string($0.args))" }
        lines += refusals.map { "Problem: " + $0 }
        if request == nil {
            lines.append("Fix the steps using what the user already said (for an email or message, write the text from the request). "
                         + "If only the user knows what is missing (who, which address, what to say), propose no steps and ask one short question in the user's language.")
        }
        return lines.joined(separator: "\n")
    }

    /// The question bibi asks when the model couldn't fix the steps itself.
    static func askFor(_ refusals: [String]) -> String {
        "I need a bit more before I can do this:\n" + refusals.map { "- " + $0 }.joined(separator: "\n")
            + "\nTell me and I'll propose it again."
    }

    /// A reply sent with a proposal should say what will happen, not what was found.
    public static func readsAsPlan(_ reply: String) -> Bool {
        let r = reply.lowercased().replacingOccurrences(of: "’", with: "'")
        return ["i'll", "i will", "let me", "i can", "i'm going", "i am going", "i'd", "i would", "to ", "checking", "running",
                "here", "this will", "these steps", "the steps", "first"].contains { r.hasPrefix($0) }
    }

    /// True if a reply written before any step ran states numbers or fills in placeholders like "[version]".
    public static func claimsResults(_ reply: String, question: String) -> Bool {
        let numbers = { (t: String) in Set(Re.all("[0-9]+(?:[.,][0-9]+)?", t).compactMap(\.first)) }
        return !numbers(reply).subtracting(numbers(question)).isEmpty || Re.test("\\[[A-Za-z ]+\\]", reply)
    }

    /// Adds a proposal to the chat run's report and returns its finding id.
    func addProposal(_ run: RunRecord, title: String, explanation: String, actions: [BoundAction], cites: [String] = []) -> String {
        var report = run.report() ?? SkillResult(summary: title)
        let fid = "F\(report.findings.count + 1)"
        var n = report.actions.count
        let numbered = actions.map { a -> BoundAction in
            n += 1
            var a = a
            a.id = "a\(n)"
            a.findingID = fid
            return a
        }
        report.findings.append(Finding(id: fid, category: "chat", title: title, severity: .info, observationIDs: cites,
                                       confidence: 70, explanation: explanation, recommendations: numbered))
        run.save(report)
        return fid
    }

    /// The skill node a proposal belongs to (for statistics): the skill it runs, the skill owning its action, or generic.
    func owner(of steps: [PlannedStep]) -> String {
        for s in steps {
            if s.tool.hasPrefix("skill:") { return GraphSync.skillID(String(s.tool.dropFirst(6))) }
            if s.tool.hasPrefix("action:"), let src = graph.edges(to: "action:" + s.tool.dropFirst(7), kind: "uses").first?.src { return src }
        }
        return GraphSync.root
    }

    func guidanceDefault(_ skillNode: String) -> String {
        skillNode == GraphSync.root ? "" : harness.skill(named: graph.node(skillNode)?.name ?? "")?.help ?? ""
    }

    // MARK: retrieval

    /// Skills whose keywords or description share words with the request, ranked by those hits plus embedding
    /// similarity, weighted by how often their proposals were approved. Skills that match nothing aren't offered:
    /// a small model picks a listed skill too eagerly.
    func rankSkills(_ text: String, _ v: [Float]?, limit: Int = 3) -> [GraphNode] {
        graph.nodes(kind: "skill", status: "active").filter { $0.id != GraphSync.root && harness.skill(named: $0.name) != nil }
            .compactMap { n -> (GraphNode, Double)? in
                let hits = Similarity.hits(text, (n.props["keywords"]?.string ?? "") + " " + n.text)
                guard hits > 0 else { return nil }
                var nv = graph.vector(n.id)
                if nv == nil, let x = embedder.vector(n.text) { graph.setVector(n.id, x); nv = x }
                let sim = nv.flatMap { a in v.map { Similarity.cosine(a, $0) } } ?? 0
                return (n, (Double(hits) + sim) * (0.5 + 0.5 * graph.approvalRate(n.id)))
            }
            .sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    func toolCatalog(_ skills: [GraphNode], request: String, examples: [GraphNode], vector: [Float]? = nil) -> (ids: [String], text: String) {
        var ids = ["command"]
        var lines = [#"- command: any program; args = the program, then each argument. Examples: ["df", "-h", "/"] free disk space; ["sw_vers"] macOS version; ["ps", "-Ao", "pid,%cpu,%mem,comm", "-m"] processes by memory; ["du", "-sh", "~/Downloads"] folder size"#]
        let used = Set(examples.flatMap { SkillMiner.steps($0).map(\.tool) })
        for n in skills {
            guard let s = harness.skill(named: n.name) else { continue }
            ids.append("skill:" + s.name)
            let guidance = prompts.text("skill." + s.name, default: s.help)
            lines.append("- skill:\(s.name) (thorough, takes a minute): \(Text.oneLine(guidance, max: 300)) \(GraphSync.example(s.params))")
        }
        for (id, a) in Self.actionHints.sorted(by: { $0.key < $1.key }) {
            guard let spec = harness.registry.spec(id),
                  used.contains("action:" + id) || Similarity.hits(request, a.words) > 0 else { continue }
            ids.append("action:" + id)
            lines.append("- action:\(id) \(a.hint): \(spec.summary)")
        }
        // Discovered app capabilities, except for apps a listed built-in action already covers.
        let covered = Set(ids.compactMap { $0.hasPrefix("action:") ? Recipes.apps[String($0.dropFirst(7))] : nil })
        for n in rankCapabilities(request, vector, examples: used) {
            guard let bundle = n.props["app"]?.string, !covered.contains(bundle), let app = harness.apps.catalog.app(bundle),
                  let hint = AppScripts.hint(app, op: n.props["op"]?.string ?? "", term: n.props["term"]?.string ?? "") else { continue }
            if !ids.contains("app:" + app.name) { ids.append("app:" + app.name) }
            lines.append(hint)
        }
        return (ids, lines.joined(separator: "\n"))
    }

    /// Scriptable-app commands and classes whose words match the request (or that a retrieved example used),
    /// ranked by those hits plus embedding similarity.
    func rankCapabilities(_ text: String, _ v: [Float]?, examples used: Set<String>, limit: Int = 3) -> [GraphNode] {
        let usedApps = Set(used.filter { $0.hasPrefix("app:") }.map { String($0.dropFirst(4)).lowercased() })
        return graph.nodes(kind: "capability").compactMap { n -> (GraphNode, Double)? in
            let hits = Similarity.hits(text, n.name + " " + n.text)
            let example = usedApps.contains((n.name.split(separator: " ").first.map(String.init) ?? "").lowercased())
            guard hits > 0 || example else { return nil }
            var nv = graph.vector(n.id)
            if nv == nil, let x = embedder.vector(n.text) { graph.setVector(n.id, x); nv = x }
            let sim = nv.flatMap { a in v.map { Similarity.cosine(a, $0) } } ?? 0
            return (n, Double(hits) + sim + (example ? 1 : 0))
        }
        .sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Up to three requests that worked (learned or seeded) sharing words with this one, best first; learned
    /// ones win ties and frequently matched ones rank higher.
    func exampleIntents(_ text: String) -> [GraphNode] {
        let terms = Similarity.terms(text)
        let ranked = graph.nodes(kind: "intent").filter { $0.props["outcome"]?.string == "ok" }
            .compactMap { n -> (GraphNode, Double)? in
                let hits = terms.intersection(Similarity.terms(n.text)).count
                guard hits > 0 else { return nil }
                let used = graph.edges(from: n.id, kind: "matched").reduce(0) { $0 + $1.weight }
                return (n, Double(hits) + (n.props["seed"] == nil ? 0.5 : 0) + min(1, used / 10))
            }
            .sorted { $0.1 > $1.1 }
        var seen = Set<String>(), out: [GraphNode] = []
        for (n, _) in ranked where out.count < 3 && seen.insert(n.text.lowercased()).inserted { out.append(n) }
        return out
    }

    func examples(_ intents: [GraphNode]) -> String {
        intents.map { n in
            let steps = SkillMiner.steps(n).map { "\($0.tool) " + JSON.string($0.args) }.joined(separator: "; ")
            return "\"\(Text.oneLine(n.text, max: 100))\" → \(steps)"
        }.joined(separator: "\n")
    }

    func facts(_ text: String, _ v: [Float]?) -> String {
        var seen = Set<String>()
        let pool = (graph.search(text, kind: "fact", limit: 10) + graph.nodes(kind: "fact").prefix(40)).filter { seen.insert($0.id).inserted }
        return pool.map { ($0, Similarity.score(text, v, $0.name + " " + $0.text, graph.vector($0.id))) }
            .filter { $0.1 >= 0.35 }.sorted { $0.1 > $1.1 }.prefix(3)
            .map { "- \($0.0.text) (\(ago($0.0.updated)))" }.joined(separator: "\n")
    }

    func recentText(_ state: ChatState, dropLastUser: Bool) -> String {
        var msgs = state.recent
        if dropLastUser, msgs.last?.role == "user" { msgs.removeLast() }
        return msgs.map { m in
            let who = ["user": "User", "bibi": "bibi", "result": "Result", "note": "Note"][m.role] ?? m.role
            return "\(who): " + Text.clip(m.text, max: m.role == "result" ? 300 : 600)
        }.joined(separator: "\n")
    }

    // MARK: decisions

    /// Skills for the quick-run list on the chat page, most used first (runs in history from any front end).
    public func quickSkills(limit: Int = 6) -> [SkillLibrary.SkillView] {
        var uses: [String: Int] = [:]
        for r in harness.store.list() where r.meta.skill != "chat" { uses[r.meta.skill, default: 0] += 1 }
        return harness.sortedSkills.compactMap { s -> (SkillLibrary.SkillView, Int)? in
            guard let n = graph.node(GraphSync.skillID(s.name)), n.status == "active", s.params.allSatisfy({ !$0.required }) else { return nil }
            var v = SkillLibrary.view(n, graph: graph)
            v.help = s.help
            return (v, uses[s.name, default: 0])
        }
        .sorted { ($0.1, $1.0.name) > ($1.1, $0.0.name) }.prefix(limit).map(\.0)
    }

    /// Records the user's decisions, runs what was approved (through the harness: validation, journal, admin
    /// confirmation), then lets the model answer from the results and learns from what worked.
    public func decide(_ run: RunRecord, _ d: ChatDecision, admin: any AdminRunner, emit: @escaping ChatEmit) async throws -> [ExecResult] {
        var state = state(run)
        guard let report = run.report() else { throw ActionError("this chat has no proposals") }
        let done = Set(run.journalEntries.filter { $0.event == .executed }.compactMap(\.actionID))
        // Only the latest proposal can be decided; a new message supersedes older ones.
        let open = Set(report.findings.first { $0.id == state.pending }?.recommendations.map(\.id) ?? [])
        for id in d.approve + d.skip where !open.contains(id) {
            throw ActionError(report.action(id) == nil ? "unknown action \(id)" : "\(id) belongs to an earlier proposal; ask again")
        }
        let approved = try d.approve.map { id -> BoundAction in
            guard let a = report.action(id) else { throw ActionError("unknown action \(id)") }
            guard !done.contains(id) else { throw ActionError("\(a.title) already ran") }
            return a
        }
        let skipped = d.skip.compactMap(report.action)
        let owner = state.skill ?? GraphSync.root
        let skillName = graph.node(owner)?.name ?? "generic"

        if !d.dryRun {
            for _ in approved { record("approved", owner, state, run) }
        }
        for a in skipped {
            record("skipped", owner, state, run)
            say(run, &state, ChatMessage("note", "Skipped: \(a.title)", actionID: a.id), emit)
        }
        if let reason = d.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty, !skipped.isEmpty {
            prompts.addAvoid("skill." + skillName, default: guidanceDefault(owner), note: reason)
            say(run, &state, ChatMessage("note", "Noted for next time: \(Text.oneLine(reason, max: 160))"), emit)
        }

        let reporter = ChatReporter(emit: emit)
        let env = harness.env(admin: admin, reporter: reporter)
        var results = await harness.execute(approved.filter { $0.call.spec != "run_skill" }, run: run, env: env,
                                            adminConfirmed: d.adminConfirmed, dryRun: d.dryRun, frontend: "chat")
        var next: String?
        for a in approved where a.call.spec == "run_skill" {
            let (r, fid, hints) = await runSkill(a, run, dryRun: d.dryRun, reporter: reporter)
            results.append(r)
            if let fid { next = fid }
            if !hints.isEmpty { state.hints = hints }
        }

        for r in results {
            let output = r.output.map { "\n" + Text.clip($0, max: 4000) } ?? ""
            say(run, &state, ChatMessage("result", "\(r.title): \(r.message)\(output)", actionID: r.actionID, ok: r.ok), emit)
            if !d.dryRun { graph.record(r.ok ? "executed" : "failed", node: owner, conversation: run.id) }
        }
        state.results = results.map { r in
            "\(r.ok ? "OK" : "FAILED") \(r.title): \(r.message)" + (r.output.map { "\n" + Text.clip(Text.collapseRepeats($0), max: 1500) } ?? "")
        }
        if let pending = state.pending, let f = run.report()?.findings.first(where: { $0.id == pending }) {
            let decided = Set(d.approve + d.skip).union(done)
            if f.recommendations.allSatisfy({ decided.contains($0.id) }) { state.pending = nil }
        }
        if let next { state.pending = next }

        if !d.dryRun, let intent = state.intent {
            let worked = approved.filter { a in results.contains { $0.actionID == a.id && $0.ok } }.map(PlannedStep.from)
            if !worked.isEmpty {
                await learn(intent, worked, owner: owner, run: run, state: &state, emit: emit)
            }
        }
        prompts.evaluate("skill." + skillName)

        if !d.dryRun && !results.isEmpty {
            await think(run, &state, question: nil, emit: emit)
            state.results = []
        }
        await compact(run, &state)
        save(run, state)
        return results
    }

    func record(_ kind: String, _ owner: String, _ state: ChatState, _ run: RunRecord) {
        graph.record(kind, node: owner, conversation: run.id)
        if let g = state.guidance { graph.record(kind, node: g, conversation: run.id) }
    }

    /// Runs a skill the user approved from chat. Its summary becomes evidence; its recommendations come back as
    /// a new proposal in this chat (so they need their own approval). Returns that proposal's id.
    func runSkill(_ a: BoundAction, _ run: RunRecord, dryRun: Bool, reporter: any Reporter) async -> (ExecResult, String?, [String]) {
        let name = a.call.params["skill"] ?? "", argv = CommandPolicy.decode(a.call.params["argv"] ?? "[]") ?? []
        func fail(_ m: String) -> (ExecResult, String?, [String]) {
            run.journal(JournalEntry(.failed, actionID: a.id, title: a.title, call: a.call, error: m, frontend: "chat"))
            return (ExecResult(actionID: a.id, title: a.title, ok: false, message: m, reversible: false), nil, [])
        }
        guard let skill = harness.skill(named: name) else { return fail("unknown skill \(name)") }
        run.journal(JournalEntry(.selected, actionID: a.id, title: a.title, call: a.call, frontend: "chat"))
        if dryRun {
            let m = "[dry-run] would run bibi \(name) \(Shell.join(argv))"
            run.journal(JournalEntry(.dryRun, actionID: a.id, title: a.title, call: a.call, message: m, frontend: "chat"))
            return (ExecResult(actionID: a.id, title: a.title, ok: true, message: m, reversible: false), nil, [])
        }
        do {
            let (child, result) = try await harness.run(skill, argv: argv, reporter: reporter)
            guard var report = run.report() else { return fail("the chat report is missing") }
            let oid = "o\(report.observations.count + 1)"
            let top = result.findings.prefix(5).map { "- [\($0.severity.rawValue)] \($0.title): \(Text.oneLine($0.explanation, max: 200))" }
            let text = ([result.summary] + top).joined(separator: "\n")
            report.observations.append(Observation(id: oid, source: "bibi \(name) (run \(child.id))", text: text))
            run.save(report)
            var message = "ran \(name) (run \(child.id))"
            var fid: String?
            let recs = Array(result.actions.prefix(6))
            if !recs.isEmpty {
                fid = addProposal(run, title: "Recommendations from \(name)", explanation: result.summary, actions: recs, cites: [oid])
                message += "; \(recs.count) recommendation(s) to review"
            }
            run.journal(JournalEntry(.executed, actionID: a.id, title: a.title, call: a.call, message: message, frontend: "chat"))
            return (ExecResult(actionID: a.id, title: a.title, ok: true, message: message, reversible: false, output: text), fid,
                    Self.hints(result.findings))
        } catch {
            return fail("\(error)")
        }
    }

    /// The read-only diagnostic commands of a skill's top findings, filled in for their subject, as
    /// "finding → [argv]" lines the model can copy.
    static func hints(_ findings: [Finding], limit: Int = 6) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for f in findings.prefix(8) {
            for id in f.diagnostics {
                guard out.count < limit, let d = Diagnostics.get(id), !d.admin, let argv = d.command(subject: f.subject),
                      seen.insert(argv.joined(separator: " ")).inserted else { continue }
                out.append("\(Text.oneLine(f.title, max: 70)) → command \(JSON.string(argv))")
            }
        }
        return out
    }

    /// Remembers what worked for this request and drafts a skill when the same request keeps coming back.
    func learn(_ intent: String, _ worked: [PlannedStep], owner: String, run: RunRecord, state: inout ChatState,
               emit: @escaping ChatEmit) async {
        graph.update(intent) { n in
            let steps = SkillMiner.steps(n) + worked
            n.props["outcome"] = .string("ok")
            n.props["steps"] = (try? JSON.decode(JSONValue.self, from: JSON.string(steps))) ?? .array([])
            n.props["signature"] = .string(steps.map(\.signature).joined(separator: ">"))
        }
        graph.strengthen(intent, owner, "matched")
        graph.strengthen(owner, intent, "example")
        let miner = SkillMiner(graph: graph, model: model(run), prompts: prompts)
        guard let c = await miner.observe(intent) else { return }
        state.candidates.append(c.id)
        let size = c.props["size"]?.int ?? SkillMiner.minOccurrences
        emit("candidate", JSON.string(SkillLibrary.view(c, graph: graph)))
        say(run, &state, ChatMessage("note", "You've asked for this \(size) times. I can keep it as a skill, \"\(c.name)\": "
                                     + (c.props["help"]?.string ?? "") + " Accept it under Skills, or here."), emit)
    }

    // MARK: compaction

    /// Folds messages older than the last few into the summary and stores durable facts in the graph.
    func compact(_ run: RunRecord, _ state: inout ChatState) async {
        guard state.recent.count > Self.keepMessages else { return }
        let old = state.recent.dropLast(Self.keepMessages)
        state.recent = Array(state.recent.suffix(Self.keepMessages))
        let lines = old.map { m in
            "\(["user": "User", "bibi": "bibi", "result": "Result", "note": "Note"][m.role] ?? m.role): \(Text.clip(m.text, max: 500))"
        }.joined(separator: "\n")
        let prompt = "Summary so far:\n\(state.summary.ifEmpty("(none)"))\n\nNew messages:\n\(lines)"
        if let r = try? await model(run).respond(prompt, instructions: prompts.text("chat.compact", default: Self.compactInstructions),
                                                 schema: Self.compactSchema),
           let s = r["summary"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            state.summary = Text.clip(s, max: 1200)
            let source = lines + "\n" + state.summary
            for f in r["facts"]?.array ?? [] {
                if let subject = f["subject"]?.string, let statement = f["statement"]?.string, Self.grounded(statement, in: source) {
                    remember(subject, statement, conversation: run.id)
                }
            }
        } else {
            state.summary = String((state.summary + "\n" + lines).suffix(1200))
        }
    }

    /// A fact is kept only if it is a sentence about the Mac or the user (not a request or a plan) whose numbers
    /// and most of whose words appear in what was said: the model embellishes and copies fragments.
    public static func grounded(_ statement: String, in source: String) -> Bool {
        let numbers = { (t: String) in Set(Re.all("[0-9]+(?:[.,][0-9]+)?", t).compactMap(\.first)) }
        let words = Similarity.terms(statement)
        let lower = statement.lowercased()
        guard words.count >= 3, statement.split(separator: " ").count >= 4,
              !["i'll", "i will", "result:", "the user asked", "user asked", "bibi will", "bibi"].contains(where: { lower.hasPrefix($0) }),
              numbers(statement).isSubset(of: numbers(source)) else { return false }
        return Double(words.intersection(Similarity.terms(source)).count) / Double(words.count) >= 0.6
    }

    func remember(_ subject: String, _ statement: String, conversation: String) {
        // One fact per subject: a newer statement (e.g. free space today) replaces the older one.
        let id = "fact:" + Hashing.short(Similarity.terms(subject).sorted().joined(separator: " "))
        graph.upsert(GraphNode(id: id, kind: "fact", name: Text.oneLine(subject, max: 80), text: Text.oneLine(statement, max: 300),
                               props: ["conversation": .string(conversation)]))
        if let v = embedder.vector(subject + " " + statement) { graph.setVector(id, v) }
        graph.link(id, "conversation:" + conversation, "from")
    }
}

/// Sends progress from running steps to the chat.
struct ChatReporter: Reporter {
    let emit: ChatEmit
    func progress(_ m: String) { emit("progress", m) }
    func info(_ m: String) { emit("info", m) }
    func debug(_: String) {}
    func ok(_ m: String) { emit("ok", m) }
    func error(_ m: String) { emit("error", m) }
    func heading(_ m: String) { emit("heading", m) }
}
