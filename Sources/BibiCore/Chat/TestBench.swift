import Foundation

/// Settings' Test bench: what chat would do with a request, without a conversation. It retrieves exactly as a
/// first turn does (`pick`, `turnContext`, `turnInstructions`), optionally asks the model and binds its steps with
/// bibi's rules, and shows the prompt, its sections and its size. Nothing is saved, proposed or run: no run, no
/// intent node, no events (only embeddings may be cached).
extension ChatEngine {
    public struct Tokens: Codable, Sendable {
        public var instructions: Int
        public var prompt: Int
        public var schema: Int
        public var total: Int
        /// The on-device model's whole window, for scale.
        public var window = 4096
    }

    public struct BenchSection: Codable, Sendable {
        public var title: String
        public var chars: Int
        public var cap: Int
        public var priority: Int
        /// Dropped to fit the budget.
        public var dropped: Bool
    }

    public struct BenchStep: Codable, Sendable {
        public var title: String
        public var command: String
        public var kind: String
        public var problems: [String: String]?
    }

    public struct DryTurn: Codable, Sendable {
        public var request: String
        /// The request as retrieval saw it, when it was translated.
        public var english: String?
        public var skills: [String]
        public var examples: [String]
        public var tools: [String]
        public var instructions: String
        public var prompt: String
        public var sections: [BenchSection]
        public var budget: Int
        public var tokens: Tokens
        /// With the model:
        public var answer: JSONValue?
        public var error: String?
        public var seconds: Double?
        public var steps: [BenchStep]?
        public var refusals: [String]?
    }

    public func dryTurn(_ request: String, askModel: Bool) async -> DryTurn {
        let question = Text.clip(request.trimmingCharacters(in: .whitespacesAndNewlines), max: knobs.int(.inputMax))
        let english = askModel ? await english(nil, question) : question
        let words = english == question ? question : question + "\n" + english
        let v = embedder.vector(english)
        let picked = pick(english, words: words, vector: v, examples: true)
        let state = ChatState(id: "bench", title: "Test bench")
        let (ctx, _, _) = turnContext(state, question: question, topic: english, vector: v, tools: picked.tools.text, shown: picked.shown,
                                      previous: nil, draft: nil, form: "", editing: false)
        let instructions = turnInstructions()
        let schema = Self.turnSchema(picked.tools.ids)
        let budget = promptBudget(instructions: instructions, schema: schema)
        let built = ctx.build(budget: budget)
        let tokens = Tokens(instructions: Text.estimatedTokens(instructions), prompt: Text.estimatedTokens(built.text),
                            schema: Text.estimatedTokens(chars: schema.estimatedChars),
                            total: Text.estimatedTokens(chars: instructions.utf8.count + built.text.utf8.count + schema.estimatedChars))
        var out = DryTurn(request: question, english: english == question ? nil : english, skills: picked.skills.map(\.name),
                          examples: picked.shown.map { "\(GraphSync.text($0)) → " + SkillMiner.steps($0).map { "\($0.tool) \(Shell.join($0.args))" }.joined(separator: "; ") },
                          tools: picked.tools.ids, instructions: instructions, prompt: built.text,
                          sections: ctx.sections.map { BenchSection(title: $0.title, chars: $0.body.count, cap: $0.maxChars, priority: $0.priority,
                                                                    dropped: built.dropped.contains($0.title)) },
                          budget: budget, tokens: tokens)
        guard askModel else { return out }
        let start = Date()
        do {
            let answer = try await harness.model.respond(built.text, instructions: instructions, schema: schema)
            out.seconds = Date().timeIntervalSince(start)
            out.answer = answer
            let plan = await bind(Self.steps(answer), run: nil, said: question, request: question)
            out.steps = plan.actions.map { BenchStep(title: $0.title, command: $0.command, kind: $0.kind, problems: $0.problems) }
            out.refusals = plan.refusals
        } catch {
            out.seconds = Date().timeIntervalSince(start)
            out.error = "\(error)"
        }
        return out
    }

    /// The `chat.extract` path on pasted output: the lines the model picked that really are in the output.
    public func tryExtract(output: String, purpose: String, request: String) async -> [String] {
        let r = ExecResult(actionID: "bench", title: purpose, ok: true, message: "", reversible: false, output: output)
        return await notes(for: r, purpose: purpose, request: request, turn: 0, run: nil).map(\.text)
    }
}

extension Harness {
    /// The result of trying one prompt on its own (Settings → Prompts → Try).
    public struct PromptTrial: Codable, Sendable {
        public var answer: JSONValue?
        public var error: String?
        public var seconds: Double
        public var tokens: ChatEngine.Tokens
    }

    /// Sends `input` with `instructions` (the edited, unsaved text) and the prompt's own schema. Nothing is recorded.
    public func tryPrompt(_ def: PromptDefinition, instructions: String, input: String) async -> PromptTrial {
        let schema = def.schema ?? Schema("Reply", [.init("reply", .string)])
        let tokens = ChatEngine.Tokens(instructions: Text.estimatedTokens(instructions), prompt: Text.estimatedTokens(input),
                                       schema: Text.estimatedTokens(chars: schema.estimatedChars),
                                       total: Text.estimatedTokens(chars: instructions.utf8.count + input.utf8.count + schema.estimatedChars))
        let start = Date()
        do {
            let r = try await model.respond(input, instructions: instructions, schema: schema)
            return PromptTrial(answer: r, error: nil, seconds: Date().timeIntervalSince(start), tokens: tokens)
        } catch {
            return PromptTrial(answer: nil, error: "\(error)", seconds: Date().timeIntervalSince(start), tokens: tokens)
        }
    }
}
