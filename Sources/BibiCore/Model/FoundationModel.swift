import Foundation
import FoundationModels

/// Apple's on-device Foundation Model, called in-process.
public struct FoundationModel: LanguageModel {
    public var timeout: Double
    public var retries: Int

    public init(timeout: Double = 90, retries: Int = 1) {
        self.timeout = timeout; self.retries = retries
    }

    /// nil when the model can be used, else a reason to show the user.
    public static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "this Mac does not support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is turned off (System Settings > Apple Intelligence & Siri)"
        case .unavailable(.modelNotReady): return "the on-device model is still downloading; try again later"
        case .unavailable: return "the on-device model is unavailable"
        }
    }

    public func respond(_ prompt: String, instructions: String, schema: Schema) async throws -> JSONValue {
        let generation = try GenerationSchema(root: Self.dynamic(schema), dependencies: [])
        var last = "no attempt"
        for _ in 0...retries {
            do {
                let content = try await withTimeout(timeout) {
                    let session = LanguageModelSession(instructions: instructions)
                    return try await session.respond(to: prompt, schema: generation,
                                                     options: GenerationOptions(sampling: .greedy)).content
                }
                return try JSON.decode(JSONValue.self, from: content.jsonString)
            } catch let e as LanguageModelSession.GenerationError {
                last = "\(e.localizedDescription)"
                if case .exceededContextWindowSize = e { break }
            } catch {
                last = "\(error)"
            }
        }
        throw LLMError("fm failed: \(last)")
    }

    static func dynamic(_ schema: Schema) -> DynamicGenerationSchema {
        DynamicGenerationSchema(name: schema.name, properties: schema.fields.map {
            .init(name: $0.name, description: $0.description, schema: kind($0.kind, name: schema.name + "_" + $0.name))
        })
    }

    static func kind(_ k: Schema.Kind, name: String) -> DynamicGenerationSchema {
        switch k {
        case .string: return DynamicGenerationSchema(type: String.self)
        case .bool: return DynamicGenerationSchema(type: Bool.self)
        case .int(let r): return DynamicGenerationSchema(type: Int.self, guides: r.map { [.range($0)] } ?? [])
        case .choice(let c): return DynamicGenerationSchema(name: name, anyOf: c.isEmpty ? ["none"] : c)
        case .array(let item, let max):
            return DynamicGenerationSchema(arrayOf: kind(item, name: name + "_item"), maximumElements: max)
        case .object(let s):
            return DynamicGenerationSchema(name: name + "_" + s.name, properties: s.fields.map {
                .init(name: $0.name, description: $0.description, schema: kind($0.kind, name: name + "_" + s.name + "_" + $0.name))
            })
        }
    }
}

struct TimeoutError: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "timed out after \(Int(seconds))s" }
}

func withTimeout<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError(seconds: seconds)
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
