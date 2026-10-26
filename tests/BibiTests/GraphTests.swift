import BibiCore
import Foundation
import Testing

func tempGraph() -> GraphStore { try! GraphStore(path: tempDir() + "/bibi.db") }

@Suite struct GraphStoreTests {
    @Test func nodesEdgesAndWalks() throws {
        let g = tempGraph()
        g.upsert(GraphNode(id: "skill:generic", kind: "skill", name: "generic"))
        g.upsert(GraphNode(id: "skill:storage", kind: "namespace", name: "storage"))
        g.upsert(GraphNode(id: "skill:storage.optimize", kind: "skill", name: "storage.optimize", text: "find what uses disk space"))
        g.link("skill:storage", "skill:generic", "child_of")
        g.link("skill:storage.optimize", "skill:storage", "child_of")

        #expect(g.node("skill:storage.optimize")?.text == "find what uses disk space")
        #expect(g.nodes(kind: "skill").count == 2)
        // Up the tree, two hops.
        #expect(g.neighbors("skill:storage.optimize", kind: "child_of", depth: 2).map(\.id) == ["skill:storage", "skill:generic"])
        // Down the tree.
        #expect(g.neighbors("skill:generic", kind: "child_of", depth: 2, reverse: true).map(\.id).sorted()
                == ["skill:storage", "skill:storage.optimize"])

        g.update("skill:storage.optimize") { $0.status = "disabled" }
        #expect(g.nodes(kind: "skill", status: "active").map(\.id) == ["skill:generic"])

        g.strengthen("a", "b", "matched")
        g.strengthen("a", "b", "matched")
        #expect(g.edges(from: "a", kind: "matched").first?.weight == 2)
    }

    @Test func migrationsAreIdempotent() throws {
        let path = tempDir() + "/bibi.db"
        let g = try GraphStore(path: path)
        g.upsert(GraphNode(id: "x", kind: "fact", name: "disk", text: "home uses 180 GB"))
        let again = try GraphStore(path: path)
        #expect(again.node("x")?.text == "home uses 180 GB")
    }

    @Test func searchIgnoresSyntax() {
        let g = tempGraph()
        g.upsert(GraphNode(id: "f1", kind: "fact", name: "disk", text: "The home folder uses 180 GB"))
        g.upsert(GraphNode(id: "f2", kind: "fact", name: "network", text: "Wi-Fi is on 5 GHz"))
        #expect(g.search("how big is my home folder?", kind: "fact").map(\.id) == ["f1"])
        // FTS operators in user text are just words.
        #expect(g.search("home\" OR NEAR(x) *", kind: "fact").map(\.id) == ["f1"])
        // Re-upserting replaces the search entry.
        g.upsert(GraphNode(id: "f1", kind: "fact", name: "disk", text: "Downloads holds 20 GB"))
        #expect(g.search("home folder", kind: "fact").isEmpty)
    }

    @Test func eventsStatsAndVectors() {
        let g = tempGraph()
        g.record("approved", node: "skill:x")
        g.record("approved", node: "skill:x")
        g.record("skipped", node: "skill:x")
        #expect(g.stats("skill:x") == ["approved": 2, "skipped": 1])
        #expect(abs(g.approvalRate("skill:x") - 3.0 / 5.0) < 1e-9)
        #expect(g.approvalRate("skill:none") == 0.5)

        g.upsert(GraphNode(id: "v", kind: "fact", name: "v", text: "one"))
        g.setVector("v", [1, 0, 0.5])
        #expect(g.vector("v") == [1, 0, 0.5])
        // Changing the text drops the stale embedding.
        g.upsert(GraphNode(id: "v", kind: "fact", name: "v", text: "two"))
        #expect(g.vector("v") == nil)
    }

    @Test func similarity() {
        #expect(Similarity.jaccard("check free disk space", "how much free disk space") > 0.5)
        #expect(Similarity.jaccard("check free disk space", "list running processes") == 0)
        #expect(abs(Similarity.cosine([1, 0], [1, 0]) - 1) < 1e-9)
    }
}

@Suite struct PromptBookTests {
    @Test func defaultsOverridesAndCodeChanges() {
        let g = tempGraph(), book = PromptBook(g)
        #expect(book.text("explain", default: "v1 text") == "v1 text")
        book.revise("explain", text: "tuned", reason: "user edit")
        #expect(book.text("explain", default: "v1 text") == "tuned")
        // A new code default doesn't override a revision...
        #expect(book.text("explain", default: "v2 text") == "tuned")
        // ...but replaces an untouched default.
        #expect(book.text("other", default: "a") == "a")
        #expect(book.text("other", default: "b") == "b")
        #expect(PromptBook().text("explain", default: "plain") == "plain")
    }

    @Test func avoidNotesAndRollback() {
        let g = tempGraph(), book = PromptBook(g)
        let v1 = book.active("skill.generic", default: "").version
        for _ in 0..<8 { g.record("approved", node: v1) }
        for _ in 0..<2 { g.record("skipped", node: v1) }
        let v2 = book.addAvoid("skill.generic", default: "", note: "don't use sudo for reading logs")
        #expect(book.text("skill.generic", default: "").contains("Avoid: don't use sudo for reading logs"))
        #expect(book.evaluate("skill.generic") == nil)  // not enough decisions yet
        for _ in 0..<3 { g.record("approved", node: v2) }
        for _ in 0..<7 { g.record("skipped", node: v2) }
        #expect(book.evaluate("skill.generic") == v1)
        #expect(book.active("skill.generic", default: "").version == v1)
        #expect(g.node(v2)?.status == "rolled-back")
    }

    @Test func avoidNotesAreBounded() {
        let book = PromptBook(tempGraph())
        for i in 0..<8 { book.addAvoid("skill.x", default: "Base guidance", note: "note \(i)") }
        let text = book.text("skill.x", default: "Base guidance")
        #expect(text.hasPrefix("Base guidance"))
        #expect(text.components(separatedBy: "Avoid: ").count - 1 == 5)
        #expect(text.contains("note 7") && !text.contains("note 2"))
    }
}

@Suite struct CommandPolicyTests {
    let policy = testPolicy()
    func classify(_ argv: [String]) -> CommandVerdict { CommandPolicy.classify(argv, policy: policy, exists: { _ in true }) }

    @Test func refusesShells() {
        #expect(classify(["sh", "-c", "rm -rf /"]).refusal != nil)
        #expect(classify(["bash", "script.sh"]).refusal != nil)
        #expect(classify(["ls", "|", "grep", "x"]).refusal != nil)
        #expect(classify(["echo", "$(whoami)"]).refusal != nil)
        #expect(classify(["df -h"]).refusal != nil)
        #expect(classify(["python3", "-c", "import os"]).refusal != nil)
        #expect(classify(["osascript", "-e", "do shell script \"ls\""]).refusal != nil)
        #expect(CommandPolicy.classify(["no-such-program-xyz"], policy: policy).refusal != nil)
    }

    @Test func classes() {
        #expect(classify(["df", "-h"]).cls == .readOnly)
        #expect(classify(["python3", "--version"]).cls == .readOnly)
        #expect(classify(["defaults", "read", "com.apple.dock"]).cls == .readOnly)
        #expect(classify(["defaults", "write", "com.apple.dock", "autohide", "-bool", "true"]).cls == .writes)
        #expect(classify(["brew", "outdated"]).cls == .readOnly)
        #expect(classify(["brew", "upgrade"]).cls == .writes)
        #expect(classify(["git", "branch", "-D", "x"]).cls == .writes)
        #expect(classify(["find", "/tmp", "-name", "x", "-delete"]).cls == .writes)
        #expect(classify(["curl", "https://example.com"]).cls == .network)
        #expect(classify(["curl", "-o", "/tmp/x", "https://example.com"]).cls == .writes)
        #expect(classify(["powermetrics", "-n", "1"]).refusal != nil)
        let admin = classify(["sudo", "-n", "powermetrics", "-n", "1"])
        #expect(admin.cls == .admin && admin.argv == ["powermetrics", "-n", "1"])
    }

    @Test func rmBecomesTrash() {
        let v = classify(["rm", "-rf", "/tmp/a", "~/b"])
        #expect(v.rewrite == [ActionCall("trash_path", ["path": "/tmp/a"]), ActionCall("trash_path", ["path": Paths.home + "/b"])])
        #expect(classify(["rm", "relative"]).refusal != nil)
    }

    @Test func protectedPaths() {
        #expect(classify(["mv", "/System/Library/x", "/tmp"]).refusal != nil)
        #expect(classify(["chmod", "777", Paths.home + "/Documents"]).refusal != nil)
        #expect(classify(["mkdir", "/tmp/new"]).refusal == nil)
    }

    @Test func runCommandRechecks() async throws {
        let env = ActionEnv(policy: policy, admin: RecordingAdminRunner())
        let registry = ActionRegistry(Builtins.all)
        let ok = try await registry.execute(RunCommand.call(["echo", "hello"], admin: false), env)
        #expect(ok.output == "hello")
        // A stored call can't smuggle a shell or a deletion past the policy.
        await #expect(throws: ActionError.self) { try await registry.execute(RunCommand.call(["sh", "-c", "echo"], admin: false), env) }
        await #expect(throws: ActionError.self) { try await registry.execute(RunCommand.call(["rm", "/tmp/x"], admin: false), env) }
        // Admin commands need confirmation and go through the admin runner.
        let admin = RecordingAdminRunner()
        let aenv = ActionEnv(policy: policy, admin: admin)
        await #expect(throws: ActionError.self) { try await registry.execute(RunCommand.call(["ls", "/var/root"], admin: true), aenv) }
        _ = try await registry.execute(RunCommand.call(["ls", "/var/root"], admin: true), aenv, adminConfirmed: true)
        #expect(admin.calls == [["ls", "/var/root"]])
    }
}

@Suite struct MinerTests {
    @Test func generalizesDifferingArguments() throws {
        let runs = ["/Users/a/Downloads", "/Users/a/Desktop", "/tmp"].map { p in
            [PlannedStep(tool: "command", args: ["du", "-sh", p]), PlannedStep(tool: "action:reveal", args: ["path=" + p])]
        }
        let (steps, params) = try #require(SkillMiner.generalize(runs))
        #expect(params == ["path"])
        #expect(steps[0].args == ["du", "-sh", "{path}"])
        #expect(steps[1].args == ["path={path}"])
        // Different programs don't merge.
        #expect(SkillMiner.generalize([[PlannedStep(tool: "command", args: ["df"])], [PlannedStep(tool: "command", args: ["du"])]]) == nil)
    }
}

@Suite struct ContextBuilderTests {
    @Test func dropsLeastImportantFirst() {
        var c = ContextBuilder()
        c.add("Tools", String(repeating: "t", count: 100), priority: 0)
        c.add("Summary", String(repeating: "s", count: 300), priority: 3)
        c.add("Facts", String(repeating: "f", count: 300), priority: 4)
        c.add("Examples", String(repeating: "e", count: 300), priority: 5)
        c.add("User", "hello", priority: 0)
        let (text, dropped) = c.build(budget: 500)
        #expect(dropped == ["Examples", "Facts"])
        #expect(text.contains("Summary") && text.hasSuffix("User:\nhello"))
        let (small, _) = c.build(budget: 150)
        #expect(small.count < 400 && small.contains("hello"))
    }
}

@Suite struct PlannerTests {
    let planner = Planner(registry: ActionRegistry(Builtins.all), env: ActionEnv(policy: testPolicy(), admin: RecordingAdminRunner()),
                          skill: { _ in nil })

    @Test func tidiesSmallModelMistakes() throws {
        // A whole command line in one string, and empty arguments.
        let df = try planner.bind(PlannedStep(tool: "command", args: ["df -h /", ""])).get()
        #expect(df.first?.call == RunCommand.call(["df", "-h", "/"], admin: false))
        // A bare value for an action with one main parameter.
        let tmp = tempDir()
        let reveal = try planner.bind(PlannedStep(tool: "action:reveal", args: [tmp])).get()
        #expect(reveal.first?.call.params["path"] == tmp)
        // Placeholders copied from the option list are dropped with their flag.
        #expect(Planner.tidy(PlannedStep(tool: "skill:x", args: ["--top TOP --depth 3"])).args == ["--depth", "3"])
        // The runner-only specs can't be proposed directly.
        #expect(throws: ActionError.self) { try planner.bind(PlannedStep(tool: "action:run_command", args: ["argv=[\"ls\"]"])).get() }
    }

    @Test func replyGuards() {
        #expect(ChatEngine.claimsResults("You have 12 GB free.", question: "how much space?"))
        #expect(ChatEngine.claimsResults("You are on macOS [version].", question: "which version?"))
        #expect(!ChatEngine.claimsResults("I'll check the top 5 folders.", question: "show the top 5 folders"))
        #expect(ChatEngine.readsAsPlan("I’ll check your firewall."))
        #expect(!ChatEngine.readsAsPlan("The firewall is on."))
        #expect(ChatEngine.grounded("The home folder uses 180 GB", in: "Result: du says the home folder uses 180 GB"))
        #expect(!ChatEngine.grounded("The home folder uses 180 GB", in: "Result: du says the home folder uses 20 GB"))
        #expect(!ChatEngine.grounded("The user asked about disk", in: "The user asked about disk space"))
    }
}
