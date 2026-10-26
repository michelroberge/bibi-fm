import BibiCore
@testable import BibiSkills
import Foundation

let MB = 1 << 20

/// Answers storage verdicts by item name, consolidation with a fixed answer, and anything else with `other`.
final class FakeModel: LanguageModel, @unchecked Sendable {
    let rules: [String: JSONValue]
    let combine: Bool
    let other: JSONValue?
    private let lock = NSLock()
    private(set) var prompts: [String] = []

    init(_ rules: [String: JSONValue] = [:], combine: Bool = false, other: JSONValue? = nil) {
        self.rules = rules; self.combine = combine; self.other = other
    }

    func respond(_ prompt: String, instructions: String, schema: Schema) async throws -> JSONValue {
        lock.withLock { prompts.append(prompt) }
        if schema.name == "Consolidate" {
            return .object(["combine": .bool(combine), "safety": .number(9), "reason": .string("all caches")])
        }
        if schema.name == "Verdict" {
            let item = String(prompt.split(separator: "\n")[0].dropFirst("Item: ".count))
            for (name, v) in rules where item.hasSuffix("/" + name) { return v }
            return verdict("skip", "none", 5, 5)
        }
        if let other { return other }
        throw LLMError("no fake answer for \(schema.name)")
    }
}

func verdict(_ v: String, _ kind: String, _ safety: Int = 8, _ conf: Int = 8) -> JSONValue {
    .object(["verdict": .string(v), "action_type": .string(kind), "safety": .number(Double(safety)),
             "confidence": .number(Double(conf)), "reason": .string("test")])
}

func act(_ kind: String, _ safety: Int = 8, _ conf: Int = 8) -> JSONValue { verdict("act", kind, safety, conf) }
let DESCEND = verdict("descend", "none", 5, 5)

func tempDir() -> String {
    let p = Paths.resolve(NSTemporaryDirectory()) + "/bibi-test-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

func write(_ path: String, mb: Int) {
    try! FileManager.default.createDirectory(atPath: Paths.parent(path), withIntermediateDirectories: true)
    var data = Data(count: mb * MB)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, mb * MB) }
    FileManager.default.createFile(atPath: path, contents: data)
}

/// Temp dirs live under /private on macOS, which the default policy protects; tests lift that.
func testPolicy(regenerable: (@Sendable (String) -> Bool)? = nil) -> SafetyPolicy {
    var p = SafetyPolicy()
    p.protectedPrefixes.removeAll { $0 == "/private" }
    p.regenerableOverride = regenerable
    return p
}

func fixture(_ name: String) -> String {
    let url = Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)!
    return try! String(contentsOf: url, encoding: .utf8)
}
