import Foundation

/// A use of a discovered app, as the model proposes it: run one of its commands, make an object of one of its
/// classes, or list objects of a class. Values are plain strings; bibi checks them against the app's dictionary.
public struct AppCall: Codable, Sendable, Equatable {
    public var op: String  // command | make | list
    public var term: String  // the command or class
    public var values: [String: String]

    public init(op: String, term: String, values: [String: String] = [:]) { self.op = op; self.term = term; self.values = values }
}

/// What an app call can do, decided from the dictionary by bibi's rules (never by the model).
public enum AppRisk: String, Codable, Sendable {
    case readOnly = "read-only"
    case writes
    case destructive
    /// Sends something to other people or places a call: can't be taken back.
    case outbound

    public var safety: Int { [.readOnly: 10, .writes: 6, .destructive: 3, .outbound: 3][self]! }
}

/// The AppleScript bibi wrote for a call, its arguments, and how to show it.
public struct AppScript: Sendable {
    public var source: String
    public var args: [String]
    public var risk: AppRisk
    public var title: String
    /// Every value the script uses, in full, for the approval card.
    public var steps: [String]
    /// For make: the class whose `id` the script returns, so the new object can be deleted again.
    public var undoClass: String?
}

/// Writes AppleScript for discovered apps. The model never writes script text: terms come from the app's
/// dictionary (plain words, checked by SdefParser), and every value is passed as an argument.
public enum AppScripts {
    static let reserved: Set<String> = ["at", "where", "fields", "limit", "direct"]
    /// Commands that run code or drive the UI: refused whatever app offers them.
    static let refusedWords = ["script", "javascript", "shell", "execute", "evaluate", "keystroke", "key code", "click",
                               "applescript", "automator", "terminal"]
    static let readVerbs: Set<String> = ["get", "count", "exists", "search", "find", "lookup", "fetch"]
    static let outboundWords: Set<String> = ["send", "reply", "forward", "redirect", "bounce", "post", "share", "call", "dial",
                                             "invite", "publish", "upload", "tweet", "submit", "email", "message", "airdrop"]
    static let destructiveWords: Set<String> = ["delete", "erase", "remove", "empty", "clear", "wipe", "reset", "quit", "close",
                                                "restart", "shutdown", "shut", "logout", "log", "sleep", "eject", "format",
                                                "uninstall", "purge", "trash", "kill", "terminate", "cancel", "decline", "archive",
                                                "unsubscribe", "revoke"]

    /// Credentials an app exposes as properties (Mail's account password): never read or set from chat.
    static func secret(_ property: String) -> Bool {
        let p = property.lowercased()
        return ["password", "passcode", "passphrase", "secret", "token", "credential"].contains { p.contains($0) }
    }

    public static func risk(ofCommand name: String) -> AppRisk {
        let words = Set(Similarity.tokens(name))
        if !words.isDisjoint(with: outboundWords) { return .outbound }
        if !words.isDisjoint(with: destructiveWords) { return .destructive }
        if let first = Similarity.tokens(name).first, readVerbs.contains(first) { return .readOnly }
        return .writes
    }

    public static func refusal(ofCommand name: String) -> String? {
        let lower = name.lowercased()
        guard let w = refusedWords.first(where: { lower.contains($0) }) else { return nil }
        return "'\(name)' would run code or drive the screen (\(w)); bibi doesn't use it"
    }

    /// key=value arguments → a call. `command=<name>`, `make=<class>` or `list=<class>` says what to do.
    public static func parse(_ args: [String]) throws -> AppCall {
        var values: [String: String] = [:], op: (String, String)?
        for a in args {
            guard let eq = a.firstIndex(of: "=") else { throw ActionError("expected key=value, got \(a)") }
            let key = a[..<eq].trimmingCharacters(in: .whitespaces).lowercased(), value = String(a[a.index(after: eq)...])
            if ["command", "make", "list"].contains(key) { op = (key, value.trimmingCharacters(in: .whitespaces)) } else { values[key] = value }
        }
        // Small models also write op=make class=note.
        if op == nil, let o = values["op"], let c = values["class"] ?? values["command"], ["command", "make", "list"].contains(o) {
            op = (o, c)
            values["op"] = nil; values["class"] = nil; values["command"] = nil
        }
        guard let (o, term) = op, !term.isEmpty else { throw ActionError("say what to do: command=<command>, make=<class> or list=<class>") }
        return AppCall(op: o, term: term, values: values)
    }

    /// Brings values into the form validation accepts: dates the model wrote in words become exact dates, ~ paths
    /// become absolute. Done once, when the step is proposed, so the card shows what will run.
    public static func normalize(_ call: AppCall, _ app: AppDictionary, home: String = Paths.home, now: Date = Date()) -> AppCall {
        var call = call
        let types: [String: String]
        switch call.op {
        case "command":
            guard let c = app.command(call.term) else { return call }
            types = Dictionary(c.params.map { ($0.name.lowercased(), $0.type) } + (c.direct.map { [("direct", $0.type)] } ?? []),
                               uniquingKeysWith: { a, _ in a })
        default:
            types = Dictionary((app.cls(call.term)?.properties ?? []).map { ($0.name.lowercased(), $0.type) }, uniquingKeysWith: { a, _ in a })
        }
        for (k, v) in call.values {
            switch types[k]?.lowercased() {
            case "date": if let d = DateText.normalize(v, now: now) { call.values[k] = d }
            case "file", "alias": call.values[k] = Paths.standardize(CommandPolicy.expand(v, home: home))
            default: break
            }
        }
        return call
    }

    public static func build(_ call: AppCall, _ app: AppDictionary) throws -> AppScript {
        var b = Builder(app: app)
        switch call.op {
        case "command": return try b.command(call)
        case "make": return try b.make(call)
        case "list": return try b.list(call)
        default: throw ActionError("unknown app operation '\(call.op)'")
        }
    }

    /// One line for the tool list: how to call a capability, with its parameters.
    public static func hint(_ app: AppDictionary, op: String, term: String) -> String? {
        if op == "command", let c = app.command(term) {
            var args = ["command=\(c.name)"]
            if let d = c.direct, !d.optional { args.append("direct=<\(d.type.ifEmpty("value"))>") }
            args += c.params.filter { !$0.optional }.map { "\($0.name)=<\($0.type.ifEmpty("value"))>" }
            let optional = c.params.filter(\.optional).map(\.name) + (c.direct?.optional == true ? ["direct"] : [])
            return "- app:\(app.name) \(JSON.string(args)): \(Text.oneLine(c.help, max: 110))"
                + (optional.isEmpty ? "" : " Optional: \(optional.joined(separator: ", ")).")
        }
        if op == "class", let c = app.cls(term) {
            let settable = c.properties.filter { $0.writable && !secret($0.name) && Builder.passable($0.type, app) }.map(\.name)
            var text = "- app:\(app.name) [\"list=\(c.name)\", \"where=<text in the name>\"] lists \(c.plural ?? c.name)"
            if !settable.isEmpty {
                text += "; [\"make=\(c.name)\", \"\(settable[0])=...\"] creates one. Settable: \(settable.prefix(8).joined(separator: ", "))"
            }
            let container = app.topElements.contains(c.name) ? nil : app.containers(of: c.name).first
            return text + (container.map { ". In one \($0): \"at=\($0):<name>\"" } ?? "")
        }
        return nil
    }

    public static let helpers = """
    on mkdate(s)
    \tset d to current date
    \tset day of d to 1
    \tset year of d to (text 1 thru 4 of s) as integer
    \tset month of d to (text 6 thru 7 of s) as integer
    \tset day of d to (text 9 thru 10 of s) as integer
    \tset hours of d to 0
    \tset minutes of d to 0
    \tif (length of s) > 15 then
    \t\tset hours of d to (text 12 thru 13 of s) as integer
    \t\tset minutes of d to (text 15 thru 16 of s) as integer
    \tend if
    \tset seconds of d to 0
    \treturn d
    end mkdate

    on joinlist(xs, sep)
    \tset saved to AppleScript's text item delimiters
    \tset AppleScript's text item delimiters to sep
    \tset t to xs as text
    \tset AppleScript's text item delimiters to saved
    \treturn t
    end joinlist

    on totext(x)
    \ttry
    \t\tif class of x is list then
    \t\t\tset out to {}
    \t\t\trepeat with i in x
    \t\t\t\tset end of out to my totext(contents of i)
    \t\t\tend repeat
    \t\t\treturn my joinlist(out, ", ")
    \t\tend if
    \tend try
    \ttry
    \t\treturn x as text
    \tend try
    \ttry
    \t\treturn (name of x) as text
    \tend try
    \treturn "(an object)"
    end totext

    on flatten(xs)
    \tset out to {}
    \trepeat with i in xs
    \t\tset v to contents of i
    \t\tif class of v is list then
    \t\t\tset out to out & v
    \t\telse
    \t\t\tset end of out to v
    \t\tend if
    \tend repeat
    \treturn out
    end flatten

    """

    struct Builder {
        let app: AppDictionary
        var args: [String] = []
        var shown: [String] = []

        init(app: AppDictionary) { self.app = app }

        static func passable(_ type: String, _ app: AppDictionary) -> Bool {
            let t = type.lowercased()
            return ["", "text", "string", "unicode text", "any", "rich text", "integer", "real", "number", "double integer",
                    "boolean", "date", "file", "alias"].contains(t) || app.enumerations[type] != nil
        }

        mutating func arg(_ v: String) -> String {
            args.append(v)
            return "(item \(args.count) of argv)"
        }

        /// The AppleScript expression for `v` as a value of `type`.
        mutating func value(_ type: String, _ v: String, what: String) throws -> String {
            let t = type.lowercased()
            switch t {
            case "", "text", "string", "unicode text", "any", "rich text", "styled text":
                return arg(v)
            case "integer":
                guard Int(v.trimmingCharacters(in: .whitespaces)) != nil else { throw ActionError("\(what) must be a whole number, got \(v)") }
                return "(\(arg(v.trimmingCharacters(in: .whitespaces))) as integer)"
            case "real", "number", "double integer":
                guard Double(v.trimmingCharacters(in: .whitespaces)) != nil else { throw ActionError("\(what) must be a number, got \(v)") }
                return "(\(arg(v.trimmingCharacters(in: .whitespaces))) as real)"
            case "boolean":
                switch v.lowercased() {
                case "true", "yes": return "true"
                case "false", "no": return "false"
                default: throw ActionError("\(what) must be true or false, got \(v)")
                }
            case "date":
                guard DateText.strict(v) != nil else { throw ActionError("\(what) must be a date like 2026-10-27 15:00, got \(v)") }
                return "(my mkdate(\(arg(v))))"
            case "file", "alias":
                guard v.hasPrefix("/"), Paths.exists(v) else { throw ActionError("\(what): \(v) is not an existing absolute path") }
                return "(POSIX file \(arg(v)))"
            default:
                if let e = app.enumerations[type] {
                    guard let hit = e.first(where: { Contacts.same($0, v.trimmingCharacters(in: .whitespaces)) }) else {
                        throw ActionError("\(what) must be one of: \(e.joined(separator: ", "))")
                    }
                    return hit
                }
                if ["specifier", "location specifier", "reference", "item"].contains(t) || app.cls(type) != nil {
                    return try reference(v, defaultClass: app.cls(type)?.name, what: what)
                }
                throw ActionError("\(what) takes a \(type), which bibi can't pass from chat")
            }
        }

        /// "list:Groceries" or, when the class is known, "Groceries": the first such object with that name.
        mutating func reference(_ v: String, defaultClass: String?, what: String) throws -> String {
            var cls = defaultClass.flatMap(app.cls), name = v
            if let colon = v.firstIndex(of: ":"), let c = app.cls(v[..<colon].trimmingCharacters(in: .whitespaces)) {
                cls = c
                name = v[v.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let c = cls else { throw ActionError("\(what): say which object as <class>:<name>, like list:Groceries") }
            guard c.properties.contains(where: { $0.name == "name" }) else { throw ActionError("\(what): \(c.name) objects have no name to find them by") }
            guard app.topElements.contains(c.name) else { throw ActionError("\(what): bibi can only find \(c.name) objects inside another object") }
            return "(first \(c.name) whose name is \(arg(name)))"
        }

        func script(_ body: String) -> String {
            AppScripts.helpers + "on run argv\n\ttell application id \"\(app.bundleID)\"\n" + body + "\tend tell\nend run\n"
        }

        mutating func command(_ call: AppCall) throws -> AppScript {
            guard let c = app.command(call.term) else {
                throw ActionError("\(app.name) has no command '\(call.term)' (has: \(app.commands.map(\.name).joined(separator: ", ")))")
            }
            if let why = AppScripts.refusal(ofCommand: c.name) { throw ActionError(why) }
            var text = c.name, line = "\(app.name): \(c.name)"
            if let d = c.direct {
                if let v = call.values["direct"] {
                    text += " " + (try value(d.type, v, what: "\(c.name)"))
                    line += " " + v
                } else if !d.optional {
                    throw ActionError("\(c.name) needs direct=<\(d.type.ifEmpty("value"))>")
                }
            }
            for (k, v) in call.values.sorted(by: { $0.key < $1.key }) where k != "direct" {
                guard let p = c.params.first(where: { Contacts.same($0.name, k) }) else {
                    throw ActionError("\(c.name) has no parameter '\(k)' (has: \(c.params.map(\.name).joined(separator: ", ")))")
                }
                text += " \(p.name) " + (try value(p.type, v, what: "\(c.name) \(p.name)"))
                line += "; \(p.name): \(v)"
            }
            let missing = c.params.filter { p in !p.optional && !call.values.keys.contains { Contacts.same($0, p.name) } }
            if !missing.isEmpty { throw ActionError("\(c.name) needs " + missing.map { "\($0.name)=..." }.joined(separator: ", ")) }
            let body = "\t\tset r to (\(text))\n\tend tell\n\ttry\n\t\treturn my totext(r)\n\ton error number -2753\n\t\treturn \"done\"\n\tend try\n"
            // The tell block closes early so a command without a result can be told apart.
            let source = AppScripts.helpers + "on run argv\n\ttell application id \"\(app.bundleID)\"\n" + body + "end run\n"
            return AppScript(source: source, args: args, risk: AppScripts.risk(ofCommand: c.name),
                             title: "\(app.name): \(c.name)", steps: [line], undoClass: nil)
        }

        func requireClass(_ name: String) throws -> ScriptClass {
            guard let c = app.cls(name) else {
                let known = Set(app.topElements + app.topElements.flatMap { app.cls($0)?.elements ?? [] }).sorted()
                throw ActionError("\(app.name) has no class '\(name)' (has: \(known.joined(separator: ", ")))")
            }
            return c
        }

        /// at=<class>:<name> or at=<name> (in the class's usual container).
        mutating func container(_ call: AppCall, for c: ScriptClass) throws -> (expr: String, shown: String)? {
            guard let at = call.values["at"], !at.isEmpty else { return nil }
            return (try reference(at, defaultClass: app.containers(of: c.name).first, what: "at"), at)
        }

        mutating func make(_ call: AppCall) throws -> AppScript {
            let c = try requireClass(call.term)
            // Some apps (Photos) replace the standard make with one that takes no properties.
            if let own = app.command("make"), !own.params.contains(where: { $0.name == "with properties" }) {
                throw ActionError("\(app.name) creates objects its own way; bibi can't make a \(c.name) there")
            }
            var props: [String] = [], line = ["\(app.name): create a \(c.name)"]
            for (k, v) in call.values.sorted(by: { $0.key < $1.key }) where !AppScripts.reserved.contains(k) {
                guard let p = c.properties.first(where: { Contacts.same($0.name, k) }) else {
                    throw ActionError("a \(c.name) has no property '\(k)' (has: \(c.properties.map(\.name).joined(separator: ", ")))")
                }
                guard p.writable, !AppScripts.secret(p.name) else { throw ActionError("\(c.name) \(p.name) can't be set from chat") }
                props.append("\(p.name):" + (try value(p.type, v, what: "\(c.name) \(p.name)")))
                line.append("\(p.name): \(v)")
            }
            let at = try container(call, for: c)
            if let at { line.append("in \(at.shown)") }
            let hasID = c.properties.contains { $0.name == "id" } && app.topElements.contains(c.name)
            var body = "\t\tset r to make new \(c.name)" + (at.map { " at \($0.expr)" } ?? "") + " with properties {\(props.joined(separator: ", "))}\n"
            body += "\t\tset out to \"created \" & my totext(r)\n"
            if hasID { body += "\t\ttry\n\t\t\tset out to out & linefeed & \"id:\" & ((id of r) as text)\n\t\tend try\n" }
            body += "\t\treturn out\n"
            return AppScript(source: script(body), args: args, risk: .writes, title: "\(app.name): create a \(c.name)",
                             steps: [line.joined(separator: "; ")], undoClass: hasID ? c.name : nil)
        }

        mutating func list(_ call: AppCall) throws -> AppScript {
            let c = try requireClass(call.term)
            let names = c.properties.map(\.name)
            let fields = try (call.values["fields"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                              ?? [names.contains("name") ? "name" : (names.first ?? "")]).map { f -> String in
                guard let p = c.properties.first(where: { Contacts.same($0.name, f) }) else {
                    throw ActionError("a \(c.name) has no property '\(f)' (has: \(names.joined(separator: ", ")))")
                }
                guard !AppScripts.secret(p.name) else { throw ActionError("bibi doesn't read \(c.name) \(p.name)") }
                return p.name
            }
            let limit = min(50, max(1, Int(call.values["limit"] ?? "") ?? 20))
            var line = "\(app.name): list \(c.plural ?? c.name) (\(fields.joined(separator: ", ")))"
            var filter = ""
            if let w = call.values["where"], !w.isEmpty {
                guard names.contains("name") else { throw ActionError("\(c.name) objects have no name to filter on") }
                filter = " whose name contains \(arg(w))"
                line += " whose name contains \"\(w)\""
            }
            var source: String
            if let at = try container(call, for: c) {
                source = "(every \(c.name)\(filter)) of \(at.expr)"
                line += " in \(at.shown)"
            } else if app.topElements.contains(c.name) {
                source = "every \(c.name)\(filter)"
            } else if let parent = app.containers(of: c.name).first {
                source = "my flatten((every \(c.name)\(filter)) of every \(parent))"
            } else {
                throw ActionError("say where to look: at=<class>:<name>")
            }
            var body = "\t\tset xs to \(source)\n\t\tset total to count of xs\n\t\tset out to {}\n"
            body += "\t\trepeat with i from 1 to total\n\t\t\tif i > \(limit) then exit repeat\n\t\t\tset x to item i of xs\n\t\t\tset row to {}\n"
            for f in fields { body += "\t\t\tset end of row to my totext(\(f) of x)\n" }
            body += "\t\t\tset end of out to my joinlist(row, \" | \")\n\t\tend repeat\n"
            body += "\t\treturn (total as text) & \" found\" & linefeed & my joinlist(out, linefeed)\n"
            return AppScript(source: script(body), args: args, risk: .readOnly, title: "\(app.name): list \(c.plural ?? c.name)",
                             steps: [line], undoClass: nil)
        }
    }
}

/// Runs an app call the user approved. The call is stored, never the script: the script is written again from the
/// app's current dictionary right before it runs, so a stored report can't carry other script text.
public struct RunAppCall: ActionSpec {
    public let id = "run_app_call"
    public let summary = "Use an app on this Mac through its scripting dictionary"
    public init() {}

    func resolve(_ p: Params, _ env: ActionEnv) throws -> (AppDictionary, AppScript) {
        let bundle = try require(p, "app")
        guard let app = env.apps.catalog.app(bundle) else { throw ActionError("\(bundle) is not a scriptable app on this Mac") }
        guard let call = try? JSON.decode(AppCall.self, from: try require(p, "call")) else { throw ActionError("\(id): bad call") }
        return (app, try AppScripts.build(call, app))
    }

    public func validate(_ p: Params, _ env: ActionEnv) throws { _ = try resolve(p, env) }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        let (_, s) = try resolve(p, env)
        let note = s.undoClass != nil ? "undo deletes it again" : s.risk == .readOnly ? "read-only" : "\(s.risk.rawValue); cannot be undone by bibi"
        return s.steps + ["(\(note))"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let (app, s) = try resolve(p, env)
        let out = try await env.apps.scripts.run(s.source, args: s.args, timeout: 90)
        var lines = out.components(separatedBy: "\n")
        var undo: ActionCall?
        if let cls = s.undoClass, let last = lines.last, last.hasPrefix("id:") {
            lines.removeLast()
            undo = ActionCall("app_delete", ["app": app.bundleID, "class": cls, "id": String(last.dropFirst(3))])
        }
        let text = lines.joined(separator: "\n")
        return Outcome(s.risk == .readOnly ? "read \(app.name)" : Text.oneLine(text.ifEmpty("done"), max: 160), undo: undo,
                       output: Text.clip(text.ifEmpty("(no output)"), max: 20000))
    }

    public static func call(_ app: AppDictionary, _ c: AppCall) -> ActionCall {
        ActionCall("run_app_call", ["app": app.bundleID, "call": JSON.string(c)])
    }
}

/// Undo for app_call make: deletes the object it created, found by the id it returned.
public struct AppDelete: ActionSpec {
    public let id = "app_delete"
    public let summary = "Delete an object bibi created in an app"
    public var selectable: Bool { false }
    public init() {}

    func resolve(_ p: Params, _ env: ActionEnv) throws -> (AppDictionary, ScriptClass, String) {
        let bundle = try require(p, "app"), cls = try require(p, "class"), oid = try require(p, "id")
        guard let app = env.apps.catalog.app(bundle), let c = app.cls(cls), app.topElements.contains(c.name),
              c.properties.contains(where: { $0.name == "id" }) else { throw ActionError("can't find \(cls) objects in \(bundle)") }
        return (app, c, oid)
    }

    public func validate(_ p: Params, _ env: ActionEnv) throws { _ = try resolve(p, env) }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        let (app, c, _) = try resolve(p, env)
        return ["\(app.name): delete the \(c.name) bibi created"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let (app, c, oid) = try resolve(p, env)
        let source = "on run argv\n\ttell application id \"\(app.bundleID)\"\n\t\tdelete (first \(c.name) whose id is (item 1 of argv))\n\tend tell\nend run\n"
        _ = try await env.apps.scripts.run(source, args: [oid], timeout: 60)
        return Outcome("deleted the \(c.name) from \(app.name)")
    }
}
