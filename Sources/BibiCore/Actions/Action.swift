import Foundation

public enum Privilege: String, Codable, Sendable { case user, admin }

public typealias Params = [String: String]

/// A request to run one registry action. This is all that is stored, sent from the web UI, or chosen by the model:
/// an id and string parameters. The registry validates both before anything runs.
public struct ActionCall: Codable, Sendable, Equatable {
    public var spec: String
    public var params: Params
    public init(_ spec: String, _ params: Params = [:]) { self.spec = spec; self.params = params }
}

/// What executing an action did.
public struct Outcome: Codable, Sendable {
    public var message: String
    /// The call that reverses this one, if any.
    public var undo: ActionCall?
    /// Output worth keeping as evidence (diagnostics).
    public var output: String?
    public init(_ message: String, undo: ActionCall? = nil, output: String? = nil) {
        self.message = message; self.undo = undo; self.output = output
    }
}

/// Dry-run description of a call.
public struct Preview: Codable, Sendable {
    public var steps: [String]
    public var privilege: Privilege
    public var reversible: Bool
    public var error: String?
}

/// One parameter of an action as a form field. Chat shows the fields on the proposal card, so the user can fill in
/// or change any of them before approving (by hand, by asking in chat, or by picking from live choices).
public struct ActionField: Codable, Sendable, Equatable {
    public var key: String
    public var label: String
    /// text, longtext, addresses, datetime, choice or bool.
    public var kind: String
    public var required: Bool
    /// Where a choice field's options come from (`AppServices.choices`): mail_accounts, calendars, reminder_lists.
    public var source: String?
    /// Fixed options for a choice field.
    public var options: [String]?
    public var placeholder: String?

    public init(_ key: String, _ label: String, kind: String = "text", required: Bool = false, source: String? = nil,
                options: [String]? = nil, placeholder: String? = nil) {
        self.key = key; self.label = label; self.kind = kind; self.required = required; self.source = source
        self.options = options; self.placeholder = placeholder
    }
}

/// A recommendation the user can approve: a registry call plus everything needed to judge it.
public struct BoundAction: Codable, Sendable, Identifiable {
    public var id: String  // "a3", assigned when attached to a finding
    public var call: ActionCall
    public var title: String
    public var kind: String  // display category: trash, clear, tool, review, open, quit, disable, upgrade...
    public var target: String
    public var bytes: Int
    public var safety: Int  // 0-10, 10 = no risk
    public var confidence: Int  // 0-10
    public var reason: String
    public var command: String  // human-readable description of what runs
    public var findingID: String
    public var weight: Double  // < 1 for actions that don't directly reclaim anything (e.g. review)
    public var privilege: Privilege
    public var reversible: Bool
    /// What still needs filling in or fixing, by field key ("" = not about one field). nil: ready to approve.
    public var problems: [String: String]?
    /// Fields the user typed on the card: a later chat turn doesn't overwrite them unless the user asks.
    public var edited: [String]?

    public init(_ call: ActionCall, title: String, kind: String, target: String, bytes: Int = 0, safety: Int,
                confidence: Int, reason: String, command: String, weight: Double = 1, privilege: Privilege = .user,
                reversible: Bool = false) {
        self.id = ""; self.findingID = ""
        self.call = call; self.title = title; self.kind = kind; self.target = target; self.bytes = bytes
        self.safety = safety; self.confidence = confidence; self.reason = reason; self.command = command
        self.weight = weight; self.privilege = privilege; self.reversible = reversible
    }

    public var score: Double {
        Double(bytes) / 1e9 * Double(safety) / 10 * Double(confidence) / 10 * weight
    }
}

public struct ActionError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Runs a command with administrator rights. Every implementation must make the user type their password each time.
public protocol AdminRunner: Sendable {
    func run(_ argv: [String]) async throws -> String
}

/// Everything an action may use while validating or executing.
public struct ActionEnv: Sendable {
    public var policy: SafetyPolicy
    public var admin: any AdminRunner
    public var reporter: any Reporter
    public var apps: AppServices

    public init(policy: SafetyPolicy = SafetyPolicy(), admin: any AdminRunner, reporter: any Reporter = SilentReporter(),
                apps: AppServices = .system) {
        self.policy = policy; self.admin = admin; self.reporter = reporter; self.apps = apps
    }
}

/// One kind of action bibi can take. Only specs registered here can ever run.
public protocol ActionSpec: Sendable {
    var id: String { get }
    var summary: String { get }
    var privilege: Privilege { get }
    var reversible: Bool { get }
    /// False for internal specs that only exist to undo others.
    var selectable: Bool { get }
    /// The category chat shows ("read-only", "outbound"...); nil = the spec id.
    var kind: String? { get }
    /// Brings parameters the model wrote into the form validate accepts (dates in words → exact dates). Runs once,
    /// when the step is proposed, so the card shows exactly what will run.
    func normalize(_ p: Params, _ env: ActionEnv) -> Params
    /// The parameters as form fields; empty for actions that are approved as they are.
    var fields: [ActionField] { get }
    func validate(_ p: Params, _ env: ActionEnv) throws
    /// Human-readable steps. Must not change anything.
    func plan(_ p: Params, _ env: ActionEnv) throws -> [String]
    func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome
}

extension ActionSpec {
    public var selectable: Bool { true }
    public var reversible: Bool { false }
    public var privilege: Privilege { .user }
    public var kind: String? { nil }
    public func normalize(_ p: Params, _ env: ActionEnv) -> Params { p }
    public var fields: [ActionField] { [] }

    /// What is missing or wrong, by field: required fields left empty, then validation's complaint, filed under
    /// the field it names ("to: x is not an email address") or under "".
    public func problems(_ p: Params, _ env: ActionEnv) -> [String: String] {
        var out: [String: String] = [:]
        for f in fields where f.required && (p[f.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty { out[f.key] = "needed" }
        guard out.isEmpty else { return out }
        do { try validate(p, env) } catch {
            var m = "\(error)"
            if m.hasPrefix(id + ": ") { m = String(m.dropFirst(id.count + 2)) }
            let field = fields.first { m.hasPrefix($0.key + ":") || m.hasSuffix("parameter " + $0.key) }
            if let f = field, m.hasPrefix(f.key + ":") { m = String(m.dropFirst(f.key.count + 1)).trimmingCharacters(in: .whitespaces) }
            out[field?.key ?? ""] = m
        }
        return out
    }

    /// The parameters as the card shows them while some are missing (a preview needs them all).
    public func describe(_ p: Params) -> String {
        let shown = fields.compactMap { f in p[f.key].flatMap { $0.isEmpty ? nil : "\(f.label.lowercased()): \($0)" } }
        return ([summary] + shown).joined(separator: "; ")
    }

    public func require(_ p: Params, _ key: String) throws -> String {
        guard let v = p[key], !v.isEmpty else { throw ActionError("\(id): missing parameter \(key)") }
        return v
    }
}

/// The fixed set of actions bibi can run. Immutable once built.
public final class ActionRegistry: Sendable {
    private let specs: [String: any ActionSpec]

    public init(_ specs: [any ActionSpec]) {
        var d: [String: any ActionSpec] = [:]
        for s in specs { d[s.id] = s }
        self.specs = d
    }

    public func spec(_ id: String) -> (any ActionSpec)? { specs[id] }
    public var all: [any ActionSpec] { specs.values.sorted { $0.id < $1.id } }

    func lookup(_ call: ActionCall) throws -> any ActionSpec {
        guard let s = specs[call.spec] else { throw ActionError("unknown action '\(call.spec)'") }
        return s
    }

    public func preview(_ call: ActionCall, _ env: ActionEnv) -> Preview {
        guard let s = specs[call.spec] else {
            return Preview(steps: [], privilege: .user, reversible: false, error: "unknown action '\(call.spec)'")
        }
        do {
            try s.validate(call.params, env)
            return Preview(steps: try s.plan(call.params, env), privilege: s.privilege, reversible: s.reversible, error: nil)
        } catch {
            return Preview(steps: [], privilege: s.privilege, reversible: s.reversible, error: "\(error)")
        }
    }

    /// Validates again (state may have changed since the scan) and runs. Admin actions need explicit confirmation.
    public func execute(_ call: ActionCall, _ env: ActionEnv, adminConfirmed: Bool = false,
                        allowInternal: Bool = false) async throws -> Outcome {
        let s = try lookup(call)
        if !s.selectable && !allowInternal { throw ActionError("'\(call.spec)' can only be used to undo") }
        if s.privilege == .admin && !adminConfirmed {
            throw ActionError("'\(call.spec)' needs administrator rights and was not confirmed")
        }
        try s.validate(call.params, env)
        return try await s.execute(call.params, env)
    }
}
