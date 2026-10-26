import Foundation

/// One piece of evidence, with where it came from. Findings and model output cite observations by id.
public struct Observation: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var source: String  // the exact command, API, or file it came from
    public var text: String
    public var value: JSONValue?

    public init(id: String, source: String, text: String, value: JSONValue? = nil) {
        self.id = id; self.source = source; self.text = text; self.value = value
    }
}

public enum Severity: String, Codable, Sendable, Comparable, CaseIterable {
    case info, low, medium, high
    public static func < (a: Severity, b: Severity) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

public enum Uncertainty: String, Codable, Sendable { case low, medium, high }

public struct Finding: Codable, Sendable, Identifiable {
    public var id: String
    public var category: String
    public var title: String
    public var severity: Severity
    public var observationIDs: [String]
    public var confidence: Int  // 0-100
    public var explanation: String
    public var diagnostics: [String]  // Diagnostics catalog ids
    public var recommendations: [BoundAction]
    /// Who produced the explanation: "rule" or "model".
    public var explainedBy: String
    /// What the finding is about (pid, process, path, label...), used to fill in diagnostic commands.
    public var subject: [String: String]

    public init(id: String, category: String, title: String, severity: Severity, observationIDs: [String],
                confidence: Int, explanation: String, diagnostics: [String] = [], recommendations: [BoundAction] = []) {
        self.id = id; self.category = category; self.title = title; self.severity = severity
        self.observationIDs = observationIDs; self.confidence = confidence; self.explanation = explanation
        self.diagnostics = diagnostics; self.recommendations = recommendations; self.explainedBy = "rule"
        self.subject = [:]
    }

    /// Low only with strong confidence and corroborating evidence.
    public var uncertainty: Uncertainty {
        if confidence >= 70 && observationIDs.count >= 2 { return .low }
        if confidence < 40 || observationIDs.isEmpty { return .high }
        return .medium
    }

    enum CodingKeys: String, CodingKey {
        case id, category, title, severity, observationIDs, confidence, explanation, diagnostics, recommendations,
             explainedBy, uncertainty, subject
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decode(String.self, forKey: .category)
        title = try c.decode(String.self, forKey: .title)
        severity = try c.decode(Severity.self, forKey: .severity)
        observationIDs = try c.decode([String].self, forKey: .observationIDs)
        confidence = try c.decode(Int.self, forKey: .confidence)
        explanation = try c.decode(String.self, forKey: .explanation)
        diagnostics = try c.decodeIfPresent([String].self, forKey: .diagnostics) ?? []
        recommendations = try c.decodeIfPresent([BoundAction].self, forKey: .recommendations) ?? []
        explainedBy = try c.decodeIfPresent(String.self, forKey: .explainedBy) ?? "rule"
        subject = try c.decodeIfPresent([String: String].self, forKey: .subject) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(category, forKey: .category)
        try c.encode(title, forKey: .title)
        try c.encode(severity, forKey: .severity)
        try c.encode(observationIDs, forKey: .observationIDs)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(explanation, forKey: .explanation)
        try c.encode(diagnostics, forKey: .diagnostics)
        try c.encode(recommendations, forKey: .recommendations)
        try c.encode(explainedBy, forKey: .explainedBy)
        try c.encode(uncertainty, forKey: .uncertainty)
        try c.encode(subject, forKey: .subject)
    }
}

/// A model hypothesis linking several findings, kept only when it cites real observations.
public struct Hypothesis: Codable, Sendable {
    public var title: String
    public var explanation: String
    public var observationIDs: [String]
    public var findingIDs: [String]
    public var confidence: Int
    public var diagnostics: [String]
}

public struct SkillResult: Codable, Sendable {
    public var summary: String
    public var observations: [Observation]
    public var findings: [Finding]
    public var hypotheses: [Hypothesis]
    /// Comparable snapshot for baselines: sets as string arrays, metrics as numbers or {key: number} maps.
    public var facts: [String: JSONValue]
    public var diff: FactDiff?
    public var notes: [String]

    public init(summary: String, observations: [Observation] = [], findings: [Finding] = [], hypotheses: [Hypothesis] = [],
                facts: [String: JSONValue] = [:], diff: FactDiff? = nil, notes: [String] = []) {
        self.summary = summary; self.observations = observations; self.findings = findings
        self.hypotheses = hypotheses; self.facts = facts; self.diff = diff; self.notes = notes
    }

    public func observation(_ id: String) -> Observation? { observations.first { $0.id == id } }

    /// Every recommendation, in finding order (findings are expected sorted by importance).
    public var actions: [BoundAction] { findings.flatMap(\.recommendations) }

    public func action(_ id: String) -> BoundAction? { actions.first { $0.id == id } }
}

/// Builds observations and findings with sequential ids. Thread-safe so concurrent collectors can share one.
public final class Evidence: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [Observation] = []
    private var findings: [Finding] = []
    private var actionCount = 0

    public init() {}

    @discardableResult
    public func observe(_ source: String, _ text: String, value: JSONValue? = nil) -> String {
        lock.withLock {
            let id = "o\(observations.count + 1)"
            observations.append(Observation(id: id, source: source, text: text, value: value))
            return id
        }
    }

    @discardableResult
    public func observe(_ output: CommandOutput, _ text: String, value: JSONValue? = nil) -> String {
        observe(output.source, text, value: value)
    }

    @discardableResult
    public func find(_ category: String, _ title: String, severity: Severity, cites: [String], confidence: Int,
                     explanation: String, diagnostics: [String] = [], subject: [String: String] = [:],
                     actions: [BoundAction] = []) -> String {
        lock.withLock {
            let id = "F\(findings.count + 1)"
            let numbered = actions.map { a -> BoundAction in
                actionCount += 1
                var a = a
                a.id = "a\(actionCount)"
                a.findingID = id
                return a
            }
            var f = Finding(id: id, category: category, title: title, severity: severity, observationIDs: cites,
                            confidence: confidence, explanation: explanation, diagnostics: diagnostics,
                            recommendations: numbered)
            f.subject = subject
            findings.append(f)
            return id
        }
    }

    public var allObservations: [Observation] { lock.withLock { observations } }
    public var allFindings: [Finding] { lock.withLock { findings } }

    public func update(_ id: String, _ change: (inout Finding) -> Void) {
        lock.withLock {
            if let i = findings.firstIndex(where: { $0.id == id }) { change(&findings[i]) }
        }
    }

    /// Findings sorted most severe first, then by confidence.
    public func sortedFindings() -> [Finding] {
        allFindings.sorted { ($0.severity, $0.confidence) > ($1.severity, $1.confidence) }
    }
}
