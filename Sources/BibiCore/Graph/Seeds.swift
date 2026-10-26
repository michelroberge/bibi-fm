import Foundation

/// Starter examples for chat: common requests and steps that answer them. They are ordinary `intent` nodes
/// (marked `seed`), retrieved like the requests bibi learns from, so the small on-device model sees a concrete
/// example of the right command. They never count toward learning a skill.
public enum Seeds {
    static let examples: [(String, [PlannedStep])] = [
        ("how much free disk space do I have", [.init(tool: "command", args: ["df", "-h", "/"])]),
        ("what macOS version am I on", [.init(tool: "command", args: ["sw_vers"])]),
        ("is the firewall on", [.init(tool: "command", args: ["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate"])]),
        ("is FileVault disk encryption on", [.init(tool: "command", args: ["fdesetup", "status"])]),
        ("which processes use the most memory", [.init(tool: "command", args: ["ps", "-Ao", "pid,%mem,rss,comm", "-m"])]),
        ("which processes use the most CPU", [.init(tool: "command", args: ["ps", "-Ao", "pid,%cpu,comm", "-r"])]),
        ("how big is my Downloads folder", [.init(tool: "command", args: ["du", "-sh", "~/Downloads"])]),
        ("find large files in Downloads", [.init(tool: "command", args: ["find", "~/Downloads", "-size", "+500M"])]),
        ("what is my IP address", [.init(tool: "command", args: ["ipconfig", "getifaddr", "en0"])]),
        ("how is my battery health", [.init(tool: "command", args: ["system_profiler", "SPPowerDataType"])]),
        ("how long since the last restart", [.init(tool: "command", args: ["uptime"])]),
        ("which Homebrew packages are outdated", [.init(tool: "command", args: ["brew", "outdated"])]),
        ("open the privacy settings", [.init(tool: "action:open_settings_pane", args: ["pane=privacy"])]),
        ("clean the npm cache", [.init(tool: "action:tool_cleanup", args: ["tool=npm"])]),
        ("delete ~/Downloads/old.zip", [.init(tool: "action:trash_path", args: ["path=~/Downloads/old.zip"])]),
        ("show me ~/Documents/report.pdf in Finder", [.init(tool: "action:reveal", args: ["path=~/Documents/report.pdf"])]),
        ("my Mac is slow, check why", [.init(tool: "skill:sys.health", args: [])]),
        ("free up disk space", [.init(tool: "skill:storage.optimize", args: [])]),
    ]

    public static func sync(_ graph: GraphStore) {
        for (i, (question, steps)) in examples.enumerated() {
            let id = "intent:seed-\(i + 1)"
            let node = GraphNode(id: id, kind: "intent", name: question, text: question,
                                 props: ["question": .string(question), "intent": .string(question), "seed": .bool(true),
                                         "outcome": .string("ok"),
                                         "steps": (try? JSON.decode(JSONValue.self, from: JSON.string(steps))) ?? .array([]),
                                         "signature": .string(steps.map(\.signature).joined(separator: ">"))])
            GraphSync.ensure(graph, node)
        }
    }
}
