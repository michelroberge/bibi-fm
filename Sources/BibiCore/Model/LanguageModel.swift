import Foundation

/// A structured-output schema built at runtime, so choices (e.g. the action ids allowed for one finding)
/// can depend on the data. FoundationModel turns it into a DynamicGenerationSchema.
public struct Schema: Sendable {
    public indirect enum Kind: Sendable {
        case string
        case int(ClosedRange<Int>?)
        case bool
        case choice([String])
        case array(Kind, max: Int?)
        case object(Schema)
    }

    public struct Field: Sendable {
        public var name: String
        public var description: String?
        public var kind: Kind
        public init(_ name: String, _ kind: Kind, _ description: String? = nil) {
            self.name = name; self.kind = kind; self.description = description
        }
    }

    public var name: String
    public var fields: [Field]
    public init(_ name: String, _ fields: [Field]) { self.name = name; self.fields = fields }
}

public struct LLMError: Error, CustomStringConvertible {
    public let description: String
    /// The prompt didn't fit the model's context window: retry with less context.
    public var contextOverflow = false
    public init(_ d: String, contextOverflow: Bool = false) { description = d; self.contextOverflow = contextOverflow }
}

/// The only interface skills use to talk to a model. Each call is independent and stateless,
/// and prompts stay small: the on-device model has a ~4k token context.
public protocol LanguageModel: Sendable {
    func respond(_ prompt: String, instructions: String, schema: Schema) async throws -> JSONValue
    /// Like respond, calling `partial` with incomplete output as it is generated (for chat replies).
    func stream(_ prompt: String, instructions: String, schema: Schema,
                partial: @escaping @Sendable (JSONValue) -> Void) async throws -> JSONValue
}

extension LanguageModel {
    public func stream(_ prompt: String, instructions: String, schema: Schema,
                       partial: @escaping @Sendable (JSONValue) -> Void) async throws -> JSONValue {
        let r = try await respond(prompt, instructions: instructions, schema: schema)
        partial(r)
        return r
    }
}

extension LanguageModel {
    /// Responds and decodes into T (field names must match the schema).
    public func respond<T: Decodable>(_ prompt: String, instructions: String, schema: Schema, as type: T.Type) async throws -> T {
        let value = try await respond(prompt, instructions: instructions, schema: schema)
        do {
            return try JSON.decoder.decode(T.self, from: JSON.encoder.encode(value))
        } catch {
            throw LLMError("model output did not match \(schema.name): \(error)")
        }
    }
}
