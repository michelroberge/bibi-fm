import BibiCore
import Foundation

/// The only actions storage.optimize can recommend, plus the rules that downgrade or reject what the model picks.
/// The model never writes commands: it picks an action_type and this decides what is allowed for the path.
public enum Catalog {
    public static let actionTypes = ["trash", "empty_cache_dir", "tool_cleanup", "empty_trash", "review", "none"]

    /// Trashing something no rule knows to be regenerable is never rated fully safe, whatever the model says.
    public static let unknownTrashMaxSafety = 6

    public struct Verdict: Codable, Sendable {
        public var verdict: String
        public var action_type: String
        public var safety: Int
        public var confidence: Int
        public var reason: String
        public init(verdict: String, action_type: String, safety: Int, confidence: Int, reason: String) {
            self.verdict = verdict; self.action_type = action_type; self.safety = safety
            self.confidence = confidence; self.reason = reason
        }
    }

    static func toolFor(_ path: String, _ policy: SafetyPolicy) -> String? {
        guard let key = policy.knowledge(path).tool, Tools.available(key) else { return nil }
        return key
    }

    static func missingToolNote(_ path: String, _ policy: SafetyPolicy) -> String? {
        if policy.knowledge(path).tool == "simctl" && !Tools.available("simctl") {
            return "Xcode isn't installed, so simctl can't prune it; if you no longer use iOS simulators, trash this folder."
        }
        return nil
    }

    /// Turns a model verdict into a safe action, downgrading or rejecting when rules say so.
    public static func buildAction(_ node: Node, _ v: Verdict, root: String, policy: SafetyPolicy) -> BoundAction? {
        let path = node.path
        guard path != root, Paths.isWithin(path, root) else { return nil }
        var kind = v.action_type
        if v.verdict == "skip" || kind == "none" { return nil }
        var safety = max(0, min(10, v.safety))
        let confidence = max(0, min(10, v.confidence))
        var reason = v.reason.trimmingCharacters(in: .whitespaces).isEmpty ? "suggested by model" : v.reason
        let regen = policy.isRegenerable(path)

        if kind == "tool_cleanup" && toolFor(path, policy) == nil {
            kind = regen ? "empty_cache_dir" : "review"
            if let note = missingToolNote(path, policy) { reason = note }
        }
        if kind == "empty_trash" && path != policy.trash { kind = "review" }
        if kind == "trash" && node.isDir && regen { kind = "empty_cache_dir" }
        if kind == "empty_cache_dir" && (!node.isDir || !regen) { kind = "trash" }
        if ["trash", "empty_cache_dir"].contains(kind) && (policy.isProtected(path) || (node.isDir && Paths.exists(path + "/.git"))) {
            kind = "review"
        }
        if kind == "trash" && Paths.isWithin(path, policy.home + "/Library") && !regen { kind = "review" }
        if kind == "trash" && path == policy.trash { kind = "empty_trash" }
        if kind == "trash" && !regen { safety = min(safety, unknownTrashMaxSafety) }

        let s = Paths.short(path)
        switch kind {
        case "trash":
            return BoundAction(ActionCall("trash_path", ["path": path]), title: "Move \(s) to Trash", kind: "trash", target: path,
                               bytes: node.size, safety: safety, confidence: confidence, reason: reason,
                               command: "mv \(s) ~/.Trash/", reversible: true)
        case "empty_cache_dir":
            return clearAction(path, bytes: node.size, safety: safety, confidence: confidence, reason: reason)
        case "empty_trash":
            return BoundAction(ActionCall("empty_trash"), title: "Empty the Trash", kind: "empty_trash", target: path,
                               bytes: node.size, safety: safety, confidence: confidence, reason: reason, command: "rm -rf ~/.Trash/*")
        case "tool_cleanup":
            let tool = toolFor(path, policy)!
            let argv = Tools.commands[tool]!
            return BoundAction(ActionCall("tool_cleanup", ["tool": tool]), title: "Run \(argv[0]) cleanup (\(s))", kind: "tool_cleanup",
                               target: path, bytes: node.size, safety: safety, confidence: confidence, reason: reason,
                               command: Shell.join(argv))
        default:
            return BoundAction(ActionCall("reveal", ["path": path]), title: "Review \(s)", kind: "review", target: path,
                               bytes: node.size, safety: min(safety, 10), confidence: confidence, reason: reason,
                               command: "open -R \(s)   (manual review in Finder)", weight: 0.4)
        }
    }

    static func clearAction(_ path: String, bytes: Int, safety: Int, confidence: Int, reason: String) -> BoundAction {
        let s = Paths.short(path)
        return BoundAction(ActionCall("clear_regenerable_dir", ["path": path]), title: "Clear \(s)", kind: "empty_cache_dir",
                           target: path, bytes: bytes, safety: safety, confidence: confidence, reason: reason, command: "rm -rf \(s)/*")
    }

    /// One "clear parent" action replacing several actions inside a regenerable parent.
    public static func consolidatedAction(_ node: Node, _ actions: [BoundAction], safety: Int, reason: String,
                                          policy: SafetyPolicy) -> BoundAction? {
        guard node.isDir, policy.isRegenerable(node.path), !policy.isProtected(node.path), !actions.isEmpty else { return nil }
        let confidence = Int((Double(actions.map(\.confidence).reduce(0, +)) / Double(actions.count)).rounded())
        return clearAction(node.path, bytes: node.size, safety: safety, confidence: confidence, reason: reason)
    }
}
