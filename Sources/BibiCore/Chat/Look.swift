import Foundation

/// "Let bibi look": steps that only read run without a card, and after each round the model reads the notes and
/// picks the next read-only steps, until they answer the request. Anything that changes the Mac is still a card.
extension ChatEngine {
    static let nextInstructions = """
    You are bibi, an assistant on the user's Mac, continuing one task. The notes are what the steps found so far.
    done: true when the notes answer the request, or when no read-only command would add to them.
    steps: otherwise, the next one or two read-only commands that get closer; args is the program, then each argument, like ["du", "-sh", "~/Downloads"]. Pick the program that answers directly: lsof -nP -iTCP:<port> for a port, find <folder> -type f for files, system_profiler for hardware, log show for logs. There is no shell: no pipes, redirections or wildcards. Never run again a program whose result is in the notes. Nothing that changes the Mac.
    reply: one short sentence on what the steps will find out; empty when done.
    """

    static let nextTask = "Do the notes answer the request? If not, the next read-only steps."

    static func nextSchema(_ tools: [String]) -> Schema {
        Schema("Next", [
            .init("done", .bool, "true when the notes answer the request, or nothing read-only would add to them"),
            .init("steps", .array(.object(Schema("Step", [
                // Every tool can be turned off in Settings; a choice needs at least one value.
                .init("tool", .choice(tools.isEmpty ? ["none"] : tools)),
                .init("args", .array(.string, max: 16), "command: the program, then each argument; action: key=value"),
                .init("purpose", .string, "a few words: what this step finds out"),
            ])), max: 2), "empty when done"),
            .init("reply", .string, "one sentence on what the steps will find out; empty when done"),
        ])
    }

    /// A step that may run without a card: a read-only command or registry action, as the user, with nothing left
    /// to fill in. Skills (slow, with proposals of their own) and app calls always get a card.
    func autoRunnable(_ a: BoundAction) -> Bool {
        guard a.privilege == .user, a.problems == nil else { return false }
        switch a.call.spec {
        case "run_command": return a.kind == CommandClass.readOnly.rawValue
        case "run_command_admin", "run_skill", "run_app_call": return false
        default: return harness.registry.spec(a.call.spec)?.kind == "read-only"
        }
    }

    /// With "Let bibi look" on: the open proposal's steps, when every one may run without a card.
    func autoApprovable(_ run: RunRecord, _ state: ChatState) -> [String]? {
        guard state.look == true, let pending = state.pending,
              let f = run.report()?.findings.first(where: { $0.id == pending }), !f.recommendations.isEmpty,
              f.recommendations.allSatisfy(autoRunnable) else { return nil }
        return f.recommendations.map(\.id)
    }

    /// Keeps looking after the steps ran: asks what to run next from the notes, runs read-only steps, and stops when
    /// the notes answer the request, at the cap, after two rounds that failed, or when a step would change the Mac.
    /// That step becomes a card (`paused`): the loop goes on once the user decides.
    func look(_ run: RunRecord, _ state: inout ChatState, admin: any AdminRunner, reporter: ChatReporter,
              emit: @escaping ChatEmit) async -> (actions: [BoundAction], results: [ExecResult], paused: Bool) {
        guard let intent = state.intent, let node = graph.node(intent) else { return ([], [], false) }
        let request = node.props["question"]?.string ?? node.text
        var ran = run.journalEntries.filter { $0.event == .executed }.compactMap(\.call)
        // Programs run so far in this task (this turn's notes), to stop the same one coming back with new flags.
        var programs = (state.notes ?? []).filter { $0.turn == state.turns }.map(\.actionID)
            .compactMap { id in run.report()?.action(id).map { PlannedStep.from($0).signature } }
        var actions: [BoundAction] = [], results: [ExecResult] = [], failures = 0
        let instructions = prompts.text("chat.next", default: Self.nextInstructions)
        // Rounds of looking per user message (each of at most two steps), and times one program may run in a task:
        // a small model re-runs `ps` with new flags instead of moving on.
        let rounds = knobs.int(.lookRounds), repeats = knobs.int(.lookRepeats)
        for i in 0..<rounds {
            let tools = toolCatalog([], request: request, examples: [])
            var ctx = ContextBuilder()
            ctx.add("Now", DateText.formatter("EEEE yyyy-MM-dd HH:mm").string(from: Date()), priority: 0)
            ctx.add("Request", request, priority: 0)
            ctx.add("Tools", tools.text, priority: 0, maxChars: knobs.int(.lookTools))
            ctx.add("What the steps found", notesText(state, turn: state.turns), priority: 0, maxChars: knobs.int(.lookNotes))
            ctx.add("Commands that check the latest findings", (state.hints ?? []).joined(separator: "\n"), priority: 1, maxChars: 900)
            ctx.add("Task", prompts.text("chat.next.task", default: Self.nextTask), priority: 0)
            emit("delta", "Looking (round \(i + 1) of \(rounds))…")
            guard let a = await ask(run, &state, ctx, instructions: instructions, schema: Self.nextSchema(tools.ids), emit: emit),
                  a["done"]?.bool != true else { break }
            let steps = Array(Self.steps(a).prefix(2))
            guard !steps.isEmpty else { break }
            let plan = await bind(steps, run: run, said: request + "\n" + state.results.joined(separator: "\n"), request: request)
            let fresh = plan.actions.filter { a in
                !ran.contains(a.call) && programs.filter { $0 == PlannedStep.from(a).signature }.count < repeats
            }
            guard !fresh.isEmpty else { break }
            let reply = (a["reply"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let finding = propose(run, &state, title: node.name, explanation: reply, actions: fresh, owner: GraphSync.root)
            let bound = run.report()?.findings.first { $0.id == finding }?.recommendations ?? []
            guard bound.allSatisfy(autoRunnable) else {
                say(run, &state, ChatMessage("bibi", reply.ifEmpty("Here is what I'd do next; approve it to run."), finding: finding), emit)
                return (actions, results, true)
            }
            for _ in bound { record("auto", GraphSync.root, state, run) }
            let r = await perform(bound, run: run, state: &state, dryRun: false, adminConfirmed: false, admin: admin,
                                  reporter: reporter, emit: emit)
            state.pending = nil
            actions += bound; results += r.results
            ran += bound.map(\.call)
            programs += bound.map { PlannedStep.from($0).signature }
            failures = r.results.allSatisfy { !$0.ok } ? failures + 1 : 0
            if failures >= 2 { break }
        }
        return (actions, results, false)
    }
}
