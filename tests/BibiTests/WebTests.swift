import BibiCore
@testable import BibiWeb
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@Suite struct WebTests {
    let tmp = tempDir()

    func app(_ file: String) -> (Application<RouterResponder<BasicRequestContext>>, String) {
        let harness = Harness(skills: [FakeSkill(file: file)], store: RunStore(root: tmp + "/runs"), policy: testPolicy()) { FakeModel() }
        let server = WebServer(harness: harness, token: "secret")
        let router = server.makeRouter(manager: RunManager(harness: harness))
        return (Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0))), "secret")
    }

    static let auth: HTTPFields = [HTTPField.Name("X-Bibi-Token")!: "secret", .contentType: "application/json"]

    func get<T: Decodable>(_ client: any TestClientProtocol, _ uri: String, _ type: T.Type) async throws -> T {
        try await client.execute(uri: uri, method: .get, headers: Self.auth) { r in
            #expect(r.status == .ok, "\(uri): \(String(buffer: r.body))")
            return try JSON.decoder.decode(T.self, from: Data(r.body.readableBytesView))
        }
    }

    func post(_ client: any TestClientProtocol, _ uri: String, _ body: String) async throws -> JSONValue {
        try await client.execute(uri: uri, method: .post, headers: Self.auth, body: ByteBuffer(string: body)) { r in
            #expect(r.status == .ok, "\(uri): \(String(buffer: r.body))")
            return try JSON.decoder.decode(JSONValue.self, from: Data(r.body.readableBytesView))
        }
    }

    @Test func tokenAndOriginEnforced() async throws {
        let (app, _) = app("/nonexistent")
        try await app.test(.live) { client in
            try await client.execute(uri: "/api/skills", method: .get) { #expect($0.status == .unauthorized) }
            try await client.execute(uri: "/api/skills?token=wrong", method: .get) { #expect($0.status == .unauthorized) }
            var evil = Self.auth
            evil[.origin] = "http://evil.example"
            try await client.execute(uri: "/api/skills", method: .get, headers: evil) { #expect($0.status == .forbidden) }
            try await client.execute(uri: "/api/skills", method: .get, headers: Self.auth) { #expect($0.status == .ok) }
            // Static files need no token but get the same host checks and headers.
            try await client.execute(uri: "/", method: .get) { r in
                #expect(r.status == .ok)
                #expect(String(buffer: r.body).contains("<title>bibi</title>"))
                #expect(r.headers[HTTPField.Name("Content-Security-Policy")!] != nil)
            }
        }
    }

    @Test func runPreviewExecuteUndo() async throws {
        let file = tmp + "/old.bin"
        write(file, mb: 1)
        let (app, _) = app(file)
        try await app.test(.live) { client in
            let start = try await post(client, "/api/runs", #"{"skill":"test.fake","argv":["--label","x"]}"#)
            let id = try #require(start["id"]?.string)
            var view = JSONValue.null
            for _ in 0..<50 {
                view = try await get(client, "/api/runs/\(id)", JSONValue.self)
                if view["report"] != nil && view["report"] != .null && view["busy"] == nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(view["report"]?["findings"]?.array?.count == 1)
            #expect(view["actionInfo"]?["a1"]?["reversible"] == .bool(true))

            let preview = try await post(client, "/api/runs/\(id)/preview", #"{"actions":["a1"]}"#)
            #expect(preview["a1"]?["error"] == nil || preview["a1"]?["error"] == .null)
            #expect(Paths.exists(file))

            // Ids the run didn't recommend are rejected.
            try await client.execute(uri: "/api/runs/\(id)/execute", method: .post, headers: Self.auth,
                                     body: ByteBuffer(string: #"{"actions":["a99"]}"#)) { #expect($0.status == .badRequest) }

            let results = try await post(client, "/api/runs/\(id)/execute", #"{"actions":["a1"]}"#)
            #expect(results.array?.first?["ok"] == .bool(true))
            #expect(!Paths.exists(file))

            let history = try await get(client, "/api/history", JSONValue.self)
            #expect(history.array?.first?["undoable"]?.int == 1)

            let undone = try await post(client, "/api/runs/\(id)/undo", "{}")
            #expect(undone.array?.first?["ok"] == .bool(true))
            #expect(Paths.exists(file))
        }
    }

    @Test func hostCheck() {
        #expect(Guard.isLocal("127.0.0.1:8080"))
        #expect(Guard.isLocal("localhost:8080"))
        #expect(!Guard.isLocal("attacker.example:80"))
        #expect(!Guard.isLocal("127.0.0.1.attacker.example"))
    }

    @Test func badArgumentsAre400() async throws {
        let (app, _) = app("/nonexistent")
        try await app.test(.live) { client in
            try await client.execute(uri: "/api/runs", method: .post, headers: Self.auth,
                                     body: ByteBuffer(string: #"{"skill":"test.fake","argv":["--nope"]}"#)) { #expect($0.status == .badRequest) }
            try await client.execute(uri: "/api/runs", method: .post, headers: Self.auth,
                                     body: ByteBuffer(string: #"{"skill":"nope"}"#)) { #expect($0.status == .notFound) }
        }
    }

    @Test func eventsReplayForLateSubscribers() async {
        let hub = EventHub()
        hub.emit("info", "one")
        hub.emit("progress", "p1")
        hub.emit("progress", "p2")  // replaces p1
        hub.emit("done", "finished", phase: "run")
        var seen: [String] = []
        for await e in hub.subscribe(from: 0) {
            seen.append(e.text)
            if e.type == "done" { break }
        }
        #expect(seen == ["one", "p2", "finished"])
    }
}
