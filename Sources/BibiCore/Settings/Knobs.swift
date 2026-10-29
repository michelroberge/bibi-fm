import Foundation

/// One tunable number. The built-in value ships in code; an override lives in bibi.db's `settings` table.
public struct Knob: Sendable, Codable, Equatable {
    public var id: String
    public var group: String
    public var label: String
    /// What changing it does to the small on-device model.
    public var help: String
    public var builtIn: Double
    public var min: Double
    public var max: Double
    public var unit: String
    public var integer: Bool

    init(_ id: String, _ group: String, _ label: String, _ builtIn: Double, _ min: Double, _ max: Double, unit: String = "",
         integer: Bool = true, _ help: String) {
        self.id = id; self.group = group; self.label = label; self.help = help
        self.builtIn = builtIn; self.min = min; self.max = max; self.unit = unit; self.integer = integer
    }

    public func clamp(_ v: Double) -> Double {
        let c = Swift.min(max, Swift.max(min, v))
        return integer ? c.rounded() : c
    }
}

extension Knob {
    static let context = "Context budget", retrieval = "Retrieval", repairs = "Repairs, look and explore", notes = "Notes"
    static let learning = "Learning", timeouts = "Model and timeouts"

    public static let chatBudget = Knob("chat.budget", context, "Prompt budget", 6000, 1500, 9000, unit: "chars",
        "Most characters of context (tools, examples, results…) sent with one chat turn. The on-device model has about 4k tokens for instructions, prompt, schema and answer; bibi also shrinks the prompt when the model says it overflowed.")
    public static let contextChars = Knob("chat.contextChars", context, "Whole call size", 10_000, 4000, 14_000, unit: "chars",
        "Characters one call may take with its instructions and schema (~2.5k tokens), leaving room for the answer. The prompt gets what the instructions and schema leave, up to the prompt budget.")
    public static let keepMessages = Knob("chat.keepMessages", context, "Messages kept verbatim", 4, 1, 12,
        "Recent messages the model sees word for word; older ones are compacted into the running summary.")
    public static let inputMax = Knob("chat.inputMax", context, "Longest user message", 2000, 200, 8000, unit: "chars",
        "A longer message is clipped before it reaches the model.")
    public static let capTools = Knob("chat.cap.tools", context, "Tools section", 2500, 300, 6000, unit: "chars",
        "The list of commands, actions, skills and app tools the model may pick from.")
    public static let capSummary = Knob("chat.cap.summary", context, "Conversation summary section", 1200, 0, 4000, unit: "chars",
        "The compacted summary of older messages. Dropped first when the prompt is too big.")
    public static let capFacts = Knob("chat.cap.facts", context, "Known facts section", 600, 0, 3000, unit: "chars",
        "Remembered facts that relate to the request.")
    public static let capExamples = Knob("chat.cap.examples", context, "Examples section", 700, 0, 3000, unit: "chars",
        "Earlier requests and the steps that answered them. The small model copies their shape closely.")
    public static let capRecent = Knob("chat.cap.recent", context, "Recent messages section", 2000, 200, 6000, unit: "chars",
        "The last messages of the conversation.")
    public static let capResults = Knob("chat.cap.results", context, "Results section", 2500, 300, 6000, unit: "chars",
        "What the approved steps found (as notes).")
    public static let capHints = Knob("chat.cap.hints", context, "Check commands section", 900, 0, 3000, unit: "chars",
        "Commands that check the latest findings of a skill run.")

    public static let rankSkills = Knob("retrieval.skills", retrieval, "Skills offered", 3, 0, 8,
        "Most skills listed for one request. A small model picks whatever is listed, so fewer is often better.")
    public static let rankCapabilities = Knob("retrieval.capabilities", retrieval, "App tools offered", 3, 0, 8,
        "Most scriptable-app commands listed for one request.")
    public static let examples = Knob("retrieval.examples", retrieval, "Examples shown", 3, 0, 6,
        "Most example requests shown with one request.")
    public static let exampleWords = Knob("retrieval.exampleWords", retrieval, "Shared words for an example", 2, 1, 5,
        "Content words an example must share with the request (one is enough when it used a tool the request's words select).")
    public static let facts = Knob("retrieval.facts", retrieval, "Facts shown", 3, 0, 8, "Most remembered facts shown with one request.")
    public static let factSimilarity = Knob("retrieval.factSimilarity", retrieval, "Fact similarity", 0.35, 0, 1, integer: false,
        "How similar a fact must be to the request to be shown (0–1).")
    public static let translateConfidence = Knob("retrieval.translateConfidence", retrieval, "Translate when sure", 0.5, 0, 1,
        integer: false, "A message is translated to English for retrieval when its language is detected with at least this confidence.")

    public static let repairCount = Knob("chat.repairs", repairs, "Repairs", 2, 0, 4,
        "Times the model may fix refused steps before bibi asks the user. Each repair is one more model call.")
    public static let lookRounds = Knob("look.rounds", repairs, "Look rounds", 3, 1, 6,
        "With \"Let bibi look\": rounds of read-only steps per message, each of at most two steps.")
    public static let lookRepeats = Knob("look.runsPerProgram", repairs, "Runs per program", 2, 1, 5,
        "Times one program may run in a task; a small model re-runs ps with new flags instead of moving on.")
    public static let lookTools = Knob("look.cap.tools", repairs, "Look: tools section", 1500, 300, 4000, unit: "chars",
        "The tool list in each look round.")
    public static let lookNotes = Knob("look.cap.notes", repairs, "Look: notes section", 2500, 300, 6000, unit: "chars",
        "What the steps found, in each look round.")
    public static let exploreTries = Knob("explore.tries", repairs, "Work it out: tries per step", 2, 1, 4,
        "With \"Work it out\": attempts to turn one planned step into an allowed command.")

    public static let verbatimChars = Knob("notes.verbatim", notes, "Kept as is up to", 300, 50, 2000, unit: "chars",
        "Command output up to this long becomes one note as it is; longer output is reduced by the model.")
    public static let noteChars = Knob("notes.line", notes, "Note line", 160, 40, 500, unit: "chars", "Each extracted line is clipped to this.")
    public static let chunkChars = Knob("notes.chunk", notes, "Extraction chunk", 1500, 300, 4000, unit: "chars",
        "Long output is read from its first chunk of this size, and from the last only if the first gave nothing.")
    public static let earlierNotes = Knob("notes.earlier", notes, "Earlier notes shown", 8, 0, 20,
        "Notes from earlier messages shown when they relate to the topic.")

    public static let minOccurrences = Knob("learn.minOccurrences", learning, "Requests before a skill is proposed", 3, 2, 10,
        "How many similar approved requests make bibi propose saving them as a skill.")
    public static let mineSimilarity = Knob("learn.similarity", learning, "Similar requests", 0.65, 0.3, 1, integer: false,
        "How similar requests must be to count as the same (0–1).")
    public static let rollbackDecisions = Knob("prompts.rollbackDecisions", learning, "Decisions before rollback", 10, 2, 100,
        "Approvals and skips a prompt version needs before bibi compares it with the previous one.")
    public static let rollbackMargin = Knob("prompts.rollbackMargin", learning, "Rollback margin", 0.1, 0, 0.5, integer: false,
        "How much lower the approval rate must be to roll back to the previous version (0–1).")
    public static let avoidKeep = Knob("prompts.avoidKeep", learning, "\"Avoid\" notes kept", 5, 0, 20,
        "Reasons the user gave for skipping a proposal, appended to the skill's guidance; the newest are kept.")

    public static let modelTimeout = Knob("model.timeout", timeouts, "Model call timeout", 90, 10, 600, unit: "s",
        "Longest a single on-device model call may take.")
    public static let modelRetries = Knob("model.retries", timeouts, "Model retries", 1, 0, 3, "Retries after a failed model call.")
    public static let commandTimeout = Knob("command.timeout", timeouts, "Command timeout", 120, 5, 1800, unit: "s",
        "Longest an approved command may run.")
    public static let appCallTimeout = Knob("appcall.timeout", timeouts, "App call timeout", 90, 5, 600, unit: "s",
        "Longest an approved app tool (AppleScript) call may run.")

    public static let all: [Knob] = [
        chatBudget, contextChars, keepMessages, inputMax, capTools, capSummary, capFacts, capExamples, capRecent, capResults, capHints,
        rankSkills, rankCapabilities, examples, exampleWords, facts, factSimilarity, translateConfidence,
        repairCount, lookRounds, lookRepeats, lookTools, lookNotes, exploreTries,
        verbatimChars, noteChars, chunkChars, earlierNotes,
        minOccurrences, mineSimilarity, rollbackDecisions, rollbackMargin, avoidKeep,
        modelTimeout, modelRetries, commandTimeout, appCallTimeout,
    ]

    public static func named(_ id: String) -> Knob? { all.first { $0.id == id } }
}

/// Reads and writes knob overrides and the user's lists (command policy, disabled apps). Without a graph every
/// value is the built-in one.
public struct Knobs: Sendable {
    public let graph: GraphStore?
    public init(_ graph: GraphStore?) { self.graph = graph }

    static func key(_ k: Knob) -> String { "knob." + k.id }

    public func override(_ k: Knob) -> Double? { graph?.setting(Self.key(k))?.number.map(k.clamp) }
    public subscript(_ k: Knob) -> Double { override(k) ?? k.builtIn }
    public func int(_ k: Knob) -> Int { Int(self[k]) }

    public func set(_ k: Knob, _ value: Double?) { graph?.setSetting(Self.key(k), value.map { .number(k.clamp($0)) }) }

    /// Removes every knob override. Returns how many there were.
    @discardableResult
    public func resetAll(dryRun: Bool = false) -> Int {
        let set = Knob.all.filter { override($0) != nil }
        if !dryRun { for k in set { self.set(k, nil) } }
        return set.count
    }

    // MARK: lists

    public static let policyAllow = "policy.allow", policyBlock = "policy.block", appsDisabled = "apps.disabled"
    public static let lists = [policyAllow, policyBlock, appsDisabled]

    public func list(_ key: String) -> [String] { graph?.setting(key)?.strings ?? [] }

    public func setList(_ key: String, _ items: [String]) {
        var seen = Set<String>()
        let clean = items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        graph?.setSetting(key, clean.isEmpty ? nil : .array(clean.map { .string($0) }))
    }
}
