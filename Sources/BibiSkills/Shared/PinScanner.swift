import BibiCore
import Foundation

/// Which runtime versions projects ask for (.python-version, .nvmrc, .tool-versions...), so bibi never
/// suggests removing a version a project still pins.
public struct Pins: Sendable {
    /// tool -> pinned version strings ("3.11", "18", "20.11.1")
    public var byTool: [String: Set<String>] = [:]
    /// tool -> files that pin it (for evidence)
    public var sources: [String: [String]] = [:]

    public init() {}

    public mutating func add(_ tool: String, _ version: String, from file: String) {
        var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") { v.removeFirst() }
        guard !v.isEmpty, v.first!.isNumber else { return }  // "lts/*", "system", "latest" can't be matched
        byTool[tool, default: []].insert(v)
        sources[tool, default: []].append(file)
    }

    /// True if any pin selects this installed version ("3.11" pins "3.11.4"; "18" pins "18.19.0").
    public func pins(_ tool: String, _ installed: String) -> Bool {
        var v = installed
        if v.hasPrefix("v") { v.removeFirst() }
        return (byTool[tool] ?? []).contains { v == $0 || v.hasPrefix($0 + ".") }
    }
}

public enum PinScanner {
    static let files: [(String, String)] = [
        (".python-version", "python"), (".nvmrc", "node"), (".node-version", "node"), (".ruby-version", "ruby"),
        (".java-version", "java"), (".go-version", "go"),
    ]
    /// .tool-versions (asdf/mise) names -> tool
    static let asdfNames = ["python": "python", "nodejs": "node", "node": "node", "ruby": "ruby", "java": "java",
                            "golang": "go", "go": "go", "rust": "rust"]

    public static func scan(_ dirs: [String], into pins: inout Pins) {
        for dir in dirs { scanDir(dir, into: &pins) }
    }

    public static func scanDir(_ dir: String, into pins: inout Pins) {
        for (file, tool) in files {
            let path = dir + "/" + file
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                pins.add(tool, String(line), from: path)
            }
        }
        if let text = try? String(contentsOfFile: dir + "/.tool-versions", encoding: .utf8) {
            parseToolVersions(text, from: dir + "/.tool-versions", into: &pins)
        }
    }

    public static func parseToolVersions(_ text: String, from file: String, into pins: inout Pins) {
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2, !cols[0].hasPrefix("#"), let tool = asdfNames[String(cols[0])] else { continue }
            for v in cols.dropFirst() { pins.add(tool, String(v), from: file) }
        }
    }

    /// Global defaults of version managers (also treated as "in use").
    public static func globalDefaults(home: String = Paths.home, into pins: inout Pins) {
        for (file, tool) in [(".pyenv/version", "python"), (".rbenv/version", "ruby"), (".nvm/alias/default", "node")] {
            if let text = try? String(contentsOfFile: home + "/" + file, encoding: .utf8) {
                for line in text.split(separator: "\n") { pins.add(tool, String(line), from: "~/" + file) }
            }
        }
        if let text = try? String(contentsOfFile: home + "/.tool-versions", encoding: .utf8) {
            parseToolVersions(text, from: "~/.tool-versions", into: &pins)
        }
        if let text = try? String(contentsOfFile: home + "/.config/mise/config.toml", encoding: .utf8) {
            // [tools] section: node = "20", python = ["3.12", "3.11"]
            var inTools = false
            for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if line.hasPrefix("[") { inTools = line == "[tools]"; continue }
                guard inTools, let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
                guard let tool = asdfNames[key] else { continue }
                for m in Re.all("\"([^\"]+)\"", String(line[line.index(after: eq)...])) {
                    pins.add(tool, m[1], from: "~/.config/mise/config.toml")
                }
            }
        }
    }
}
