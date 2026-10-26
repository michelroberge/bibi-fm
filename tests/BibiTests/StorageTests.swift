import BibiCore
@testable import BibiSkills
import Foundation
import Testing

@Suite struct SelectionTests {
    @Test func grammar() throws {
        #expect(try Selection.parse("1,2,5", count: 5) == [0, 1, 4])
        #expect(try Selection.parse("1-3", count: 5) == [0, 1, 2])
        #expect(try Selection.parse("2 2 1", count: 5) == [1, 0])
        #expect(try Selection.parse("all", count: 3) == [0, 1, 2])
        #expect(try Selection.parse("none", count: 3) == [])
        #expect(try Selection.parse("", count: 3) == [])
    }

    @Test func invalid() {
        #expect(throws: ArgError.self) { try Selection.parse("6", count: 5) }
        #expect(throws: ArgError.self) { try Selection.parse("x", count: 5) }
    }

    @Test func sizes() throws {
        #expect(try parseSize("500M") == 500 * MB)
        #expect(try parseSize("2G") == 2 << 30)
        #expect(throws: ArgError.self) { try parseSize("lots") }
    }

    @Test func args() throws {
        let params = OptimizeStorage().params
        let a = try Args.parse(["~/dev", "-n", "10", "--min-size=1G"], params: params)
        #expect(a.string("path") == "~/dev")
        #expect(a.int("top") == 10)
        #expect(a.size("min_size") == 1 << 30)
        #expect(a.int("depth") == 3)
        #expect(throws: ArgError.self) { try Args.parse(["--nope"], params: params) }
        #expect(throws: ArgError.self) { try Args.parse(["-n", "many"], params: params) }
    }
}

@Suite struct CatalogTests {
    let policy = SafetyPolicy()
    func node(_ path: String, dir: Bool = true) -> Node { Node(path, 10 * MB, isDir: dir) }
    func v(_ json: JSONValue) -> Catalog.Verdict { try! JSON.decoder.decode(Catalog.Verdict.self, from: JSON.encoder.encode(json)) }

    @Test func protectedPathsOnlyReviewed() {
        let home = Paths.home
        for p in [home + "/Documents", home + "/Library/Mail/V10", "/System/Library"] {
            #expect(Catalog.buildAction(node(p), v(act("trash", 10, 10)), root: "/", policy: policy)?.kind == "review", "\(p)")
        }
    }

    @Test func cacheDirAllowed() {
        let a = Catalog.buildAction(node(Paths.home + "/Library/Caches/com.example"), v(act("empty_cache_dir")), root: Paths.home, policy: policy)
        #expect(a?.kind == "empty_cache_dir")
        #expect(a?.call.spec == "clear_regenerable_dir")
    }

    @Test func nonCacheLibraryTrashDowngraded() {
        let a = Catalog.buildAction(node(Paths.home + "/Library/Application Support/SomeApp"), v(act("trash")), root: Paths.home, policy: policy)
        #expect(a?.kind == "review")
    }

    @Test func outsideRootRejected() {
        #expect(Catalog.buildAction(node("/elsewhere/x"), v(act("trash")), root: Paths.home, policy: policy) == nil)
    }

    @Test func appBundlesOnlyReviewed() {
        let a = Catalog.buildAction(node(Paths.home + "/Visual Studio Code.app/Contents/Frameworks"), v(act("empty_cache_dir")),
                                    root: Paths.home, policy: policy)
        #expect(a?.kind == "review")
    }

    @Test func unknownTrashSafetyCapped() {
        let a = Catalog.buildAction(node(Paths.home + "/old-stuff"), v(act("trash", 10, 10)), root: Paths.home, policy: policy)
        #expect(a?.safety == Catalog.unknownTrashMaxSafety)
        #expect(a?.reversible == true)
    }

    @Test func skillsRegistered() {
        let names = AllSkills.list.map(\.name)
        #expect(names.contains("storage.optimize"))
        #expect(names.contains("net.identify"))
    }
}

@Suite struct AnalyzeTests {
    let tmp: String

    init() {
        tmp = tempDir()
        write(tmp + "/Caches/a/blob", mb: 3)
        write(tmp + "/Caches/b/blob", mb: 3)
        write(tmp + "/Caches/c/blob", mb: 3)
        write(tmp + "/work/big.dmg", mb: 4)
        write(tmp + "/work/notes/n.txt", mb: 2)
        write(tmp + "/photos/p.raw", mb: 5)
    }

    func analysis(_ model: FakeModel, policy: SafetyPolicy = testPolicy(), depth: Int = 2, top: Int = 5) async throws -> [BoundAction] {
        let ctx = SkillContext(model: model, reporter: SilentReporter(), policy: policy)
        let tree = try await scan(tmp, depth: depth + 1)
        let cfg = Analyze.Config(root: tmp, depth: depth, minSize: 1 * MB, keep: 2 * top, jobs: 2)
        return Array(await Analyze.analyze(tree, depthLeft: depth - 1, ctx: ctx, cfg: cfg).prefix(top))
    }

    func rel(_ a: BoundAction) -> String { String(a.target.dropFirst(tmp.count + 1)) }

    @Test func recursionAndRanking() async throws {
        let model = FakeModel(["Caches": DESCEND, "a": act("empty_cache_dir"), "b": act("empty_cache_dir"), "c": act("empty_cache_dir"),
                               "work": DESCEND, "big.dmg": act("trash", 9, 9), "photos": act("review")])
        let actions = try await analysis(model)
        let targets = actions.map(rel)
        #expect(targets.contains("work/big.dmg"))
        #expect(targets.contains("Caches/a"))
        #expect(targets.first == "work/big.dmg")  // 4MB at 9/9 beats 3MB at 8/8
        #expect(actions.last?.kind == "review")  // reviews are down-weighted
        #expect(model.prompts.contains { $0.contains("work/big.dmg") })
    }

    @Test func consolidationOnTheWayUp() async throws {
        let model = FakeModel(["Caches": DESCEND, "a": act("empty_cache_dir"), "b": act("empty_cache_dir"), "c": act("empty_cache_dir")],
                              combine: true)
        let actions = try await analysis(model, policy: testPolicy { ["Caches", "a", "b", "c"].contains(Paths.name($0)) })
        #expect(actions.map { Paths.name($0.target) } == ["Caches"])
        #expect(actions[0].bytes >= 9 * MB)
    }

    @Test func topNAndExecution() async throws {
        let policy = testPolicy { Paths.name($0) == "Caches" }
        let model = FakeModel(["work": DESCEND, "big.dmg": act("trash"), "Caches": act("empty_cache_dir")])
        let actions = try await analysis(model, policy: policy, top: 1)
        #expect(actions.count == 1)
        #expect(Paths.name(actions[0].target) == "Caches")
        let registry = ActionRegistry(Builtins.all)
        _ = try await registry.execute(actions[0].call, ActionEnv(policy: policy, admin: RecordingAdminRunner()))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp + "/Caches").isEmpty)
    }
}
