import Foundation
import Synchronization

/// One parameter of a scripting command (or the direct parameter, which has no label).
public struct ScriptParam: Codable, Sendable, Equatable {
    public var name: String
    public var type: String
    public var optional: Bool
    public var help: String
}

public struct ScriptCommand: Codable, Sendable, Equatable {
    public var name: String
    public var help: String
    public var direct: ScriptParam?
    public var params: [ScriptParam]
    public var result: String?
}

public struct ScriptProperty: Codable, Sendable, Equatable {
    public var name: String
    public var type: String
    public var writable: Bool
    public var help: String
}

public struct ScriptClass: Codable, Sendable, Equatable {
    public var name: String
    public var plural: String?
    public var inherits: String?
    public var help: String
    public var properties: [ScriptProperty]
    /// Classes this one contains (`every <element> of <this>`).
    public var elements: [String]
}

/// What an app's scripting dictionary (.sdef) says it can do. The standard suite (open, close, make, delete...)
/// is left out: bibi offers make and list itself, on the app's own classes.
public struct AppDictionary: Codable, Sendable, Equatable {
    public var name: String
    public var bundleID: String
    public var path: String
    /// Modification time of the bundle's Info.plist when it was read (rescanned when it changes).
    public var modified: Double
    public var commands: [ScriptCommand]
    public var classes: [ScriptClass]
    public var enumerations: [String: [String]]
    /// Classes the application object contains directly (`every reminder`, `every note`).
    public var topElements: [String]

    public func command(_ name: String) -> ScriptCommand? { commands.first { Contacts.same($0.name, name) } }

    /// The class with properties and elements of the classes it inherits from.
    public func cls(_ name: String) -> ScriptClass? {
        guard var c = classes.first(where: { Contacts.same($0.name, name) || Contacts.same($0.plural ?? "", name) }) else { return nil }
        var seen: Set<String> = [c.name], parent = c.inherits
        while let p = parent, seen.insert(p).inserted, let pc = classes.first(where: { $0.name == p }) {
            c.properties += pc.properties.filter { pp in !c.properties.contains { $0.name == pp.name } }
            c.elements += pc.elements.filter { !c.elements.contains($0) }
            parent = pc.inherits
        }
        return c
    }

    /// Top-level classes that contain `name`, for listing elements that don't live on the application itself.
    public func containers(of name: String) -> [String] {
        // An account holds everything; the more specific container (list, calendar, folder) is meant.
        let found = topElements.filter { cls($0)?.elements.contains(name) == true }.sorted()
        return found.filter { $0 != "account" } + found.filter { $0 == "account" }
    }
}

/// Reads .sdef XML. Terms bibi will write into scripts must be plain words; anything else is dropped.
final class SdefParser: NSObject, XMLParserDelegate {
    var commands: [ScriptCommand] = []
    var classes: [String: ScriptClass] = [:]
    var order: [String] = []
    var enumerations: [String: [String]] = [:]
    var topElements: [String] = []

    private var command: ScriptCommand?
    private var cls: ScriptClass?
    private var extendsApp = false
    private var param: ScriptParam?, paramIsDirect = false
    private var property: ScriptProperty?
    private var enumeration: String?
    private var hiddenDepth = 0, depth = 0

    static func term(_ s: String?) -> String? {
        guard let s, Re.test("^[A-Za-z][A-Za-z0-9 ]{0,40}$", s) else { return nil }
        return s
    }

    static func parse(_ data: Data) -> SdefParser? {
        let p = SdefParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.shouldResolveExternalEntities = false
        return xml.parse() ? p : nil
    }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        depth += 1
        if hiddenDepth > 0 || a["hidden"] == "yes" {
            if hiddenDepth == 0 { hiddenDepth = depth }
            return
        }
        let help = a["description"] ?? ""
        switch el {
        case "command":
            if let n = Self.term(a["name"]) { command = ScriptCommand(name: n, help: help, direct: nil, params: [], result: nil) }
        case "direct-parameter":
            param = ScriptParam(name: "", type: a["type"] ?? "", optional: a["optional"] == "yes", help: help); paramIsDirect = true
        case "parameter":
            if let n = Self.term(a["name"]) {
                param = ScriptParam(name: n, type: a["type"] ?? "", optional: a["optional"] == "yes", help: help); paramIsDirect = false
            }
        case "result":
            command?.result = a["type"] ?? "any"
        case "class", "class-extension":
            let name = el == "class" ? a["name"] : a["extends"]
            extendsApp = el == "class-extension" && name == "application"
            if !extendsApp, let n = Self.term(name) {
                cls = classes[n] ?? ScriptClass(name: n, plural: Self.term(a["plural"]), inherits: Self.term(a["inherits"]),
                                                help: help, properties: [], elements: [])
                if cls?.help.isEmpty == true { cls?.help = help }
            }
        case "property", "contents":
            if !extendsApp, let n = Self.term(a["name"]) {
                property = ScriptProperty(name: n, type: a["type"] ?? "", writable: a["access"] != "r", help: help)
            }
        case "element":
            if let t = Self.term(a["type"]) {
                if extendsApp { if !topElements.contains(t) { topElements.append(t) } } else { cls?.elements.append(t) }
            }
        case "type":
            // <type type="text" list="yes"/> inside a parameter or property, when it has no type attribute.
            let t = (a["type"] ?? "") + (a["list"] == "yes" ? " list" : "")
            if param != nil, param?.type.isEmpty == true { param?.type = t }
            if property != nil, property?.type.isEmpty == true { property?.type = t }
        case "enumeration":
            enumeration = Self.term(a["name"])
            if let e = enumeration { enumerations[e] = [] }
        case "enumerator":
            if let e = enumeration, let n = Self.term(a["name"]) { enumerations[e]?.append(n) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        if hiddenDepth > 0 {
            if depth == hiddenDepth { hiddenDepth = 0 }
            return
        }
        switch el {
        case "command":
            if let c = command { commands.append(c) }
            command = nil
        case "direct-parameter", "parameter":
            if let p = param {
                if paramIsDirect { command?.direct = p } else { command?.params.append(p) }
            }
            param = nil
        case "class", "class-extension":
            if let c = cls {
                if classes[c.name] == nil { order.append(c.name) }
                classes[c.name] = c
            }
            cls = nil; extendsApp = false
        case "property", "contents":
            if let p = property, cls?.properties.contains(where: { $0.name == p.name }) == false { cls?.properties.append(p) }
            property = nil
        case "enumeration": enumeration = nil
        default: break
        }
    }
}

/// The scriptable apps installed on this Mac, read from their bundles and cached in apps.json. Each app's
/// dictionary is parsed again only when its Info.plist changes.
public final class AppCatalog: Sendable {
    let cachePath: String
    let roots: [String]
    private let state = Mutex<(apps: [AppDictionary]?, checked: Date?, synced: Bool)>((nil, nil, false))

    public static let defaultRoots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                                      Paths.home + "/Applications"]

    /// Apps whose dictionaries run shell commands or arbitrary scripts: chat never drives them.
    static let blocked: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.ScriptEditor2",
                                       "com.apple.Automator", "com.apple.systemevents", "com.apple.Console"]

    public init(cachePath: String = Paths.bibiHome + "/apps.json", roots: [String] = AppCatalog.defaultRoots) {
        self.cachePath = cachePath; self.roots = roots
    }

    public var apps: [AppDictionary] {
        state.withLock { s in
            if s.apps == nil {
                s.apps = (try? Data(contentsOf: URL(fileURLWithPath: cachePath))).flatMap { try? JSON.decoder.decode([AppDictionary].self, from: $0) } ?? []
            }
            return s.apps!
        }
    }

    /// An app by name ("Mail") or bundle id.
    public func app(_ name: String) -> AppDictionary? {
        apps.first { Contacts.same($0.name, name) || $0.bundleID == name }
    }

    /// Rescans when the last check is older than `maxAge`, then mirrors the catalog into the graph the first time
    /// and whenever it changed. Cheap when nothing changed: one stat per app bundle.
    public func refresh(graph: GraphStore?, maxAge: TimeInterval = 600, now: Date = Date()) {
        let due = state.withLock { s in s.checked.map { now.timeIntervalSince($0) > maxAge } ?? true }
        guard due else { return }
        let changed = scan()
        state.withLock { $0.checked = now }
        let synced = state.withLock { $0.synced }
        if let graph, changed || !synced {
            sync(graph)
            state.withLock { $0.synced = true }
        }
    }

    /// Reads every scriptable app bundle under the roots. Returns true if the catalog changed.
    @discardableResult
    public func scan() -> Bool {
        let old = Dictionary(apps.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var found: [AppDictionary] = [], seen = Set<String>()
        for root in roots {
            for entry in ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted() where entry.hasSuffix(".app") {
                let path = root + "/" + entry
                guard let app = Self.read(path, cached: old[path]), seen.insert(app.bundleID).inserted else { continue }
                found.append(app)
            }
        }
        let changed = found != apps
        if changed {
            state.withLock { $0.apps = found }
            try? FileManager.default.createDirectory(atPath: Paths.parent(cachePath), withIntermediateDirectories: true)
            try? JSON.encoder.encode(found).write(to: URL(fileURLWithPath: cachePath), options: .atomic)
        }
        return changed
    }

    static func read(_ path: String, cached: AppDictionary?) -> AppDictionary? {
        let plist = path + "/Contents/Info.plist"
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: plist))?[.modificationDate] as? Date else { return nil }
        if let cached, cached.modified == mtime.timeIntervalSince1970 {
            return blocked.contains(cached.bundleID) || isRetired(cached.bundleID) ? nil : cached
        }
        guard let info = NSDictionary(contentsOfFile: plist) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String, !blocked.contains(bundleID),
              var sdef = info["OSAScriptingDefinition"] as? String, !isRetired(bundleID) else { return nil }
        if !sdef.hasSuffix(".sdef") { sdef += ".sdef" }
        guard let data = FileManager.default.contents(atPath: path + "/Contents/Resources/" + sdef),
              let p = SdefParser.parse(data) else { return nil }
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? Paths.name(path).replacingOccurrences(of: ".app", with: "")
        return AppDictionary(name: name, bundleID: bundleID, path: path, modified: mtime.timeIntervalSince1970,
                             commands: p.commands, classes: p.order.compactMap { p.classes[$0] }, enumerations: p.enumerations,
                             topElements: p.topElements)
    }

    /// New Outlook ships legacy Outlook's dictionary but ignores it. The switch lives in its sandbox container.
    static func isRetired(_ bundleID: String) -> Bool {
        guard bundleID == "com.microsoft.Outlook" else { return false }
        let prefs = Paths.home + "/Library/Containers/com.microsoft.Outlook/Data/Library/Preferences/com.microsoft.Outlook.plist"
        return (NSDictionary(contentsOfFile: prefs)?["IsRunningNewOutlook"] as? NSNumber)?.boolValue == true
    }

    // MARK: graph

    public static func capabilityID(_ app: AppDictionary, _ kind: String, _ name: String) -> String {
        "cap:\(app.bundleID):\(kind):\(name)"
    }

    /// One `capability` node per command and per class chat can make or list, so retrieval finds them like skills.
    public func sync(_ graph: GraphStore) {
        var current = Set<String>()
        for app in apps {
            for c in app.commands {
                let id = Self.capabilityID(app, "command", c.name)
                current.insert(id)
                let params = ([c.direct.map { _ in "direct" }].compactMap { $0 } + c.params.map(\.name)).joined(separator: ", ")
                GraphSync.ensure(graph, GraphNode(id: id, kind: "capability", name: "\(app.name) \(c.name)",
                                                  text: "\(app.name): \(c.name). \(c.help) \(params)",
                                                  props: ["app": .string(app.bundleID), "op": .string("command"), "term": .string(c.name)]))
            }
            for name in Set(app.topElements + app.topElements.flatMap { app.cls($0)?.elements ?? [] }).sorted() {
                guard let c = app.cls(name), !c.properties.isEmpty else { continue }
                let id = Self.capabilityID(app, "class", c.name)
                current.insert(id)
                GraphSync.ensure(graph, GraphNode(id: id, kind: "capability", name: "\(app.name) \(c.plural ?? c.name)",
                                                  text: "\(app.name) \(c.plural ?? c.name): \(c.help) \(c.properties.prefix(10).map(\.name).joined(separator: ", "))",
                                                  props: ["app": .string(app.bundleID), "op": .string("class"), "term": .string(c.name)]))
            }
        }
        for n in graph.nodes(kind: "capability") where !current.contains(n.id) { graph.delete(n.id) }
    }
}
