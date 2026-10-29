import Foundation

/// The way out, worked out (the chat's "Work it out" toggle): when no tool fits, the model first says in plain words
/// what would answer the request, then turns each step into one command, one small call per step. bibi's rules check
/// each command and a refused one goes back with the reason. What passes is an ordinary proposal: nothing runs
/// before approval, and approved steps feed learning like any others.
extension ChatEngine {
    static let explorePlanInstructions = """
    You are bibi, an assistant on the user's Mac (macOS). No ready-made tool fits the user's request.
    needs_actions: true when the answer depends on this Mac (its logs, files, settings, processes, history) and commands could find it out; false when you can answer from general knowledge.
    steps: with needs_actions, at most 4 short steps in plain words, each one thing to look up or do on the Mac, like "list crash reports from the last day". Only look things up unless the user asked for a change.
    reply: with steps, one sentence on what they will find out (their results aren't known yet); without, your answer, brief. Always in the user's language. Never invent output or numbers.
    """

    static let exploreCommandInstructions = """
    You turn one step into one macOS command. args: the program, then each argument separately, like ["log", "show", "--last", "24h"].
    There is no shell: no pipes |, no redirections, no ; or &&, no $(...), no wildcards. Filter with the program's own options instead (log show --predicate, find -mtime, mdfind). Use absolute paths or ~. Prefer read-only commands; start with sudo only when administrator rights are needed.
    """

    static let explorePlanSchema = Schema("ExplorePlan", [
        .init("needs_actions", .bool, "true when commands on this Mac would answer it"),
        .init("steps", .array(.string, max: 4), "plain-language steps; empty without needs_actions"),
        .init("reply", .string, "with steps: what they will find out; without: your answer"),
    ])

    static let exploreCommandSchema = Schema("ExploreCommand", [
        .init("args", .array(.string, max: 16), "the program, then each argument"),
    ])

    /// Tries per step: the first command, then one repair from the reason it was refused.
    static let exploreTries = 2

    /// The plan's reply and the commands that passed bibi's rules; nil when the model couldn't plan at all.
    func explore(_ run: RunRecord, _ state: inout ChatState, _ question: String,
                 _ emit: @escaping ChatEmit) async -> (reply: String, actions: [BoundAction])? {
        emit("delta", "Working it out…")
        var ctx = ContextBuilder()
        ctx.add("Now", DateText.formatter("EEEE yyyy-MM-dd HH:mm").string(from: Date()), priority: 0)
        ctx.add("User", question, priority: 0)
        guard let plan = await ask(run, &state, ctx, instructions: prompts.text("chat.explore", default: Self.explorePlanInstructions),
                                   schema: Self.explorePlanSchema, emit: emit) else { return nil }
        if let id = state.intent { graph.record("explored", node: id, conversation: run.id) }
        let reply = (plan["reply"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = Array((plan["steps"]?.strings ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(4))
        guard plan["needs_actions"]?.bool == true, !steps.isEmpty else {
            guard !reply.isEmpty else { return nil }
            say(run, &state, ChatMessage("note", Self.ownAnswerNote), emit)
            return (reply, [])
        }

        let instructions = prompts.text("chat.explore.command", default: Self.exploreCommandInstructions)
        var actions: [BoundAction] = [], failed: [String] = []
        for (i, step) in steps.enumerated() {
            emit("delta", "Working out step \(i + 1) of \(steps.count): \(step)")
            let ask = "Request: \(Text.oneLine(question, max: 300))\nStep: \(step)"
            var prompt = ask, bound: [BoundAction] = []
            for _ in 0..<Self.exploreTries {
                guard let r = try? await model(run).respond(prompt, instructions: instructions, schema: Self.exploreCommandSchema) else { break }
                let args = r["args"]?.strings ?? []
                let p = await bind([PlannedStep(tool: "command", args: args, purpose: step)], run: run, said: question, request: question)
                if !p.actions.isEmpty { bound = p.actions; break }
                // Neither runnable nor refused: this chat already proposed that command.
                guard let why = p.refusals.first else { break }
                prompt = ask + "\nYour last command: \(JSON.string(args))\nRefused: \(why)\nWrite a command that avoids this."
            }
            if bound.isEmpty { failed.append(step) }
            actions += bound.filter { a in !actions.contains { $0.call == a.call } }
        }
        guard !actions.isEmpty else {
            return ("I worked out what to check, but couldn't turn it into commands bibi can run:\n" + steps.map { "- " + $0 }.joined(separator: "\n"), [])
        }
        if !failed.isEmpty {
            say(run, &state, ChatMessage("note", "bibi couldn't turn these steps into commands it can run:\n" + failed.map { "- " + $0 }.joined(separator: "\n")), emit)
        }
        say(run, &state, ChatMessage("note", "No tool fit, so bibi worked these commands out on its own: read each one before you approve it."), emit)
        return (reply.ifEmpty("Here is what I'd run."), actions)
    }
}
