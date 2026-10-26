import Foundation

/// One line of a conversation, as shown to the user.
public struct ChatMessage: Codable, Sendable {
    public var role: String  // user, bibi, result, note
    public var text: String
    public var time: Date
    /// The proposal (finding id) this message carries.
    public var finding: String?
    /// For results: the action and whether it worked.
    public var actionID: String?
    public var ok: Bool?

    public init(_ role: String, _ text: String, finding: String? = nil, actionID: String? = nil, ok: Bool? = nil) {
        self.role = role; self.text = text; self.time = Date(); self.finding = finding; self.actionID = actionID; self.ok = ok
    }
}

/// What the model sees of a conversation: a compacted summary plus the last few messages. The full transcript
/// is kept separately for display and never sent whole (the on-device model has a ~4k token context).
public struct ChatState: Codable, Sendable {
    public var id: String
    public var title: String
    public var summary: String = ""
    public var recent: [ChatMessage] = []
    /// The proposal waiting for decisions.
    public var pending: String?
    /// The current request's intent node, its skill node and the guidance prompt version used (for statistics).
    public var intent: String?
    public var skill: String?
    public var guidance: String?
    /// Results of approved steps the model hasn't answered from yet.
    public var results: [String] = []
    /// Learned-skill candidates announced in this chat.
    public var candidates: [String] = []
    public var turns: Int = 0

    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// Assembles the prompt for one turn within a character budget. Sections have priorities; when the budget is
/// exceeded (or the model reports a context overflow), the least important ones are dropped first.
public struct ContextBuilder: Sendable {
    public struct Section: Sendable {
        public var title: String
        public var body: String
        /// 0 = never dropped; higher = dropped earlier.
        public var priority: Int
        public var maxChars: Int
    }

    public var sections: [Section] = []
    public init() {}

    public mutating func add(_ title: String, _ body: String, priority: Int, maxChars: Int = 4000) {
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { return }
        sections.append(Section(title: title, body: b, priority: priority, maxChars: maxChars))
    }

    /// The prompt, dropping sections from the highest priority down until it fits `budget` characters.
    public func build(budget: Int) -> (text: String, dropped: [String]) {
        var kept = sections.map { s -> Section in
            var s = s
            s.body = Text.clip(s.body, max: s.maxChars)
            return s
        }
        var dropped: [String] = []
        func size() -> Int { kept.reduce(0) { $0 + $1.title.count + $1.body.count + 2 } }
        while size() > budget, let worst = kept.filter({ $0.priority > 0 }).max(by: { $0.priority < $1.priority }) {
            kept.removeAll { $0.title == worst.title }
            dropped.append(worst.title)
        }
        // Still too long: clip what must stay.
        if size() > budget {
            let share = max(200, budget / max(1, kept.count))
            kept = kept.map { var s = $0; s.body = Text.clip(s.body, max: share); return s }
        }
        return (kept.map { $0.title.isEmpty ? $0.body : "\($0.title):\n\($0.body)" }.joined(separator: "\n\n"), dropped)
    }
}
