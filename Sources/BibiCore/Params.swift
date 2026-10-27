import Foundation

/// A declared skill parameter. One declaration drives the CLI parser, `--help`, and the web form.
public struct Param: Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case string, int, size, flag, list }

    public var key: String
    public var flags: [String]  // empty = positional
    public var kind: Kind
    public var help: String
    public var defaultValue: String?
    public var metavar: String?
    public var required: Bool

    public static func positional(_ key: String, help: String, default value: String? = nil) -> Param {
        Param(key: key, flags: [], kind: .string, help: help, defaultValue: value, metavar: key, required: value == nil)
    }

    public static func option(_ key: String, _ flags: String..., kind: Kind = .string, default value: String? = nil,
                              metavar: String? = nil, help: String) -> Param {
        Param(key: key, flags: flags, kind: kind, help: help, defaultValue: value, metavar: metavar, required: false)
    }

    public static func flag(_ key: String, _ flags: String..., help: String) -> Param {
        Param(key: key, flags: flags, kind: .flag, help: help, defaultValue: nil, metavar: nil, required: false)
    }
}

public struct ArgError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Parsed parameter values.
public struct Args: Sendable, Codable, Equatable {
    public var values: [String: [String]]
    public init(_ values: [String: [String]] = [:]) { self.values = values }

    public func string(_ key: String) -> String? { values[key]?.last }
    public func list(_ key: String) -> [String] { values[key] ?? [] }
    public func flag(_ key: String) -> Bool { values[key] != nil }
    public func int(_ key: String) -> Int? { string(key).flatMap { Int($0) } }
    public func size(_ key: String) -> Int? { string(key).flatMap { try? parseSize($0) } }

    /// Parses argv against params; unknown options and bad values throw ArgError.
    public static func parse(_ argv: [String], params: [Param]) throws -> Args {
        var values: [String: [String]] = [:]
        var positionals = params.filter { $0.flags.isEmpty }
        var i = 0
        while i < argv.count {
            var arg = argv[i]
            var inline: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                inline = String(arg[arg.index(after: eq)...])
                arg = String(arg[..<eq])
            }
            if arg.hasPrefix("-") && arg.count > 1 && Double(arg) == nil {
                guard let p = params.first(where: { $0.flags.contains(arg) }) else { throw ArgError("unknown option \(arg)") }
                if p.kind == .flag {
                    values[p.key] = ["true"]
                } else {
                    let v: String
                    if let inline { v = inline } else {
                        i += 1
                        guard i < argv.count else { throw ArgError("\(arg) needs a value") }
                        v = argv[i]
                    }
                    try validate(p, v)
                    values[p.key, default: []].append(v)
                }
            } else {
                guard let p = positionals.first else { throw ArgError("unexpected argument \(arg)") }
                try validate(p, arg)
                // A list positional takes every remaining word ("bibi skills.create show free space").
                if p.kind == .list {
                    values[p.key, default: []].append(arg)
                } else {
                    positionals.removeFirst()
                    values[p.key] = [arg]
                }
            }
            i += 1
        }
        for p in params where values[p.key] == nil {
            if let d = p.defaultValue { values[p.key] = [d] }
            else if p.required { throw ArgError("missing \(p.metavar ?? p.key)") }
        }
        return Args(values)
    }

    private static func validate(_ p: Param, _ v: String) throws {
        switch p.kind {
        case .int where Int(v) == nil: throw ArgError("\(p.flags.first ?? p.key): not a number: \(v)")
        case .size: _ = try parseSize(v)
        default: break
        }
    }

    /// argv back from values (for history and re-running).
    public func argv(params: [Param]) -> [String] {
        var out: [String] = []
        for p in params {
            guard let vs = values[p.key] else { continue }
            if p.flags.isEmpty { out += p.kind == .list ? vs : Array(vs.prefix(1)) }
            else if p.kind == .flag { out.append(p.flags.last!) }
            else { for v in vs where v != p.defaultValue { out += [p.flags.last!, v] } }
        }
        return out
    }
}

/// "500M", "2G", "1.5GB" -> bytes.
public func parseSize(_ text: String) throws -> Int {
    let t = text.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: "B", with: "")
    let units: [Character: Int] = ["K": 1, "M": 2, "G": 3, "T": 4]
    var num = Substring(t), exp = 0
    if let last = t.last, let e = units[last] { num = t.dropLast(); exp = e }
    guard let n = Double(num.trimmingCharacters(in: .whitespaces)), n >= 0 else {
        throw ArgError("invalid size: '\(text)' (try 500M or 2G)")
    }
    return Int(n * pow(1024, Double(exp)))
}

/// Help text for a list of params.
public func helpText(_ params: [Param]) -> String {
    params.map { p in
        let name = p.flags.isEmpty ? (p.metavar ?? p.key)
            : p.flags.joined(separator: ", ") + (p.kind == .flag ? "" : " " + (p.metavar ?? p.key.uppercased()))
        let def = p.defaultValue.map { " (default \($0))" } ?? ""
        return "  " + name.padding(toLength: max(24, name.count + 2), withPad: " ", startingAt: 0) + p.help + def
    }.joined(separator: "\n")
}
