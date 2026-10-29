import Foundation

/// What a step found, as a few short lines copied from its output: the task's working memory. The full output
/// stays in the transcript and the journal; the model sees the notes, so a long `log show` or `du` costs a few
/// lines of the ~4k-token context, not all of it.
public struct ChatNote: Codable, Sendable, Equatable {
    public var purpose: String
    public var text: String
    /// The user message (`ChatState.turns`) the step belongs to.
    public var turn: Int
    public var actionID: String

    public init(purpose: String, text: String, turn: Int, actionID: String) {
        self.purpose = purpose; self.text = text; self.turn = turn; self.actionID = actionID
    }
}

extension ChatEngine {
    static let extractInstructions = """
    You pick out what matters in a command's output for bibi, an assistant on the user's Mac.
    lines: at most 5 lines copied exactly from the output that answer the purpose: the numbers, names and states that matter, shortest first. Only lines that are in the output, word for word; never a summary. None when nothing in the output answers it.
    """

    static let extractSchema = Schema("Extract", [.init("lines", .array(.string, max: 5), "lines copied exactly from the output")])

    /// Outputs up to this long are one note as they are; longer ones are extracted from.
    static let verbatimChars = 300
    /// Each extracted line is clipped to this.
    static let noteChars = 160
    /// Long outputs are extracted chunk by chunk: at most this many chunks of this many characters (the first,
    /// the middle and the last), so a huge output costs three small calls.
    static let chunkChars = 1500, chunksMax = 3

    /// The notes for one result. A failure is one note saying so; a short output is kept as is; a long one goes to
    /// the model, and only lines that really are in the output are kept (a small model summarizes and invents).
    func notes(for r: ExecResult, purpose: String, request: String, turn: Int, run: RunRecord) async -> [ChatNote] {
        let note = { (t: String) in ChatNote(purpose: Text.oneLine(purpose, max: 80), text: t, turn: turn, actionID: r.actionID) }
        guard r.ok else { return [note("FAILED: " + Text.oneLine(r.message, max: Self.verbatimChars))] }
        let output = Text.collapseRepeats(r.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return [note(Text.oneLine(r.message, max: Self.verbatimChars))] }
        guard output.count > Self.verbatimChars else { return [note(output)] }
        var lines: [String] = []
        let instructions = prompts.text("chat.extract", default: Self.extractInstructions)
        for chunk in Self.chunks(output) {
            let prompt = "Purpose: \(Text.oneLine(purpose, max: 120))\nRequest: \(Text.oneLine(request, max: 200))\nOutput:\n\(chunk)"
            guard let a = try? await model(run).respond(prompt, instructions: instructions, schema: Self.extractSchema) else { continue }
            for l in a["lines"]?.strings ?? [] {
                let t = Text.oneLine(l, max: Self.noteChars)
                if !t.isEmpty, Self.inOutput(t, chunk), !lines.contains(t) { lines.append(t) }
            }
        }
        if lines.isEmpty { lines = [Text.clip(output, max: Self.verbatimChars)] }
        return lines.map(note)
    }

    /// True if `line` is in `output` as written (whitespace aside), or nearly all its words and all its numbers are.
    static func inOutput(_ line: String, _ output: String) -> Bool {
        let squeeze = { (s: String) in s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return squeeze(output).contains(squeeze(line)) || grounded(line, in: output)
    }

    static func chunks(_ s: String) -> [String] {
        var all: [String] = [], cur = ""
        for line in s.split(separator: "\n", omittingEmptySubsequences: false).map({ String($0.prefix(chunkChars)) }) {
            if !cur.isEmpty, cur.count + line.count + 1 > chunkChars { all.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : "\n") + line
        }
        if !cur.isEmpty { all.append(cur) }
        guard all.count > chunksMax else { return all }
        return [all[0], all[all.count / 2], all[all.count - 1]]
    }

    /// The notes of one turn, as a prompt section.
    func notesText(_ state: ChatState, turn: Int) -> String {
        (state.notes ?? []).filter { $0.turn == turn }.map { "- \($0.purpose): \($0.text)" }.joined(separator: "\n")
    }

    /// Earlier notes that relate to the topic, best first.
    func notesText(_ state: ChatState, before turn: Int, topic: String, limit: Int = 8) -> String {
        (state.notes ?? []).filter { $0.turn < turn }
            .map { ($0, Similarity.jaccard(topic, $0.purpose + " " + $0.text)) }.filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }.prefix(limit).map { "- \($0.0.purpose): \($0.0.text)" }.joined(separator: "\n")
    }
}
