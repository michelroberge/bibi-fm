import Foundation

/// One request and what chat should make of it. `expect` are step signatures the proposal must contain
/// (`command:<program>`, `skill:<name>`, `action:<id>`, `app:<App>`); empty means a plain answer with no steps.
/// Only read-only expectations, so the eval can run on the developer's own Mac.
struct EvalCase {
    var request: String
    var expect: [String]
    /// The reply (or, with look, the final answer) should mention one of these.
    var answerHas: [String] = []
    /// Lets bibi run read-only steps and continue until it can answer (the "Let bibi look" toggle).
    var look = false
    /// Works out commands when no tool fits (the "Work it out" toggle).
    var explore = false
    var tags: [String] = []

    init(_ request: String, _ expect: [String], answerHas: [String] = [], look: Bool = false, explore: Bool = false, tags: [String] = []) {
        self.request = request; self.expect = expect; self.answerHas = answerHas; self.look = look; self.explore = explore; self.tags = tags
    }
}

enum EvalCases {
    static let all: [EvalCase] = [
        // Quick facts: one read-only command (the seeds cover most of these).
        EvalCase("how much free disk space do I have?", ["command:df"], tags: ["seed"]),
        EvalCase("what macOS version am I on?", ["command:sw_vers"], tags: ["seed"]),
        EvalCase("is my firewall on?", ["command:socketfilterfw"], tags: ["seed"]),
        EvalCase("is FileVault turned on?", ["command:fdesetup"], tags: ["seed"]),
        EvalCase("which processes use the most memory?", ["command:ps"], tags: ["seed"]),
        EvalCase("what is eating my CPU right now?", ["command:ps"], tags: ["reworded"]),
        EvalCase("how big is my Downloads folder?", ["command:du"], tags: ["seed"]),
        EvalCase("what's my IP address?", ["command:ipconfig"], tags: ["seed"]),
        EvalCase("how is my battery doing?", ["command:system_profiler"], tags: ["reworded"]),
        EvalCase("when did I last restart this Mac?", ["command:uptime"], tags: ["reworded"]),
        EvalCase("are any Homebrew packages outdated?", ["command:brew"], tags: ["seed"]),
        EvalCase("combien d'espace disque libre me reste-t-il ?", ["command:df"], tags: ["french"]),
        EvalCase("quelle version de macOS j'ai ?", ["command:sw_vers"], tags: ["french"]),
        // Skills for thorough work.
        EvalCase("my Mac is slow, check why", ["skill:sys.health"], tags: ["skill"]),
        EvalCase("what happened on this Mac in the last 24 hours?", ["skill:sys.health"], tags: ["skill"]),
        EvalCase("free up disk space", ["skill:storage.optimize"], tags: ["skill"]),
        EvalCase("audit the security of this Mac", ["skill:sec.audit"], tags: ["skill"]),
        // Registry actions.
        EvalCase("open the privacy settings", ["action:open_settings_pane"], tags: ["action"]),
        EvalCase("launch Safari", ["action:open_app"], tags: ["action"]),
        EvalCase("show me ~/Documents in Finder", ["action:reveal"], tags: ["action"]),
        // No steps: general knowledge, or a question back.
        EvalCase("what does the kernel_task process do?", [], tags: ["answer"]),
        EvalCase("hello, who are you?", [], tags: ["answer"]),
        // Multi-step: with look, bibi runs read-only steps and answers from what it found.
        EvalCase("which folder under ~ takes the most space?", ["command:du"], answerHas: ["G", "M"], look: true, tags: ["multi"]),
        EvalCase("is anything listening on port 8080, and which program is it?", ["command:lsof"], look: true, tags: ["multi"]),
        EvalCase("how many files are in my Downloads folder and how big is it?", ["command:du"], answerHas: ["files", "fichiers"], look: true, tags: ["multi"]),
        EvalCase("which process uses the most memory, and how much?", ["command:ps"], answerHas: ["%", "M", "G"], look: true, tags: ["multi"]),
        EvalCase("do I have Node installed, and which version?", ["command:node"], look: true, tags: ["multi"]),
    ]
}
