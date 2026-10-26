import BibiCore
@testable import BibiSkills
import Foundation
import Testing

/// A skill that recommends trashing one file, so harness behavior can be tested without real scans.
struct FakeSkill: Skill {
    let name = "test.fake"
    let help = "fake"
    let file: String
    var facts: [String: JSONValue] = [:]
    var params: [Param] { [.option("label", "--label", help: "anything")] }

    func run(_ args: Args, _ ctx: SkillContext) async throws -> SkillResult {
        let ev = Evidence()
        let o = ev.observe("stat", "\(file) exists")
        ev.find("test", "Old file", severity: .low, cites: [o], confidence: 60, explanation: "rule says so",
                actions: [BoundAction(ActionCall("trash_path", ["path": file]), title: "Trash it", kind: "trash", target: file,
                                      safety: 8, confidence: 8, reason: "old", command: "mv", reversible: true)])
        return SkillResult(summary: "done", observations: ev.allObservations, findings: ev.allFindings, facts: facts)
    }
}

/// An admin action that records the argv instead of running it.
struct FakeAdminSpec: ActionSpec {
    let id = "test_admin"
    let summary = "admin thing"
    var privilege: Privilege { .admin }
    var reversible: Bool { true }
    func validate(_ p: Params, _ env: ActionEnv) throws {}
    func plan(_ p: Params, _ env: ActionEnv) throws -> [String] { ["sudo thing on"] }
    func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        _ = try await env.admin.run(["/usr/sbin/thing", "on"])
        return Outcome("thing on", undo: ActionCall("test_admin_undo"))
    }
}

struct FakeAdminUndo: ActionSpec {
    let id = "test_admin_undo"
    let summary = "undo"
    var privilege: Privilege { .admin }
    var selectable: Bool { false }
    func validate(_ p: Params, _ env: ActionEnv) throws {}
    func plan(_ p: Params, _ env: ActionEnv) throws -> [String] { ["sudo thing off"] }
    func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        _ = try await env.admin.run(["/usr/sbin/thing", "off"])
        return Outcome("thing off")
    }
}

@Suite struct RegistryTests {
    let registry = ActionRegistry(Builtins.all + [FakeAdminSpec(), FakeAdminUndo()])
    let admin = RecordingAdminRunner()
    var env: ActionEnv { ActionEnv(policy: testPolicy(), admin: admin) }

    @Test func rejectsUnknownAndProtected() async {
        await #expect(throws: ActionError.self) { try await registry.execute(ActionCall("rm_rf", ["path": "/"]), env) }
        await #expect(throws: ActionError.self) {
            try await registry.execute(ActionCall("trash_path", ["path": Paths.home + "/Documents"]), ActionEnv(admin: admin))
        }
        await #expect(throws: ActionError.self) { try await registry.execute(ActionCall("trash_path", ["path": "relative/x"]), env) }
        await #expect(throws: ActionError.self) { try await registry.execute(ActionCall("tool_cleanup", ["tool": "rm"]), env) }
        await #expect(throws: ActionError.self) {
            try await registry.execute(ActionCall("clear_regenerable_dir", ["path": Paths.home + "/dev"]), ActionEnv(admin: admin))
        }
        // Undo-only specs can't be selected directly.
        await #expect(throws: ActionError.self) { try await registry.execute(ActionCall("restore_path", ["from": "/a", "to": "/b"]), env) }
    }

    @Test func gitReposNeverTrashed() async throws {
        let tmp = tempDir()
        try FileManager.default.createDirectory(atPath: tmp + "/repo/.git", withIntermediateDirectories: true)
        await #expect(throws: ActionError.self) { try await registry.execute(ActionCall("trash_path", ["path": tmp + "/repo"]), env) }
    }

    @Test func previewHasNoSideEffects() throws {
        let tmp = tempDir()
        write(tmp + "/f.bin", mb: 1)
        let p = registry.preview(ActionCall("trash_path", ["path": tmp + "/f.bin"]), env)
        #expect(p.error == nil)
        #expect(p.reversible)
        #expect(Paths.exists(tmp + "/f.bin"))
        #expect(registry.preview(ActionCall("trash_path", ["path": tmp + "/missing"]), env).error != nil)
    }

    @Test func adminNeedsConfirmation() async throws {
        await #expect(throws: ActionError.self) { try await registry.execute(ActionCall("test_admin"), env) }
        #expect(admin.calls.isEmpty)
        _ = try await registry.execute(ActionCall("test_admin"), env, adminConfirmed: true)
        #expect(admin.calls == [["/usr/sbin/thing", "on"]])
    }

    @Test func diagnosticsFillPlaceholdersSafely() {
        let d = Diagnostics.get("sample_process")!
        #expect(d.command(subject: ["pid": "123"]) == ["sample", "123", "3"])
        #expect(d.command(subject: ["pid": "1; rm -rf ~"]) == nil)
        #expect(d.command(subject: [:]) == nil)
        #expect(registry.preview(RunDiagnostic.call(d, subject: ["pid": "42"]), env).error == nil)
        #expect(registry.preview(ActionCall("run_diagnostic", ["diagnostic": "spindump"]), env).error != nil)  // admin one
    }

    @Test func osascriptQuoting() {
        let s = OsascriptRunner.script(["/usr/libexec/ApplicationFirewall/socketfilterfw", "--setglobalstate", "on"])
        #expect(s.hasPrefix("do shell script \"/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on\" with administrator privileges"))
        let evil = OsascriptRunner.script(["echo", "a\"b'c"])
        #expect(evil.contains("echo 'a\\\"b'\\\\''c'"))
    }
}

@Suite struct HarnessFlowTests {
    let tmp = tempDir()

    func harness(_ skill: any Skill) -> Harness {
        Harness(skills: [skill], store: RunStore(root: tmp + "/runs"), policy: testPolicy()) { FakeModel() }
    }

    @Test func runExecuteUndo() async throws {
        let file = tmp + "/old.bin"
        write(file, mb: 1)
        let h = harness(FakeSkill(file: file))
        let (run, result) = try await h.run(h.skill(named: "test.fake")!, argv: ["--label", "x"], reporter: SilentReporter())
        #expect(result.actions.count == 1)
        #expect(result.actions[0].id == "a1")
        #expect(result.findings[0].uncertainty == .medium)
        #expect(h.store.find(run.id)?.report()?.summary == "done")

        let env = h.env(admin: RecordingAdminRunner(), reporter: SilentReporter())
        let dry = await h.execute(result.actions, run: run, env: env, adminConfirmed: false, dryRun: true, frontend: "test")
        #expect(dry[0].message.hasPrefix("[dry-run]"))
        #expect(Paths.exists(file))

        let done = await h.execute(result.actions, run: run, env: env, adminConfirmed: false, dryRun: false, frontend: "test")
        #expect(done[0].ok, "\(done[0].message)")
        #expect(!Paths.exists(file))
        #expect(run.undoable.count == 1)

        let undone = await h.undo(run, env: env, adminConfirmed: false, frontend: "test")
        #expect(undone[0].ok, "\(undone[0].message)")
        #expect(Paths.exists(file))
        #expect(run.undoable.isEmpty)
        let events = run.journalEntries.map(\.event)
        #expect(events == [.selected, .dryRun, .selected, .executed, .undone])
    }

    @Test func baselineDiff() async throws {
        let store = RunStore(root: tmp + "/runs2")
        func runWith(_ facts: [String: JSONValue]) async throws -> SkillResult {
            let h = Harness(skills: [FakeSkill(file: "/nonexistent", facts: facts)], store: store, policy: testPolicy()) { FakeModel() }
            return try await h.run(h.skill(named: "test.fake")!, argv: [], reporter: SilentReporter()).1
        }
        let first = try await runWith(["listeners": .strings(["sshd:22"]), "free": .number(100)])
        #expect(first.diff == nil)
        let second = try await runWith(["listeners": .strings(["sshd:22", "node:3000"]), "free": .number(101)])
        #expect(second.diff?.changes == [FactChange(key: "listeners", kind: .added, item: "node:3000")])
    }
}

@Suite struct BaselineTests {
    @Test func genericDiff() {
        let old: [String: JSONValue] = ["apps": .object(["Slack": .string("4.1"), "Zoom": .string("6.0")]),
                                        "sizes": .numbers(["~/a": 1_000_000_000, "~/b": 500]), "state": .string("on")]
        let new: [String: JSONValue] = ["apps": .object(["Slack": .string("4.2"), "Arc": .string("1.0")]),
                                        "sizes": .numbers(["~/a": 1_050_000_000, "~/b": 5000]), "state": .string("off")]
        let ch = Baseline.diff(old: old, new: new, spec: FactsSpec(["sizes": FactsSpec.Threshold(relative: 0.2, absolute: 1000)]))
        #expect(ch.contains(FactChange(key: "apps", kind: .added, item: "Arc", to: .string("1.0"))))
        #expect(ch.contains(FactChange(key: "apps", kind: .removed, item: "Zoom", from: .string("6.0"))))
        #expect(ch.contains(FactChange(key: "apps", kind: .changed, item: "Slack", from: .string("4.1"), to: .string("4.2"))))
        #expect(ch.contains { $0.key == "sizes" && $0.item == "~/b" })
        #expect(!ch.contains { $0.key == "sizes" && $0.item == "~/a" })  // 5% growth is noise
        #expect(ch.contains { $0.key == "state" && $0.kind == .changed })
    }

    @Test func runAge() {
        #expect(RunStore.age("7d") == 604_800.0)
        #expect(RunStore.age("12h") == 43_200.0)
        #expect(RunStore.age("abc") == nil)
    }
}

@Suite struct ExplainerTests {
    func finding() -> (Finding, [Observation]) {
        let ev = Evidence()
        let a = ev.observe("top", "chrome 180% CPU")
        let b = ev.observe("pmset -g therm", "CPU speed limit 70")
        ev.find("cpu", "Chrome uses a lot of CPU", severity: .medium, cites: [a, b], confidence: 60, explanation: "rule")
        return (ev.allFindings[0], ev.allObservations)
    }

    @Test func dropsUnknownCitationsAndBoundsConfidence() async {
        let (f, obs) = finding()
        let model = FakeModel(other: .object(["explanation": .string("Chrome is hot."), "cites": .strings(["o1", "o99"]),
                                              "confidence": .number(99), "diagnostics": .strings(["top_cpu", "made_up"])]))
        let out = await Explainer(model: model, reporter: SilentReporter()).explain(f, observations: obs)
        #expect(out.explanation == "Chrome is hot.")
        #expect(out.confidence == 75)  // rule 60 + at most 15
        #expect(out.diagnostics == ["top_cpu"])
        #expect(out.explainedBy == "model")
    }

    @Test func ungroundedCannotRaiseConfidence() async {
        let (f, obs) = finding()
        let model = FakeModel(other: .object(["explanation": .string("x"), "cites": .strings(["o42"]), "confidence": .number(95),
                                              "diagnostics": .array([])]))
        let out = await Explainer(model: model, reporter: SilentReporter()).explain(f, observations: obs)
        #expect(out.confidence == 60)
    }

    @Test func modelFailureKeepsRule() async {
        let (f, obs) = finding()
        let out = await Explainer(model: FakeModel(), reporter: SilentReporter()).explain(f, observations: obs)
        #expect(out.explanation == "rule")
        #expect(out.explainedBy == "rule")
    }

    @Test func correlationNeedsRealCitations() async {
        let ev = Evidence()
        let a = ev.observe("top", "kernel_task 300% CPU"), b = ev.observe("pmset", "thermal warning")
        ev.find("cpu", "High CPU", severity: .medium, cites: [a], confidence: 70, explanation: "x")
        ev.find("thermal", "Thermal pressure", severity: .medium, cites: [b], confidence: 80, explanation: "y")
        let good = JSONValue.object(["title": .string("Overheating"), "explanation": .string("linked"), "cites": .strings(["F1", "F2"]),
                                     "confidence": .number(90), "diagnostics": .strings(["powermetrics"])])
        let bad = JSONValue.object(["title": .string("Made up"), "explanation": .string("?"), "cites": .strings(["F9"]),
                                    "confidence": .number(90), "diagnostics": .array([])])
        let model = FakeModel(other: .object(["hypotheses": .array([good, bad])]))
        let hs = await Explainer(model: model, reporter: SilentReporter()).correlate(ev.allFindings, observations: ev.allObservations)
        #expect(hs.count == 1)
        #expect(hs[0].findingIDs == ["F1", "F2"])
        #expect(hs[0].confidence == 70)  // never above the weakest finding
    }
}

@Suite struct ExplainTextTests {
    @Test func stripsInlineIDs() {
        #expect(Explainer.stripIDs("Memory is low (o2). Teams uses 1 GB (o5, o6) and swap grows (F1, F2).") ==
                "Memory is low. Teams uses 1 GB and swap grows.")
        #expect(Explainer.stripIDs("Nothing to strip (see logs).") == "Nothing to strip (see logs).")
    }
}
