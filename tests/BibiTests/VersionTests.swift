import BibiCore
import Foundation
import Testing

@Suite struct VersionTests {
    @Test func matchesVersionFile() throws {
        // Tests/BibiTests/VersionTests.swift -> repository root.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
        #expect(file.trimmingCharacters(in: .whitespacesAndNewlines) == Bibi.version)
    }
}
