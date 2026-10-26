import BibiCore
@testable import BibiSkills
import Foundation
import Testing

@Suite struct HealthParseTests {
    @Test func topUsesLastSample() {
        let t = HealthParse.top(fixture("top.txt"))
        #expect(t.load == [14.2, 9.74, 6.91])
        #expect(t.cpuIdle == 22.85)
        #expect(t.memCompressor == 5473 << 20)
        #expect(t.swapouts == 58216)
        #expect(t.processes.count == 4)
        #expect(t.processes[0] == HealthParse.TopProcess(pid: 80894, command: "Comet Helper (Re", cpu: 144.3, mem: 536 << 20, user: "testuser"))
        #expect(t.processes[3].mem == 2 << 30)
    }

    @Test func swapAndIostat() {
        let s = HealthParse.swap("total = 2048.00M  used = 805.62M  free = 1242.38M  (encrypted)")
        #expect(s.total == 2048 << 20)
        #expect(abs(Double(s.used) - 805.62 * 1048576) < 2)
        let io = HealthParse.iostat(fixture("iostat.txt"))
        #expect(io["disk0"]?.mbs == 205)
        #expect(io["disk4"]?.tps == 0)
    }

    @Test func batteryAndThermal() {
        let b = HealthParse.battery(pmset: fixture("pmset-batt.txt"), profiler: fixture("power.json"))
        #expect(b?.percent == 64)
        #expect(b?.onAC == false)
        #expect(b?.cycles == 1043)
        #expect(b?.condition == "Service Recommended")
        #expect(b?.maxCapacity == 76)
        #expect(HealthParse.battery(pmset: "Now drawing from 'AC Power'\n", profiler: "") == nil)  // desktop Mac
        #expect(HealthParse.thermal(fixture("therm.txt")).speedLimit == 70)
        #expect(HealthParse.thermal("Note: No thermal warning level has been recorded").warnings.isEmpty)
    }

    @Test func crashReports() throws {
        let dir = tempDir()
        for name in ["Slack-2026-10-25-101112.ips", "Slack-2026-10-25-121112.ips", "JetsamEvent-2026-10-25-101112.ips",
                     "Analytics-2026-10-25-101112.ips", "Xcode_2026-10-24-101112.hang", "notes.txt"] {
            FileManager.default.createFile(atPath: dir + "/" + name, contents: Data("{\"bug_type\":\"309\"}\n{}".utf8))
        }
        let crashes = HealthParse.crashes(in: [dir], since: Date().addingTimeInterval(-3600))
        #expect(crashes.filter { $0.process == "Slack" && $0.kind == "crash" }.count == 2)
        #expect(crashes.contains { $0.kind == "jetsam" })
        #expect(crashes.contains { $0.process == "Xcode" && $0.kind == "hang" })
        #expect(!crashes.contains { $0.process.hasPrefix("Analytics") })
        #expect(crashes.count == 4)
    }

    @Test func logCounts() {
        #expect(HealthParse.logCounts(fixture("faults.ndjson")) == ["accountsd": 2, "geod": 1])
    }

    @Test func launchItems() {
        let item = LaunchItems.parse("/Users/x/Library/LaunchAgents/com.example.agent.plist", scope: .user, plist: [
            "Label": "com.example.agent", "ProgramArguments": ["/Applications/Gone.app/Contents/MacOS/agent", "--daemon"],
            "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false],
        ])
        #expect(item.program == "/Applications/Gone.app/Contents/MacOS/agent")
        #expect(item.keepAlive)
        #expect(!item.programExists)
        let list = LaunchItems.parseList("PID\tStatus\tLabel\n-\t78\tcom.example.agent\n512\t0\tcom.example.other\n")
        #expect(list["com.example.agent"]?.pid == nil)
        #expect(list["com.example.agent"]?.status == 78)
        #expect(list["com.example.other"]?.pid == 512)
    }

    @Test func quitProcessGuards() {
        let env = ActionEnv(policy: testPolicy(), admin: RecordingAdminRunner())
        let q = QuitProcess()
        #expect(throws: ActionError.self) { try q.validate(["pid": "1", "name": "launchd"], env) }
        #expect(throws: ActionError.self) { try q.validate(["pid": String(getpid()), "name": "SomethingElse"], env) }
        #expect(throws: ActionError.self) { try q.validate(["pid": "999999", "name": "ghost"], env) }
    }
}

@Suite struct DevCleanupTests {
    @Test func worktreePorcelain() {
        let w = Worktrees.parse(fixture("worktrees.txt"))
        #expect(w.count == 3)
        #expect(w[0].main)
        #expect(w[1].branch == "feature/login")
        #expect(w[2].prunable != nil)
    }

    @Test func dockerParsing() {
        let images = Docker.parseImages(fixture("docker-images.txt"))
        #expect(images.count == 3)
        #expect(images[0].bytes == 1_100_000_000)
        #expect(images[2].dangling)
        let used = Docker.parseContainers(fixture("docker-ps.txt"))
        #expect(Docker.isUsed(images[1], by: used))
        #expect(!Docker.isUsed(images[0], by: used))
        let df = Docker.parseDF(fixture("docker-df.txt"))
        #expect(df.buildCache == 1_500_000_000)
        #expect(df.volumes.filter { $0.links == 0 }.map(\.name) == ["old_cache"])
        #expect(Docker.bytes("12.3kB") == 12300)
    }

    @Test func artifactsNeedManifests() throws {
        let dir = tempDir(), repo = dir + "/proj"
        try FileManager.default.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)
        for d in ["node_modules/x", "build/out", "web/node_modules/y", "docs/build/z", "target/debug"] {
            try FileManager.default.createDirectory(atPath: repo + "/" + d, withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: repo + "/package.json", contents: Data("{}".utf8))
        FileManager.default.createFile(atPath: repo + "/package-lock.json", contents: Data("{}".utf8))
        FileManager.default.createFile(atPath: repo + "/web/package.json", contents: Data("{}".utf8))
        let found = Projects.artifacts(in: repo)
        let names = Set(found.map { String($0.path.dropFirst(repo.count + 1)) })
        #expect(names == ["node_modules", "build", "web/node_modules"])  // docs/build has no manifest; target has no Cargo.toml
        #expect(found.first { $0.path.hasSuffix("/proj/node_modules") }?.lock == "package-lock.json")
        #expect(found.first { $0.path.hasSuffix("web/node_modules") }?.lock == nil)

        let env = ActionEnv(policy: testPolicy(), admin: RecordingAdminRunner())
        let spec = DeleteBuildArtifact()
        #expect(throws: Never.self) { try spec.validate(["path": repo + "/node_modules"], env) }
        #expect(throws: ActionError.self) { try spec.validate(["path": repo + "/docs/build"], env) }
        #expect(throws: ActionError.self) { try spec.validate(["path": repo + "/target"], env) }
        #expect(Projects.discover([dir], maxDepth: 3) == [repo])
    }

    @Test func pinsProtectSDKs() {
        var pins = Pins()
        PinScanner.parseToolVersions("nodejs 20.11.1\npython 3.11\n# comment\n", from: ".tool-versions", into: &pins)
        pins.add("node", "v18", from: ".nvmrc")
        pins.add("node", "lts/*", from: ".nvmrc")  // ignored
        #expect(pins.pins("node", "20.11.1"))
        #expect(pins.pins("node", "v18.19.0"))
        #expect(pins.pins("python", "3.11.9"))
        #expect(!pins.pins("python", "3.1"))
        #expect(!pins.pins("python", "3.12.1"))
        let installs = [SDKInstall(manager: "pyenv", tool: "python", version: "3.11.9", path: "/a", removable: true),
                        SDKInstall(manager: "pyenv", tool: "python", version: "3.9.18", path: "/b", removable: true),
                        SDKInstall(manager: "nvm", tool: "node", version: "16.0.0", path: "/c", removable: true)]
        // 3.11.9 is pinned; node 16 is the only nvm version, so it stays.
        #expect(SDKs.unused(installs, pins: pins).map(\.version) == ["3.9.18"])
    }
}
