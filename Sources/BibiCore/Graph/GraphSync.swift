import Foundation

/// Mirrors the compiled-in skills into the graph so chat can retrieve them and statistics can attach to them.
///
/// The skill tree: `skill:generic` (the chat's generic skill) is the root; namespaces (`skill:storage`, ...,
/// `skill:learned`) are its children; skills are children of their namespace. Each skill links to the actions
/// it contributes (`uses`). Collector logic stays in Swift; the graph holds what chat and tuning need.
public enum GraphSync {
    public static let root = "skill:generic"

    public static func skillID(_ name: String) -> String { "skill:" + name }

    public static func syncBuiltins(_ graph: GraphStore, skills: [any Skill], registry: ActionRegistry) {
        ensure(graph, GraphNode(id: root, kind: "skill", name: "generic",
                                text: "Answer questions about this Mac and do things on it by proposing commands for approval.",
                                props: ["source": .string("builtin")]))
        let namespaces = Set(skills.map(\.namespace)).union(["learned"])
        for ns in namespaces {
            ensure(graph, GraphNode(id: skillID(ns), kind: "namespace", name: ns, text: ns + " skills"))
            graph.link(skillID(ns), root, "child_of")
        }
        for a in registry.all where a.selectable {
            ensure(graph, GraphNode(id: "action:" + a.id, kind: "action", name: a.id, text: a.summary,
                                    props: ["privilege": .string(a.privilege.rawValue), "reversible": .bool(a.reversible)]))
        }
        let current = Set(skills.map { skillID($0.name) })
        for s in skills {
            let params = s.params.map { p -> JSONValue in
                .object(["key": .string(p.key), "flags": .strings(p.flags), "help": .string(p.help)])
            }
            ensure(graph, GraphNode(id: skillID(s.name), kind: "skill", name: s.name, text: s.help + "\n" + describe(s.params),
                                    props: ["source": .string("builtin"), "params": .array(params), "keywords": .string(s.keywords),
                                            "actions": .strings(s.actionSpecs.map(\.id))]))
            graph.link(skillID(s.name), skillID(s.namespace), "child_of")
            for a in s.actionSpecs where a.selectable { graph.link(skillID(s.name), "action:" + a.id, "uses") }
        }
        Seeds.sync(graph)
        // Built-ins that no longer exist keep their statistics but stop being offered.
        for n in graph.nodes(kind: "skill") where n.props["source"]?.string == "builtin" && n.id != root && !current.contains(n.id) {
            if n.status != "retired" { graph.setStatus(n.id, "retired") }
        }
    }

    /// Upserts only if something visible changed (keeps `updated` meaningful and startup cheap).
    static func ensure(_ graph: GraphStore, _ n: GraphNode) {
        if let old = graph.node(n.id), old.kind == n.kind, old.name == n.name, old.text == n.text, old.props == n.props,
           old.status == n.status || old.status == "disabled" { return }
        var n = n
        if let old = graph.node(n.id), old.status == "disabled" { n.status = "disabled" }
        graph.upsert(n)
    }

    /// How to pass arguments, with defaults filled in, e.g. ["--top", "5"] (what a small model copies best).
    public static func example(_ params: [Param]) -> String {
        if let p = params.first(where: { $0.flags.isEmpty && $0.required }) {
            return "args: [\"<\(p.metavar ?? p.key)>\"] (required: \(p.help))"
        }
        let items = params.filter { !$0.flags.isEmpty && $0.kind != .flag && $0.defaultValue != nil }.prefix(2)
            .flatMap { [$0.flags.last!, $0.defaultValue!] }
        return "args: [] for defaults" + (items.isEmpty ? "" : ", or like [" + items.map { "\"\($0)\"" }.joined(separator: ", ") + "]")
    }

    /// One-line option summary, e.g. "options: [path] --top N --depth N".
    public static func describe(_ params: [Param]) -> String {
        guard !params.isEmpty else { return "no options" }
        return "options: " + params.map { p in
            p.flags.isEmpty ? "[\(p.metavar ?? p.key)]" : (p.flags.last! + (p.kind == .flag ? "" : " " + (p.metavar ?? p.key.uppercased())))
        }.joined(separator: " ")
    }
}
