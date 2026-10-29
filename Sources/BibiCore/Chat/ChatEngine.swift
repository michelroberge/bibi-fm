import Foundation
import NaturalLanguage

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
    /// bibi approved these itself ("Let bibi look": read-only steps): counted as `auto`, not as the user's approval.
    public var auto: Bool

    public init(approve: [String], skip: [String] = [], reason: String? = nil, adminConfirmed: Bool = false, dryRun: Bool = false,
                auto: Bool = false) {
        self.approve = approve; self.skip = skip; self.reason = reason; self.adminConfirmed = adminConfirmed; self.dryRun = dryRun
        self.auto = auto
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
    /// Characters of prompt per turn, at most (the on-device model has ~4k tokens for instructions, prompt, schema
    /// and answer; `ask` gives the instructions and schema their share first).
    let budget: Int
    /// Characters a whole call may take, instructions and schema included: ~2.5k tokens, leaving room for the answer.
    static let contextChars = 10_000
    /// The prompt never shrinks below this, whatever the instructions take: the request and the tools must fit.
    static let minPromptChars = 1500
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

    static let fallbackInstructions = """
    You are a helpful assistant on the user's Mac (macOS). Answer the user's message directly and briefly, in the user's language.
    You cannot see or check this Mac. When the answer depends on its state, say which Terminal commands or System Settings would show it. Never invent output or numbers.
    """

    static let fallbackSchema = Schema("Fallback", [.init("reply", .string, "your answer")])

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
        "open_app": ("app=App Name", "launch open start app application"),
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

    static let translateInstructions = """
    Translate the user's message to English. Keep names, email addresses, URLs, paths, numbers and quoted text exactly as written.
    Translate only: don't answer it or add anything.
    """

    static let translateSchema = Schema("Translate", [.init("english", .string, "the message in English")])

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

    /// `explore`: when no tool fits, work out commands instead of only answering (the chat's "Work it out" toggle).
    /// `look`: read-only steps run without a card, and bibi keeps looking until it can answer ("Let bibi look").
    public func send(_ run: RunRecord, _ text: String, explore: Bool = false, look: Bool = false, emit: @escaping ChatEmit) async {
        var state = state(run)
        let question = Text.clip(text.trimmingCharacters(in: .whitespacesAndNewlines), max: 2000)
        guard !question.isEmpty else { return }
        state.look = look ? true : nil
        if state.turns == 0 {
            state.title = Text.oneLine(question, max: 60)
            var report = run.report() ?? SkillResult(summary: state.title)
            report.summary = state.title
            run.save(report)
            graph.update("conversation:" + run.id) { $0.name = state.title }
        }
        state.turns += 1
        state.results = []
        // The new message supersedes the open proposal, but a card being filled in carries over into this turn.
        let previous = state.pending
        state.pending = nil
        say(run, &state, ChatMessage("user", question), emit)
        let english = await english(run, question)
        await think(run, &state, question: question, english: english, previous: previous, explore: explore, emit: emit)
        // "Let bibi look": steps that only read run right away, no card, and the answer follows from what they found.
        if let ids = autoApprovable(run, state) {
            save(run, state)
            var failed: (any Error)?
            do { _ = try await decide(run, ChatDecision(approve: ids, auto: true), admin: NoAdminRunner(), emit: emit) } catch { failed = error }
            state = self.state(run)
            if let failed { say(run, &state, ChatMessage("note", "Couldn't run the steps: \(failed)"), emit) }
        }
        await compact(run, &state)
        save(run, state)
    }

    /// One model turn. `question` is nil for the follow-up that answers from results.
    /// `english` is the request in English, for retrieval: examples, facts and embeddings are in English.
    func think(_ run: RunRecord, _ state: inout ChatState, question: String?, english: String? = nil, previous: String? = nil,
               explore: Bool = false, emit: @escaping ChatEmit) async {
        let focus = question ?? state.recent.last(where: { $0.role == "user" })?.text ?? ""
        // The follow-up answers the request whose intent node holds its English.
        let topic = english ?? (question == nil ? state.intent.flatMap { graph.node($0)?.text } : nil) ?? focus
        // Tool hints have words in both languages: match the message as written and its translation.
        let words = topic == focus ? focus : focus + "\n" + topic
        let v = embedder.vector(topic)
        harness.apps.catalog.refresh(graph: graph)
        let skills = rankSkills(topic, v)
        // Only the tools the message's own words select: an example's tools ("bibi" recalls a reminder) aren't a topic.
        let worded = toolCatalog(skills, request: words, examples: [], vector: v).ids
        let shown = question == nil ? [] : exampleIntents(topic, tools: worded)
        var tools = toolCatalog(skills, request: words, examples: shown, vector: v)

        // An unfinished request from the last turn: the user's message may be the missing piece, unless it asks for
        // something else (then the old request would only drag the model back to it).
        let draft = question == nil ? nil : state.draft.flatMap { Self.continues($0, tools: tools.ids) ? $0 : nil }
        if question != nil { state.draft = nil }
        // The open proposal's form actions: the model sees their fields, and proposing the same action again changes
        // only the fields it gives ("make the subject shorter"). A message about something else leaves them alone.
        let open = question == nil ? [] : openForms(run, previous)
        let form = open.map(Self.formText).joined(separator: "\n")
        let editing = open.isEmpty || !Self.continues(form, tools: worded) ? [] : open
        if !editing.isEmpty {
            // The card's own actions are always available while it is being filled in ("mets le sujet…" names no tool).
            var t = toolCatalog(skills, request: words, examples: [], vector: v)
            for a in editing where !t.ids.contains("action:" + a.call.spec) {
                t.ids.append("action:" + a.call.spec)
                if let spec = harness.registry.spec(a.call.spec) {
                    t.text += "\n- action:\(spec.id) \(Self.actionHints[spec.id]?.hint ?? ""): \(spec.summary)"
                }
            }
            tools = t
        }

        var ctx = ContextBuilder()
        // The model doesn't know the date; without it, "tomorrow" becomes a date from its training.
        ctx.add("Now", DateText.formatter("EEEE yyyy-MM-dd HH:mm").string(from: Date()), priority: 0)
        ctx.add("Tools", tools.text, priority: 0, maxChars: 2500)
        ctx.add("Conversation so far", editing.isEmpty ? state.summary : "", priority: 3, maxChars: 1200)
        let known = facts(topic, v)
        ctx.add("Known facts", known, priority: 4, maxChars: 600)
        // While a card is being filled in, past requests would only lend it their content.
        if question != nil && editing.isEmpty {
            ctx.add("Examples of requests and the steps that answered them", examples(shown), priority: 1, maxChars: 700)
        }
        let recent = recentText(state, dropLastUser: question != nil)
        // While the user fills in a card, the card holds what was settled: the messages that led to it would only
        // repeat it less precisely (and use the small context). Grounding below still checks the whole conversation.
        ctx.add("Recent messages", editing.isEmpty ? recent : recentText(state, dropLastUser: true, since: previous), priority: 2,
                maxChars: 2000)
        // Not the raw output: the notes, a few lines copied from it (Notes.swift). This turn's always; earlier ones if related.
        ctx.add("What the steps found", notesText(state, turn: state.turns), priority: 0, maxChars: 2500)
        ctx.add("Found earlier in this chat", notesText(state, before: state.turns, topic: topic), priority: 2, maxChars: 800)
        ctx.add("Commands that check the latest findings", (state.hints ?? []).joined(separator: "\n"), priority: 1, maxChars: 900)
        ctx.add("Unfinished request (the user's message may answer it; then propose the completed steps)", draft ?? "", priority: 0,
                maxChars: 1200)
        ctx.add("Proposal the user is filling in (to change it, propose the same action with only the fields to change)",
                editing.isEmpty ? "" : form, priority: 0, maxChars: 1500)
        ctx.add(question == nil ? "Task" : "User",
                question ?? "Answer the user's last request from what the steps found: quote the lines and numbers that answer it. If they don't answer it, say what is missing.",
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
            // The English text is what later requests are matched against; the question keeps the user's words.
            graph.upsert(GraphNode(id: id, kind: "intent", name: phrase, text: topic,
                                   props: ["question": .string(question), "intent": .string(phrase), "conversation": .string(run.id)]))
            if let iv = embedder.vector(phrase) { graph.setVector(id, iv) }
            graph.link("conversation:" + run.id, id, "contains")
            graph.record("asked", node: id, conversation: run.id)
            state.intent = id
            state.asked = worded
        }

        // People and addresses must come from the conversation (or Contacts), never from the model's imagination.
        // Values in the open form were said by the user (typed there) or already checked.
        let said = [question ?? "", recent, state.summary, known, draft ?? "", form, state.results.joined(separator: "\n")].joined(separator: "\n")
        var plan = Planner.Result(), tried = steps, best: (plan: Planner.Result, steps: [PlannedStep])?
        for attempt in 0...Self.repairs where !steps.isEmpty {
            tried = steps
            plan = await bind(steps, run: run, said: said, request: question ?? focus, editing: editing)
            // What was asked for was refused and only steps the request didn't ask for are left (an example's
            // "reveal"): that is nothing runnable, so the model gets to repair the step that matters.
            if editing.isEmpty, !plan.refusals.isEmpty, !plan.actions.isEmpty,
               plan.actions.allSatisfy({ Self.unasked("action:" + $0.call.spec, worded) }) {
                plan.refusals += plan.actions.map { "\($0.call.spec): not part of this request; leave it out" }
                plan.actions = []
            }
            if best.map({ Self.score(plan) > Self.score($0.plan) }) ?? true { best = (plan, steps) }
            let drafts = plan.actions.filter { $0.problems != nil }
            // Nothing runnable: up to two repairs. A draft with gaps: one, in case the request already fills them.
            guard plan.actions.isEmpty && !plan.refusals.isEmpty || !drafts.isEmpty,
                  attempt < (plan.actions.isEmpty ? Self.repairs : 1) else { break }
            // Let the model fix what the request already answers; what only the user knows becomes a question.
            emit("delta", "Filling in what's missing…")
            var fix = ctx
            let gaps = drafts.flatMap { a in (a.problems ?? [:]).sorted { $0.key < $1.key }.map { "\(a.call.spec): \($0.key.isEmpty ? "" : $0.key + ": ")\($0.value)" } }
            fix.add("Problems with the steps you proposed", Self.problems(steps, plan.refusals + gaps), priority: 0, maxChars: 1500)
            guard let again = await ask(run, &state, fix, instructions: instructions, schema: schema, emit: emit) else { return }
            answer = again
            steps = Self.steps(answer)
            reply = (answer["reply"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let best, Self.score(best.plan) > Self.score(plan) { (plan, tried) = best }

        var finding: String?
        // Nothing new came of a turn about the card being filled in: it stays open.
        if plan.actions.isEmpty, !editing.isEmpty {
            state.pending = previous
            // The model may claim it did something; nothing changed.
            if !reply.hasSuffix("?") { reply = "The card below didn't change: edit it there, or tell me what to change." }
        }
        if !plan.actions.isEmpty {
            finding = propose(run, &state, title: phrase, explanation: reply, actions: plan.actions, owner: owner(of: tried))
        }
        if !plan.refusals.isEmpty {
            if finding == nil {
                // Nothing runnable yet: keep what was tried so the user's answer can complete it, and ask.
                state.draft = Self.problems(tried, plan.refusals, request: question ?? focus)
                if !(steps.isEmpty && reply.hasSuffix("?")) {
                    let theirs = plan.refusals.filter(Self.userCanAnswer)
                    reply = theirs.isEmpty ? "I couldn't turn that into a step I can run. Could you say it another way?" : Self.askFor(theirs)
                    if theirs.count < plan.refusals.count {
                        let why = plan.refusals.filter { !Self.userCanAnswer($0) }.map { "- " + $0 }.joined(separator: "\n")
                        say(run, &state, ChatMessage("note", "What went wrong with the proposed steps:\n" + why), emit)
                    }
                    if theirs.isEmpty, let question, let out = await wayOut(run, &state, question, phrase: phrase, explore: explore, emit) {
                        (reply, finding) = out
                    }
                }
            } else {
                let why = plan.refusals.map { "- " + $0 }.joined(separator: "\n")
                say(run, &state, ChatMessage("note", "bibi left out some of the proposed steps:\n" + why), emit)
            }
        }
        // With "Let bibi look", steps that only read are about to run by themselves: no approval to ask for.
        if plan.actions.contains(where: { $0.problems != nil }) {
            reply = "Fill in what's missing below, or tell me, then approve."
        } else if finding != nil && (Self.claimsResults(reply, question: focus) || !Self.readsAsPlan(reply)) {
            // The model sometimes answers as if the steps had already run; nothing has run yet.
            reply = autoApprovable(run, state) != nil ? "Let me check." : "Here is what I'd do; approve it to run."
        }
        if reply.isEmpty, finding == nil, let question, let out = await wayOut(run, &state, question, phrase: phrase, explore: explore, emit) {
            (reply, finding) = out
        }
        if reply.isEmpty {
            reply = finding == nil ? "I don't have an answer for that." : autoApprovable(run, state) != nil ? "Let me check." : "Here is what I'd run."
        }
        say(run, &state, ChatMessage("bibi", reply, finding: finding), emit)
    }

    /// A proposal from this turn, recorded for the skill that owns it (statistics, guidance, learning).
    func propose(_ run: RunRecord, _ state: inout ChatState, title: String, explanation: String, actions: [BoundAction], owner: String) -> String {
        let finding = addProposal(run, title: title, explanation: explanation, actions: actions)
        state.pending = finding
        let g = prompts.active("skill." + (graph.node(owner)?.name ?? "generic"), default: guidanceDefault(owner))
        state.skill = owner
        state.guidance = g.version.isEmpty ? nil : g.version
        graph.record("proposed", node: owner, conversation: run.id)
        if let gv = state.guidance { graph.record("proposed", node: gv, conversation: run.id) }
        return finding
    }

    /// No tool fit: work out commands (the "Work it out" toggle) or let the model answer on its own. The reply, and
    /// the proposal when commands were worked out.
    func wayOut(_ run: RunRecord, _ state: inout ChatState, _ question: String, phrase: String, explore: Bool,
                _ emit: @escaping ChatEmit) async -> (String, String?)? {
        if explore, let r = await self.explore(run, &state, question, emit) {
            guard !r.actions.isEmpty else { return (r.reply, nil) }
            return (r.reply, propose(run, &state, title: phrase, explanation: r.reply, actions: r.actions, owner: GraphSync.root))
        }
        return await fallback(run, &state, question, emit).map { ($0, nil) }
    }

    static let ownAnswerNote = "No tool fit this request, so this is the model's own answer: nothing on this Mac was checked."

    /// The way out when no tool fits: the model answers the user's own words on its own, as `fm respond` would from a
    /// shell, without bibi's tools, examples or rules. Nothing runs, and a note says nothing on this Mac was checked.
    func fallback(_ run: RunRecord, _ state: inout ChatState, _ question: String, _ emit: ChatEmit) async -> String? {
        emit("delta", "Trying on my own…")
        guard let r = try? await model(run).respond(question, instructions: prompts.text("chat.fallback", default: Self.fallbackInstructions),
                                                    schema: Self.fallbackSchema),
              let own = r["reply"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !own.isEmpty else { return nil }
        if let id = state.intent { graph.record("fallback", node: id, conversation: run.id) }
        say(run, &state, ChatMessage("note", Self.ownAnswerNote), emit)
        return own
    }

    /// True if a message whose words selected `tools` can be the answer to `draft`: it brings in no built-in app
    /// action the draft didn't use. "rappelle-moi de tester les emails" after an unfinished email also selects mail
    /// (it says "emails"), but reminders too: a new request. Skills and discovered apps match too loosely to count.
    static func continues(_ draft: String, tools: [String]) -> Bool {
        // Actions of one app count as one family (mail_send and mail_accounts both belong to Mail).
        func family(_ tool: String) -> String { tool.hasPrefix("action:") ? Recipes.apps[String(tool.dropFirst(7))] ?? tool : tool }
        let wanted = Set(tools.filter { $0.hasPrefix("action:") && Recipes.apps[String($0.dropFirst(7))] != nil }.map(family))
        let tried = Set(Re.all(#"(?m)^Step: (\S+)"#, draft).compactMap { $0.count > 1 ? family($0[1]) : nil })
        return wanted.subtracting(tried).isEmpty
    }

    /// How many times the model may fix refused steps before bibi asks the user.
    static let repairs = 2

    /// How good a bound plan is: runnable actions first, then fewer gaps and refusals.
    /// A built-in app action the request's words didn't select: an example brought it in, not the request.
    static func unasked(_ tool: String, _ worded: [String]) -> Bool {
        tool.hasPrefix("action:") && actionHints[String(tool.dropFirst(7))] != nil && !worded.contains(tool)
    }

    static func score(_ p: Planner.Result) -> Int {
        let ready = p.actions.filter { $0.problems == nil }.count
        let gaps = p.actions.reduce(0) { $0 + ($1.problems?.count ?? 0) }
        return ready * 100 + p.actions.count * 10 - gaps - p.refusals.count
    }

    /// Words that name a field in a message ("mets plutôt le sujet…", "change the message"), besides its label.
    static let fieldWords: [String: [String]] = [
        "body": ["body", "message", "texte", "text", "corps", "contenu", "content"],
        "subject": ["subject", "sujet", "objet", "titre"],
        "to": ["destinataire", "destinataires", "recipient", "recipients"],
        "from": ["from", "expéditeur", "sender", "compte", "account", "depuis"],
        "cc": ["cc", "copie"],
        "title": ["title", "titre", "nom", "name"],
        "start": ["start", "début", "heure", "time", "date", "quand", "when"],
        "end": ["end", "fin", "durée", "until", "jusqu'à"],
        "due": ["due", "échéance", "heure", "time", "date", "quand", "when"],
        "location": ["location", "lieu", "où", "where"],
        "notes": ["notes", "note"],
        "text": ["text", "texte", "message"],
        "calendar": ["calendar", "calendrier"],
        "list": ["list", "liste"],
    ]

    /// True if `message` talks about the field (by one of its words or its label).
    static func names(_ key: String, _ label: String?, in message: String) -> Bool {
        let m = message.lowercased()
        // Short labels ("To", "Cc") are everyday words; their field words above cover them.
        let words = (fieldWords[key] ?? []) + (label.flatMap { $0.count > 3 ? [$0.lowercased()] : nil } ?? [])
        return words.contains { Re.test("(?<![\\p{L}])" + NSRegularExpression.escapedPattern(for: $0) + "(?![\\p{L}])", m) }
    }

    /// The not-yet-run actions with form fields in the proposal waiting for decisions.
    func openForms(_ run: RunRecord, _ finding: String?) -> [BoundAction] {
        guard let finding else { return [] }
        let done = Set(run.journalEntries.filter { $0.event == .executed }.compactMap(\.actionID))
        return (run.report()?.findings.first { $0.id == finding }?.recommendations ?? []).filter {
            !done.contains($0.id) && harness.registry.spec($0.call.spec)?.fields.isEmpty == false
        }
    }

    static let plainEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    /// An open form as the model sees it: the step it would propose, and what is still missing.
    static func formText(_ a: BoundAction) -> String {
        let args = a.call.params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        // Unescaped ("https://", not "https:\/\/"): the grounding checks read this text too.
        let list = (try? Self.plainEncoder.encode(args)).flatMap { String(data: $0, encoding: .utf8) } ?? JSON.string(args)
        return (["Step: action:\(a.call.spec) \(list)"]
                + (a.problems ?? [:]).sorted { $0.key < $1.key }.map { "Missing: \($0.key.isEmpty ? "" : $0.key + ": ")\($0.value)" })
            .joined(separator: "\n")
    }

    /// One model call, shortening the prompt when it overflows the context. The instructions and the schema take
    /// their share of the window first; the prompt gets the rest, up to `budget`. Says what went wrong and returns
    /// nil when it can't answer.
    func ask(_ run: RunRecord, _ state: inout ChatState, _ ctx: ContextBuilder, instructions: String, schema: Schema,
             emit: @escaping ChatEmit) async -> JSONValue? {
        let model = model(run)
        let fixed = Int(Double(instructions.count + schema.estimatedChars) * 1.3)
        var budget = max(Self.minPromptChars, min(self.budget, Self.contextChars - fixed))
        for _ in 0..<4 {
            do {
                return try await model.stream(ctx.build(budget: budget).text, instructions: instructions, schema: schema) { partial in
                    if let r = partial["reply"]?.string, !r.isEmpty { emit("delta", r) }
                }
            } catch let e as LLMError where e.contextOverflow {
                // Counted, so `make eval` and the Graph page show how often the estimate was wrong.
                graph.record("overflow", node: state.intent ?? GraphSync.root, conversation: run.id, payload: .number(Double(budget)))
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
    func bind(_ steps: [PlannedStep], run: RunRecord, said: String, request: String, editing: [BoundAction] = []) async -> Planner.Result {
        let planner = Planner(registry: harness.registry, env: harness.env(admin: NoAdminRunner(), reporter: SilentReporter()),
                              skill: { [harness] in harness.skill(named: $0) })
        // A step for an action the user is filling in starts from the form's values; the step's own values win,
        // except over a field the user typed by hand, unless their message talks about that field.
        var handTyped: [String: [String]] = [:]  // action spec → fields the user typed that stay theirs
        let merged = Planner.prepare(steps).map { s -> PlannedStep in
            guard let a = editing.first(where: { "action:" + $0.call.spec == s.tool }) else { return s }
            var s = s
            let fields = harness.registry.spec(a.call.spec)?.fields ?? []
            let kept = (a.edited ?? []).filter { key in !Self.names(key, fields.first { $0.key == key }?.label, in: request) }
            handTyped[a.call.spec] = kept
            s.args = a.call.params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                + s.args.filter { arg in !kept.contains(arg.split(separator: "=", maxSplits: 1).first.map(String.init)?.lowercased() ?? "") }
            return s
        }
        let prepared = Recipes.groundNames(Recipes.groundDates(merged, request: request), said: said)
        let people = await Recipes.resolveRecipients(prepared, contacts: harness.apps.contacts, said: said)
        let links = Recipes.unknownLinks(people.steps, said: said)
        var plan = Planner.Result()
        for (s, gaps) in zip(people.steps, zip(people.problems, links).map { $0.merging($1) { a, _ in a } }) {
            switch planner.bind(s) {
            case .success(let actions):
                // A recipient taken out of a step says why under its field.
                plan.actions += actions.map { a in
                    var a = a
                    if let kept = handTyped[a.call.spec], !kept.isEmpty { a.edited = kept }
                    if !gaps.isEmpty { a.problems = (a.problems ?? [:]).merging(gaps) { _, why in why } }
                    return a
                }
            case .failure(let e): plan.refusals.append(e.description)
            }
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

    /// Problems the user can resolve (who, which address, what to say, which list), as opposed to the model
    /// writing a step wrong, which the user can't fix and shouldn't be asked about.
    static func userCanAnswer(_ refusal: String) -> Bool {
        ["wasn't mentioned", "isn't in Contacts", "matches", "has several", "has no email", "has no phone", "has no text yet",
         "missing parameter", "there is no calendar named", "there is no list named", "is called", "no open reminder",
         "isn't allowed to use"].contains { refusal.contains($0) }
    }

    /// The question bibi asks when the model couldn't fix the steps itself.
    static func askFor(_ refusals: [String]) -> String {
        // "mail_send: the email has no text yet (...)" reads better without the action id.
        let lines = refusals.map { r in "- " + (Re.test("^[a-z_]+: ", r) ? String(r[r.index(after: r.firstIndex(of: ":")!)...]).trimmingCharacters(in: .whitespaces) : r) }
        return "I need a bit more before I can do this:\n" + lines.joined(separator: "\n") + "\nTell me and I'll propose it again."
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
    func owner(of steps: [PlannedStep]) -> String { GraphTuning.owner(of: steps, graph: graph) }

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
                let described = GraphSync.text(n)
                let hits = Similarity.hits(text, GraphSync.keywords(n) + " " + described)
                guard hits > 0 else { return nil }
                var nv = graph.vector(n.id)
                if nv == nil, let x = embedder.vector(described) { graph.setVector(n.id, x); nv = x }
                let sim = nv.flatMap { a in v.map { Similarity.cosine(a, $0) } } ?? 0
                return (n, (Double(hits) + sim) * (0.5 + 0.5 * graph.approvalRate(n.id)))
            }
            .sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// What a request would retrieve, without asking the model (the Graph page's "Try it"): the same steps as a
    /// turn, minus translation and open forms.
    public struct Retrieval: Codable, Sendable {
        public var skills: [String]
        public var examples: [String]
        public var tools: [String]
    }

    public func retrieval(_ text: String) -> Retrieval {
        let v = embedder.vector(text)
        let skills = rankSkills(text, v)
        let shown = exampleIntents(text, tools: toolCatalog(skills, request: text, examples: [], vector: v).ids)
        return Retrieval(skills: skills.map(\.name), examples: shown.map(\.id),
                         tools: toolCatalog(skills, request: text, examples: shown, vector: v).ids)
    }

    func toolCatalog(_ skills: [GraphNode], request raw: String, examples: [GraphNode], vector: [Float]? = nil) -> (ids: [String], text: String) {
        // "https" in a pasted link shouldn't offer whatever mentions http.
        let request = raw.replacingOccurrences(of: #"\S+://\S+|\S+@\S+\.\S+"#, with: " ", options: .regularExpression)
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
        // Discovered app capabilities, when no built-in app action fits or the message names the app: a small model
        // picks whatever is listed, and "email" also matches Safari's "email contents".
        // "launch garageband" is open_app, not PowerPoint's "launch speller": while it is offered, an app's own
        // tools only show when the message names that app.
        let covered = Set(ids.compactMap { $0.hasPrefix("action:") ? Recipes.apps[String($0.dropFirst(7))] : nil })
        let launching = ids.contains("action:open_app")
        for n in rankCapabilities(request, vector, examples: used) {
            guard let bundle = n.props["app"]?.string, !covered.contains(bundle), let app = harness.apps.catalog.app(bundle),
                  covered.isEmpty && !launching || Recipes.mentioned(app.name, in: request),
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

    /// The request in English (retrieval, examples and embeddings are English), or the request itself when it
    /// already is or the model can't translate it.
    func english(_ run: RunRecord, _ text: String) async -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        // Short or mixed messages ("ok", "try again") stay as they are: a guess would only cost a model call.
        guard let (lang, p) = recognizer.languageHypotheses(withMaximum: 1).first, lang != .english, p >= 0.5,
              let r = try? await model(run).respond(text, instructions: prompts.text("chat.translate", default: Self.translateInstructions),
                                                     schema: Self.translateSchema),
              let t = r["english"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return text }
        return Text.clip(t, max: 2000)
    }

    /// Up to three requests that worked (learned or seeded) sharing words with this one, best first; learned
    /// ones win ties and frequently matched ones rank higher. One shared word is chance (a name, "repo") unless
    /// the example used a tool this request's own words select (its `used` edges in the graph).
    func exampleIntents(_ text: String, tools: [String]) -> [GraphNode] {
        let terms = Similarity.terms(text), selected = Set(tools).subtracting(["command"])
        let ranked = graph.nodes(kind: "intent").filter { $0.props["outcome"]?.string == "ok" && $0.status != "disabled" }
            .compactMap { n -> (GraphNode, Double)? in
                let hits = terms.intersection(Similarity.terms(GraphSync.text(n))).count
                let answered = Set(graph.edges(from: n.id, kind: "used").map(\.dst) + SkillMiner.steps(n).map(\.tool))
                guard hits >= 2 || hits == 1 && !answered.isDisjoint(with: selected) else { return nil }
                let used = graph.edges(from: n.id, kind: "matched").reduce(0) { $0 + $1.weight }
                return (n, Double(hits) + (n.props["seed"] == nil ? 0.5 : 0) + min(1, used / 10))
            }
            .sorted { $0.1 > $1.1 }
        var seen = Set<String>(), out: [GraphNode] = []
        for (n, _) in ranked where out.count < 3 && seen.insert(GraphSync.text(n).lowercased()).inserted { out.append(n) }
        return out
    }

    /// Free text of an earlier message (its body, its title): left out of examples, so the model takes the shape
    /// of the step and writes the content from this request.
    static let contentKeys: Set<String> = ["body", "subject", "text", "title", "notes", "location"]

    func examples(_ intents: [GraphNode]) -> String {
        intents.map { n in
            let steps = SkillMiner.steps(n).map { st in
                let args = st.args.filter { a in
                    guard st.tool.hasPrefix("action:"), let eq = a.firstIndex(of: "=") else { return true }
                    return !Self.contentKeys.contains(String(a[..<eq]))
                }
                return "\(st.tool) " + JSON.string(args)
            }.joined(separator: "; ")
            return "\"\(Text.oneLine(GraphSync.text(n), max: 100))\" → \(steps)"
        }.joined(separator: "\n")
    }

    func facts(_ text: String, _ v: [Float]?) -> String {
        var seen = Set<String>()
        let pool = (graph.search(text, kind: "fact", limit: 10) + graph.nodes(kind: "fact").prefix(40))
            .filter { seen.insert($0.id).inserted && !Self.isRequest($0.text) }
        return pool.map { ($0, Similarity.score(text, v, $0.name + " " + $0.text, graph.vector($0.id))) }
            .filter { $0.1 >= 0.35 }.sorted { $0.1 > $1.1 }.prefix(3)
            .map { "- \($0.0.text) (\(ago($0.0.updated)))" }.joined(separator: "\n")
    }

    /// The last few messages for the prompt; with `since`, only those after the message carrying that proposal.
    func recentText(_ state: ChatState, dropLastUser: Bool, since finding: String? = nil) -> String {
        var msgs = state.recent
        if let finding, let i = msgs.lastIndex(where: { $0.finding == finding }) { msgs = Array(msgs[(i + 1)...]) }
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
        if let a = approved.first(where: { $0.problems != nil }) {
            let fields = (a.problems ?? [:]).keys.filter { !$0.isEmpty }.sorted()
            throw ActionError("\(a.title): fill in \(fields.isEmpty ? "what's missing" : fields.joined(separator: ", ")) first")
        }
        let skipped = d.skip.compactMap(report.action)
        let owner = state.skill ?? GraphSync.root
        let skillName = graph.node(owner)?.name ?? "generic"

        if !d.dryRun {
            for _ in approved { record(d.auto ? "auto" : "approved", owner, state, run) }
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
        let performed = await perform(approved, run: run, state: &state, dryRun: d.dryRun, adminConfirmed: d.adminConfirmed,
                                      admin: admin, reporter: reporter, emit: emit)
        var results = performed.results
        if let pending = state.pending, let f = run.report()?.findings.first(where: { $0.id == pending }) {
            let decided = Set(d.approve + d.skip).union(done)
            if f.recommendations.allSatisfy({ decided.contains($0.id) }) { state.pending = nil }
        }
        if let next = performed.next { state.pending = next }

        // "Let bibi look": from what the steps found, the next read-only steps, until the notes answer the request.
        // Not while a skill's own proposal waits for a decision.
        var worked = approved, paused = false
        if !d.dryRun, state.look == true, state.pending == nil, !results.isEmpty {
            let more = await look(run, &state, admin: admin, reporter: reporter, emit: emit)
            worked += more.actions; results += more.results; paused = more.paused
        }

        if !d.dryRun, let intent = state.intent {
            // A step the request didn't ask for (an example's "reveal") ran, but it isn't how this request is answered.
            let ok = worked.filter { a in results.contains { $0.actionID == a.id && $0.ok } }.map(PlannedStep.from)
                .filter { s in state.asked.map { !Self.unasked(s.tool, $0) } ?? true }
            if !ok.isEmpty {
                await learn(intent, ok, owner: owner, run: run, state: &state, emit: emit)
            }
        }
        prompts.evaluate("skill." + skillName)

        // Paused: a card waits for the user; the answer comes once they decide. Skipping that card still gets an
        // answer from what was found before it.
        let found = state.look == true && !notesText(state, turn: state.turns).isEmpty
        if !d.dryRun && (!results.isEmpty || found) && !paused {
            await think(run, &state, question: nil, emit: emit)
            state.results = []
        }
        await compact(run, &state)
        save(run, state)
        return results
    }

    /// Runs steps through the harness (validation, journal, admin confirmation), shows each result, and keeps notes
    /// of what they found. Returns the results and, when a skill ran, the id of its own proposal.
    func perform(_ approved: [BoundAction], run: RunRecord, state: inout ChatState, dryRun: Bool, adminConfirmed: Bool,
                 admin: any AdminRunner, reporter: ChatReporter, emit: @escaping ChatEmit) async -> (results: [ExecResult], next: String?) {
        let owner = state.skill ?? GraphSync.root
        let env = harness.env(admin: admin, reporter: reporter)
        var results = await harness.execute(approved.filter { $0.call.spec != "run_skill" }, run: run, env: env,
                                            adminConfirmed: adminConfirmed, dryRun: dryRun, frontend: "chat")
        var next: String?
        for a in approved where a.call.spec == "run_skill" {
            let (r, fid, hints, candidate) = await runSkill(a, run, dryRun: dryRun, reporter: reporter)
            results.append(r)
            if let fid { next = fid }
            if !hints.isEmpty { state.hints = hints }
            // skills.create drafted a skill: it gets the same card as one learned from repeated requests.
            if let candidate, let c = graph.node(candidate) {
                state.candidates.append(c.id)
                emit("candidate", JSON.string(SkillLibrary.view(c, graph: graph)))
            }
        }

        for r in results {
            let output = r.output.map { "\n" + Text.clip($0, max: 4000) } ?? ""
            say(run, &state, ChatMessage("result", "\(r.title): \(r.message)\(output)", actionID: r.actionID, ok: r.ok), emit)
            if !dryRun { graph.record(r.ok ? "executed" : "failed", node: owner, conversation: run.id) }
        }
        // The raw output stays at hand (clipped) to ground names and addresses the model uses; the model itself
        // sees the notes.
        state.results += results.map { r in
            "\(r.ok ? "OK" : "FAILED") \(r.title): \(r.message)" + (r.output.map { "\n" + Text.clip(Text.collapseRepeats($0), max: 1500) } ?? "")
        }
        if !dryRun {
            let request = state.intent.flatMap { graph.node($0)?.props["question"]?.string } ?? ""
            var notes = state.notes ?? []
            for r in results {
                notes += await self.notes(for: r, purpose: approved.first { $0.id == r.actionID }?.title ?? r.title,
                                          request: request, turn: state.turns, run: run)
            }
            state.notes = notes
        }
        return (results, next)
    }

    /// Changes fields of a proposed action from the form on its card, checks them again and saves the proposal.
    /// What the user types there is their own word, so it needs no grounding; empty clears a field.
    @discardableResult
    public func edit(_ run: RunRecord, action id: String, changes: [String: String]) throws -> BoundAction {
        let state = state(run)
        guard var report = run.report(), let fi = report.findings.firstIndex(where: { $0.id == state.pending }),
              let ai = report.findings[fi].recommendations.firstIndex(where: { $0.id == id }) else {
            throw ActionError("\(id) isn't part of the open proposal")
        }
        guard !run.journalEntries.contains(where: { $0.event == .executed && $0.actionID == id }) else { throw ActionError("that step already ran") }
        var a = report.findings[fi].recommendations[ai]
        guard let spec = harness.registry.spec(a.call.spec), !spec.fields.isEmpty else { throw ActionError("\(a.title) has no fields to change") }
        let env = harness.env(admin: NoAdminRunner(), reporter: SilentReporter())
        var params = a.call.params
        for (k, v) in changes {
            guard spec.fields.contains(where: { $0.key == k }) else { throw ActionError("\(spec.id) has no field \(k)") }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            params[k] = t.isEmpty ? nil : t
        }
        a.call.params = spec.normalize(params, env)
        let problems = spec.problems(a.call.params, env)
        a.problems = problems.isEmpty ? nil : problems
        a.command = problems.isEmpty ? harness.registry.preview(a.call, env).steps.joined(separator: "; ") : spec.describe(a.call.params)
        a.target = problems.isEmpty ? a.call.params.values.sorted().joined(separator: " ") : ""
        a.edited = Array(Set(a.edited ?? []).union(changes.keys)).sorted()
        report.findings[fi].recommendations[ai] = a
        run.save(report)
        run.journal(JournalEntry(.edited, actionID: a.id, title: a.title, call: a.call,
                                 message: "changed " + changes.keys.sorted().joined(separator: ", "), frontend: "chat"))
        return a
    }

    func record(_ kind: String, _ owner: String, _ state: ChatState, _ run: RunRecord) {
        graph.record(kind, node: owner, conversation: run.id)
        if let g = state.guidance { graph.record(kind, node: g, conversation: run.id) }
    }

    /// Runs a skill the user approved from chat. Its summary becomes evidence; its recommendations come back as
    /// a new proposal in this chat (so they need their own approval). Returns that proposal's id, diagnostic hints,
    /// and the skill it drafted (skills.create).
    func runSkill(_ a: BoundAction, _ run: RunRecord, dryRun: Bool, reporter: any Reporter) async -> (ExecResult, String?, [String], String?) {
        let name = a.call.params["skill"] ?? "", argv = CommandPolicy.decode(a.call.params["argv"] ?? "[]") ?? []
        func fail(_ m: String) -> (ExecResult, String?, [String], String?) {
            run.journal(JournalEntry(.failed, actionID: a.id, title: a.title, call: a.call, error: m, frontend: "chat"))
            return (ExecResult(actionID: a.id, title: a.title, ok: false, message: m, reversible: false), nil, [], nil)
        }
        guard let skill = harness.skill(named: name) else { return fail("unknown skill \(name)") }
        run.journal(JournalEntry(.selected, actionID: a.id, title: a.title, call: a.call, frontend: "chat"))
        if dryRun {
            let m = "[dry-run] would run bibi \(name) \(Shell.join(argv))"
            run.journal(JournalEntry(.dryRun, actionID: a.id, title: a.title, call: a.call, message: m, frontend: "chat"))
            return (ExecResult(actionID: a.id, title: a.title, ok: true, message: m, reversible: false), nil, [], nil)
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
                    Self.hints(result.findings), result.facts["candidate"]?.string)
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
        // Which actions and skills answered it: retrieval follows these, and they show what an example teaches.
        for tool in Set(worked.map(\.tool)) {
            let node = tool.hasPrefix("skill:") ? GraphSync.skillID(String(tool.dropFirst(6))) : tool
            if graph.node(node) != nil { graph.strengthen(intent, node, "used") }
        }
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
        // Notes are the current task's working memory; older ones are in the summary through their result messages.
        let kept = (state.notes ?? []).filter { $0.turn >= state.turns - 1 }
        state.notes = kept.isEmpty ? nil : kept
        guard state.recent.count > Self.keepMessages else { return }
        let msgs = Array(state.recent.dropLast(Self.keepMessages))
        state.recent = Array(state.recent.suffix(Self.keepMessages))
        let line = { (m: ChatMessage) in
            "\(["user": "User", "bibi": "bibi", "result": "Result", "note": "Note"][m.role] ?? m.role): \(Text.clip(m.text, max: 500))"
        }
        let lines = msgs.map(line).joined(separator: "\n")
        // Messages bibi answered with a proposal are requests: what someone wanted, not evidence that it happened
        // ("an email was sent" when only a Finder window opened).
        let asked = Set(msgs.indices.filter { i in
            msgs[i].role == "user" && msgs[(i + 1)...].first(where: { $0.role == "bibi" })?.finding != nil
        })
        // Facts are checked against what was said and seen, never against the summary the model just wrote.
        let source = msgs.indices.filter { !asked.contains($0) }.map { line(msgs[$0]) }.joined(separator: "\n") + "\n" + state.summary
        let prompt = "Summary so far:\n\(state.summary.ifEmpty("(none)"))\n\nNew messages:\n\(lines)"
        if let r = try? await model(run).respond(prompt, instructions: prompts.text("chat.compact", default: Self.compactInstructions),
                                                 schema: Self.compactSchema),
           let s = r["summary"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            state.summary = Text.clip(s, max: 1200)
            for f in r["facts"]?.array ?? [] {
                if let subject = f["subject"]?.string, let statement = f["statement"]?.string, Self.grounded(statement, in: source),
                   !asked.contains(where: { Similarity.jaccard(msgs[$0].text, statement) >= 0.6 }) {
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
        guard words.count >= 3, statement.split(separator: " ").count >= 4, !isRequest(statement),
              !["i'll", "i will", "result:", "bibi will", "bibi"].contains(where: { lower.hasPrefix($0) }),
              numbers(statement).isSubset(of: numbers(source)) else { return false }
        return Double(words.intersection(Similarity.terms(source)).count) / Double(words.count) >= 0.6
    }

    /// "The user asked for an email to…": what someone wanted once, not a fact about the Mac or the user. Kept as
    /// a fact, it steers every later turn back to that request.
    static func isRequest(_ statement: String) -> Bool {
        Re.test(#"^(the )?user (asked|requested|wants|wanted|would like|needs|is asking)|^(a |the )?request"#, statement.lowercased())
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
