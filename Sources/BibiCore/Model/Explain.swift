import Foundation

/// Evidence-grounded model use: deterministic rules create findings, the model explains and correlates them,
/// and everything it says must cite observations that actually exist.
public struct Explainer: Sendable {
    let model: any LanguageModel
    let reporter: any Reporter
    /// How far the model may raise a rule's confidence.
    public static let maxRaise = 15
    public static let maxLower = 40

    public init(model: any LanguageModel, reporter: any Reporter) {
        self.model = model; self.reporter = reporter
    }

    static let explainInstructions = """
    You explain one finding from a macOS health, cleanup or security check to a technical user.
    You get the finding and numbered observations (o1, o2, ...). Only use facts from the observations.
    explanation: two or three plain sentences: what it means, why it matters, what to do. Don't write observation ids in it.
    cites: the observation ids your explanation relies on.
    confidence: 0-100, how sure you are the finding is real and the advice is right. Lower it when evidence is thin.
    action: the best of the offered actions, or "none" if the user should only look into it.
    diagnostics: commands that would help confirm the finding, from the offered list, or none.
    """

    struct Explanation: Decodable {
        var explanation: String
        var cites: [String]
        var confidence: Int
        var action: String?
        var diagnostics: [String]?
    }

    /// Asks the model to explain the finding; keeps only valid citations and bounded confidence changes.
    /// On failure the rule's own explanation stays.
    public func explain(_ finding: Finding, observations: [Observation], context: String = "") async -> Finding {
        var f = finding
        let obs = observations.filter { f.observationIDs.contains($0.id) }
        let actionIDs = f.recommendations.map(\.id)
        let diagnosticIDs = Diagnostics.all.map(\.id)
        var fields: [Schema.Field] = [
            .init("explanation", .string, "two or three sentences"),
            .init("cites", .array(.string, max: 6), "observation ids, e.g. o3"),
            .init("confidence", .int(0...100)),
        ]
        if !actionIDs.isEmpty { fields.append(.init("action", .choice(actionIDs + ["none"]))) }
        fields.append(.init("diagnostics", .array(.choice(diagnosticIDs), max: 2)))

        var prompt = [context.isEmpty ? nil : context,
                      "Finding: \(f.title) (severity \(f.severity.rawValue))",
                      "Rule says: \(f.explanation)",
                      "Observations:"].compactMap { $0 }
        prompt += obs.map { "\($0.id): \($0.text.prefix(300))" }
        if !actionIDs.isEmpty {
            prompt.append("Actions:")
            prompt += f.recommendations.map { "\($0.id): \($0.title) (safety \($0.safety)/10)" }
        }
        let relevant = Diagnostics.all.filter { f.diagnostics.contains($0.id) || $0.categories.contains(f.category) }
        if !relevant.isEmpty {
            prompt.append("Diagnostics:")
            prompt += relevant.prefix(6).map { "\($0.id): \($0.title)" }
        }

        do {
            let r = try await model.respond(prompt.joined(separator: "\n"), instructions: Self.explainInstructions,
                                            schema: Schema("Explanation", fields), as: Explanation.self)
            let valid = r.cites.filter { id in obs.contains { $0.id == id } }
            f.explanation = Self.stripIDs(r.explanation).ifEmpty(f.explanation)
            f.explainedBy = "model"
            f.confidence = Self.bound(model: r.confidence, rule: finding.confidence, grounded: !valid.isEmpty)
            if let pick = r.action, let i = f.recommendations.firstIndex(where: { $0.id == pick }), i > 0 {
                f.recommendations.insert(f.recommendations.remove(at: i), at: 0)
            }
            let diag = (r.diagnostics ?? []).filter { id in Diagnostics.all.contains { $0.id == id } }
            f.diagnostics = Array(Set(f.diagnostics + diag)).sorted()
        } catch {
            reporter.debug("  ! explain \(f.id): \(error)")
        }
        return f
    }

    /// The model sometimes writes "(o3)" or "(F1, F2)" into prose despite instructions; evidence links are shown separately.
    public static func stripIDs(_ text: String) -> String {
        let cleaned = Re.replace("\\s*\\((?:[oF][0-9]+(?:,\\s*)?)+\\)", text, with: "")
        return Re.replace("\\s{2,}", cleaned, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The model may lower confidence (bounded) and raise it only a little, and only if it cited real evidence.
    public static func bound(model: Int, rule: Int, grounded: Bool) -> Int {
        let upper = grounded ? min(100, rule + maxRaise) : rule
        return max(max(0, rule - maxLower), min(model, upper))
    }

    static let correlateInstructions = """
    You look for connections between findings from one macOS check, e.g. high CPU, heat and a failing battery,
    or a new listening port and a new login item from the same app.
    Only propose a hypothesis that links at least two findings and cite the finding ids (F1, F2...) and observation ids it relies on.
    Don't write ids in the title or explanation; put them in cites.
    If nothing is connected, return an empty list. Never invent facts.
    """

    struct Correlation: Decodable {
        struct H: Decodable {
            var title: String
            var explanation: String
            var cites: [String]
            var confidence: Int
            var diagnostics: [String]?
        }
        var hypotheses: [H]
    }

    /// One call over compact finding summaries. Returns only hypotheses whose citations check out.
    public func correlate(_ findings: [Finding], observations: [Observation], context: String = "") async -> [Hypothesis] {
        let top = Array(findings.filter { $0.severity > .info }.prefix(20))
        guard top.count >= 2 else { return [] }
        var lines = context.isEmpty ? [] : [context]
        lines.append("Findings:")
        for f in top {
            let ev = f.observationIDs.prefix(3).compactMap { id in observations.first { $0.id == id } }
                .map { "\($0.id) \($0.text.prefix(90))" }.joined(separator: "; ")
            lines.append("\(f.id) [\(f.severity.rawValue)] \(f.title) — \(ev)")
        }
        let schema = Schema("Correlation", [
            .init("hypotheses", .array(.object(Schema("Hypothesis", [
                .init("title", .string, "short"),
                .init("explanation", .string, "two sentences"),
                .init("cites", .array(.string, max: 8), "finding ids and observation ids"),
                .init("confidence", .int(0...100)),
                .init("diagnostics", .array(.choice(Diagnostics.all.map(\.id)), max: 2)),
            ])), max: 3)),
        ])
        do {
            let r = try await model.respond(lines.joined(separator: "\n"), instructions: Self.correlateInstructions,
                                            schema: schema, as: Correlation.self)
            return r.hypotheses.compactMap { h in
                let fids = h.cites.filter { id in top.contains { $0.id == id } }
                var oids = h.cites.filter { id in observations.contains { $0.id == id } }
                for fid in fids { oids += top.first { $0.id == fid }!.observationIDs }
                guard Set(fids).count >= 2 || (Set(fids).count == 1 && !oids.isEmpty && Set(oids).count >= 2) else { return nil }
                let rule = fids.compactMap { id in top.first { $0.id == id }?.confidence }.min() ?? 50
                return Hypothesis(title: Self.stripIDs(h.title), explanation: Self.stripIDs(h.explanation), observationIDs: Array(Set(oids)).sorted(),
                                  findingIDs: Array(Set(fids)).sorted(),
                                  confidence: min(h.confidence, rule),
                                  diagnostics: (h.diagnostics ?? []).filter { id in Diagnostics.all.contains { $0.id == id } })
            }
        } catch {
            reporter.debug("  ! correlate: \(error)")
            return []
        }
    }

    /// Explains findings with limited parallelism, keeping order.
    public func explainAll(_ findings: [Finding], observations: [Observation], context: String = "", limit: Int = 12,
                           jobs: Int = 2) async -> [Finding] {
        let targets = Set(findings.filter { $0.severity > .info }.prefix(limit).map(\.id))
        var out = findings
        await withTaskGroup(of: (Int, Finding).self) { group in
            var running = 0
            for (i, f) in findings.enumerated() where targets.contains(f.id) {
                if running >= jobs, let (j, done) = await group.next() {
                    out[j] = done
                    running -= 1
                }
                reporter.progress("Asking fm to explain: \(f.title)")
                group.addTask { (i, await explain(f, observations: observations, context: context)) }
                running += 1
            }
            for await (j, done) in group { out[j] = done }
        }
        return out
    }
}
