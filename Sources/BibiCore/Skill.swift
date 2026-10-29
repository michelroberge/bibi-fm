import Foundation

/// The previous run a skill can compare itself with.
public struct BaselineInfo: Sendable {
    public var runID: String
    public var date: Date
    public var facts: [String: JSONValue]
}

/// Everything a skill may use. Front ends (terminal, web) build one through Harness.
public struct SkillContext: Sendable {
    public var model: any LanguageModel
    public var reporter: any Reporter
    public var fetcher: Fetcher
    public var policy: SafetyPolicy
    public var baseline: BaselineInfo?
    public var verbose: Bool
    public var dryRun: Bool
    /// Model instructions, tunable through the graph (defaults when there is none).
    public var prompts: PromptBook

    public init(model: any LanguageModel, reporter: any Reporter, fetcher: Fetcher = Fetcher(online: false),
                policy: SafetyPolicy = SafetyPolicy(), baseline: BaselineInfo? = nil, verbose: Bool = false, dryRun: Bool = false,
                prompts: PromptBook = PromptBook()) {
        self.model = model; self.reporter = reporter; self.fetcher = fetcher; self.policy = policy
        self.baseline = baseline; self.verbose = verbose; self.dryRun = dryRun; self.prompts = prompts
    }

    public var online: Bool { fetcher.online }
    public var explainer: Explainer { Explainer(model: model, reporter: reporter, prompts: prompts) }

    /// Changes since the baseline run, if there is one.
    public func diff(_ facts: [String: JSONValue], spec: FactsSpec) -> FactDiff? {
        guard let b = baseline else { return nil }
        return FactDiff(baselineRun: b.runID, baselineDate: b.date, changes: Baseline.diff(old: b.facts, new: facts, spec: spec))
    }
}

public protocol Skill: Sendable {
    var name: String { get }
    var help: String { get }
    var aliases: [String] { get }
    /// Words that suggest a request is for this skill (chat retrieval; stored in the graph, where they can be tuned).
    var keywords: String { get }
    /// True if the skill can send data to internet services (shown as [web]).
    var usesWeb: Bool { get }
    /// net.identify is useless offline, so it defaults to online; everything else defaults to offline.
    var onlineByDefault: Bool { get }
    var params: [Param] { get }
    var factsSpec: FactsSpec { get }
    /// Actions this skill contributes to the registry.
    var actionSpecs: [any ActionSpec] { get }
    /// The skill's own model prompts, for Settings (each read with `ctx.prompts.text(id, default:)`).
    var prompts: [PromptDefinition] { get }
    func run(_ args: Args, _ ctx: SkillContext) async throws -> SkillResult
    /// Called after actions ran (not on dry runs); returns a line to show, e.g. space reclaimed.
    func afterRun(_ result: SkillResult, _ ctx: SkillContext) async -> String?
    /// Whether two runs' facts describe the same thing (net.identify only compares runs for the same device).
    func comparable(_ old: [String: JSONValue], _ new: [String: JSONValue]) -> Bool
}

extension Skill {
    public var aliases: [String] { [] }
    public var keywords: String { "" }
    public var usesWeb: Bool { false }
    public var onlineByDefault: Bool { false }
    public var factsSpec: FactsSpec { FactsSpec() }
    public var actionSpecs: [any ActionSpec] { [] }
    public var prompts: [PromptDefinition] { [] }
    public func afterRun(_: SkillResult, _: SkillContext) async -> String? { nil }
    public func comparable(_: [String: JSONValue], _: [String: JSONValue]) -> Bool { true }
    public var namespace: String { String(name.split(separator: ".").first ?? "") }
}

public struct SkillError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}
