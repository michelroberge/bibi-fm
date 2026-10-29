import Foundation

public struct ModelLogEntry: Codable, Sendable {
    public var time: Date
    public var schema: String
    public var prompt: String
    public var response: JSONValue?
    public var error: String?
    public var seconds: Double
    /// Sizes, to watch the ~4k-token context: characters of the instructions and the prompt, and the tokens the
    /// call roughly took with its schema (`Text.estimatedTokens`). Missing in logs written before these were kept.
    public var instructionChars: Int?
    public var promptChars: Int?
    public var tokens: Int?
    /// The call failed because the prompt didn't fit the context window.
    public var overflow: Bool?
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
            record(Self.entry(start, prompt, instructions, schema, r, nil))
            return r
        } catch {
            record(Self.entry(start, prompt, instructions, schema, nil, error))
            throw error
        }
    }

    public func stream(_ prompt: String, instructions: String, schema: Schema,
                       partial: @escaping @Sendable (JSONValue) -> Void) async throws -> JSONValue {
        let start = Date()
        do {
            let r = try await base.stream(prompt, instructions: instructions, schema: schema, partial: partial)
            record(Self.entry(start, prompt, instructions, schema, r, nil))
            return r
        } catch {
            record(Self.entry(start, prompt, instructions, schema, nil, error))
            throw error
        }
    }

    static func entry(_ start: Date, _ prompt: String, _ instructions: String, _ schema: Schema, _ r: JSONValue?,
                      _ e: (any Error)?) -> ModelLogEntry {
        ModelLogEntry(time: start, schema: schema.name, prompt: prompt, response: r, error: e.map { "\($0)" },
                      seconds: Date().timeIntervalSince(start), instructionChars: instructions.count, promptChars: prompt.count,
                      tokens: Text.estimatedTokens(instructions) + Text.estimatedTokens(prompt) + Text.estimatedTokens(chars: schema.estimatedChars),
                      overflow: (e as? LLMError)?.contextOverflow == true ? true : nil)
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
