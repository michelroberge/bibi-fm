import Foundation

public struct ModelLogEntry: Codable, Sendable {
    public var time: Date
    public var schema: String
    public var prompt: String
    public var response: JSONValue?
    public var error: String?
    public var seconds: Double
}

/// Wraps a model and records every prompt and response for the audit history.
public struct RecordingModel: LanguageModel {
    let base: any LanguageModel
    let record: @Sendable (ModelLogEntry) -> Void

    public init(_ base: any LanguageModel, record: @escaping @Sendable (ModelLogEntry) -> Void) {
        self.base = base; self.record = record
    }

    public func respond(_ prompt: String, instructions: String, schema: Schema) async throws -> JSONValue {
        let start = Date()
        do {
            let r = try await base.respond(prompt, instructions: instructions, schema: schema)
            record(ModelLogEntry(time: start, schema: schema.name, prompt: prompt, response: r, error: nil,
                                 seconds: Date().timeIntervalSince(start)))
            return r
        } catch {
            record(ModelLogEntry(time: start, schema: schema.name, prompt: prompt, response: nil, error: "\(error)",
                                 seconds: Date().timeIntervalSince(start)))
            throw error
        }
    }
}

/// Used when the model is unavailable: every call fails, so skills fall back to their deterministic output.
public struct UnavailableModel: LanguageModel {
    let reason: String
    public init(_ reason: String) { self.reason = reason }
    public func respond(_: String, instructions _: String, schema _: Schema) async throws -> JSONValue {
        throw LLMError(reason)
    }
}
