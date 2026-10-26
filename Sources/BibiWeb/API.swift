import BibiCore
import Foundation
import Hummingbird

struct SkillInfo: Encodable {
    var name, help, namespace: String
    var aliases: [String]
    var usesWeb, onlineByDefault, adminActions: Bool
    var params: [Param]
}

struct RunView: Encodable {
    var meta: RunMeta
    var report: SkillResult?
    var journal: [JournalEntry]
    var undoable: [String]
    var undoNeedsAdmin: Bool
    var busy: String?
    var actionInfo: [String: ActionInfo]
    var network: [NetworkEntry]
    var modelCalls: Int
}

struct ActionInfo: Encodable {
    var privilege: Privilege
    var reversible: Bool
    var summary: String
}

struct HistoryItem: Encodable {
    var meta: RunMeta
    var undoable: Int
}

struct ExecuteBody: Decodable {
    var actions: [String]
    var confirmAdmin: Bool?
    var dryRun: Bool?
}

struct StartBody: Decodable {
    var skill: String
    var argv: [String]?
    var online: Bool?
    var since: String?
    var verbose: Bool?
}

struct DiagnosticBody: Decodable {
    var finding: String
    var diagnostic: String
    var confirmAdmin: Bool?
}

struct UndoBody: Decodable {
    var actions: [String]?
    var confirmAdmin: Bool?
}

struct API: Sendable {
    let harness: Harness
    let manager: RunManager

    func register(_ api: RouterGroup<BasicRequestContext>) {
        api.get("skills") { _, _ in json(harness.sortedSkills.map(info)) }
        api.get("catalog") { _, _ in
            json(["version": JSONValue.string(Bibi.version),
                  "diagnostics": (try? JSON.decode(JSONValue.self, from: JSON.string(Diagnostics.all))) ?? .null,
                  "actions": .array(harness.registry.all.map {
                      .object(["id": .string($0.id), "summary": .string($0.summary), "privilege": .string($0.privilege.rawValue),
                               "reversible": .bool($0.reversible), "selectable": .bool($0.selectable)])
                  })])
        }
        api.post("runs") { req, _ in
            let b = try await decode(req, StartBody.self)
            guard let skill = harness.skill(named: b.skill) else { throw HTTPError(.notFound, message: "unknown skill \(b.skill)") }
            do {
                let id = try await manager.start(skill, argv: b.argv ?? [], online: b.online, since: b.since, verbose: b.verbose ?? false)
                return json(["id": id])
            } catch let e as ArgError {
                throw HTTPError(.badRequest, message: e.description)
            }
        }
        api.get("runs/:id") { _, ctx in json(try view(run(ctx))) }
        api.get("runs/:id/events") { req, ctx in
            let id = try ctx.parameters.require("id")
            let from = req.uri.queryParameters["from"].flatMap { Int(String($0)) } ?? 0
            return sse(manager.hub(id).subscribe(from: from))
        }
        api.post("runs/:id/preview") { req, ctx in
            let run = try run(ctx)
            let b = try await decode(req, ExecuteBody.self)
            let actions = try bound(run, b.actions)
            let env = harness.env(admin: OsascriptRunner(), reporter: SilentReporter())
            let previews = harness.preview(actions, env: env, run: run)
            return json(Dictionary(uniqueKeysWithValues: zip(actions.map(\.id), previews)))
        }
        api.post("runs/:id/execute") { req, ctx in
            let run = try run(ctx)
            let b = try await decode(req, ExecuteBody.self)
            let actions = try bound(run, b.actions)
            return try await operate(run, phase: "execute") { reporter in
                await harness.execute(actions, run: run, env: harness.env(admin: OsascriptRunner(), reporter: reporter),
                                      adminConfirmed: b.confirmAdmin ?? false, dryRun: b.dryRun ?? false, frontend: "web")
            }
        }
        api.post("runs/:id/diagnostic") { req, ctx in
            let run = try run(ctx)
            let b = try await decode(req, DiagnosticBody.self)
            guard let report = run.report(), let f = report.findings.first(where: { $0.id == b.finding }),
                  let d = Diagnostics.get(b.diagnostic) else { throw HTTPError(.notFound, message: "unknown finding or diagnostic") }
            var a = BoundAction(RunDiagnostic.call(d, subject: f.subject), title: d.title, kind: "diagnostic", target: f.title,
                                safety: 10, confidence: 10, reason: "read-only check",
                                command: (d.admin ? "sudo " : "") + (d.command(subject: f.subject).map(Shell.join) ?? d.template),
                                privilege: d.admin ? .admin : .user)
            a.id = "d-\(d.id)-\(f.id)"
            a.findingID = f.id
            return try await operate(run, phase: "execute") { reporter in
                await harness.execute([a], run: run, env: harness.env(admin: OsascriptRunner(), reporter: reporter),
                                      adminConfirmed: b.confirmAdmin ?? false, dryRun: false, frontend: "web")
            }
        }
        api.post("runs/:id/undo") { req, ctx in
            let run = try run(ctx)
            let b = try await decode(req, UndoBody.self)
            return try await operate(run, phase: "undo") { reporter in
                await harness.undo(run, only: b.actions.map(Set.init), env: harness.env(admin: OsascriptRunner(), reporter: reporter),
                                   adminConfirmed: b.confirmAdmin ?? false, frontend: "web")
            }
        }
        api.get("history") { req, _ in
            let skill = req.uri.queryParameters["skill"].map(String.init)
            return json(harness.store.list(skill: skill?.isEmpty == false ? skill : nil).prefix(200).map {
                HistoryItem(meta: $0.meta, undoable: $0.undoable.count)
            })
        }
        api.get("diff") { req, _ in
            guard let name = req.uri.queryParameters["skill"].map(String.init), let skill = harness.skill(named: name) else {
                throw HTTPError(.badRequest, message: "skill is required")
            }
            let since = req.uri.queryParameters["since"].map(String.init).flatMap { $0.isEmpty ? nil : $0 }
            let runs = harness.store.list(skill: skill.name).filter { $0.meta.finished != nil && $0.meta.error == nil }
            guard let latest = runs.first, let new = latest.report() else { return json(["latest": JSONValue.null]) }
            guard let base = harness.store.baseline(skill: skill.name, since: since, excluding: latest.id), let old = base.report(),
                  skill.comparable(old.facts, new.facts) else {
                return json(DiffView(latest: latest.meta, baseline: nil, changes: []))
            }
            return json(DiffView(latest: latest.meta, baseline: base.meta,
                                 changes: Baseline.diff(old: old.facts, new: new.facts, spec: skill.factsSpec)))
        }
        api.post("chat") { _, _ -> Response in
            throw HTTPError(.notImplemented, message: "chat is planned; it will use this endpoint and the run event stream")
        }
    }

    struct DiffView: Encodable {
        var latest: RunMeta
        var baseline: RunMeta?
        var changes: [FactChange]
    }

    func info(_ s: any Skill) -> SkillInfo {
        SkillInfo(name: s.name, help: s.help, namespace: s.namespace, aliases: s.aliases, usesWeb: s.usesWeb,
                  onlineByDefault: s.onlineByDefault, adminActions: s.actionSpecs.contains { $0.privilege == .admin }, params: s.params)
    }

    func run(_ ctx: BasicRequestContext) throws -> RunRecord {
        let id = try ctx.parameters.require("id")
        guard let r = harness.store.find(id) else { throw HTTPError(.notFound, message: "no run \(id)") }
        return r
    }

    func view(_ run: RunRecord) -> RunView {
        let report = run.report()
        var info: [String: ActionInfo] = [:]
        for a in report?.actions ?? [] {
            if let s = harness.registry.spec(a.call.spec) {
                info[a.id] = ActionInfo(privilege: s.privilege, reversible: s.reversible, summary: s.summary)
            }
        }
        return RunView(meta: run.meta, report: report, journal: run.journalEntries, undoable: run.undoable.compactMap(\.actionID),
                       undoNeedsAdmin: harness.undoNeedsAdmin(run), busy: manager.hub(run.id).busy, actionInfo: info,
                       network: run.networkEntries, modelCalls: run.modelEntries.count)
    }

    /// Only actions the run actually recommended can be executed; ids from the browser are looked up, never trusted.
    func bound(_ run: RunRecord, _ ids: [String]) throws -> [BoundAction] {
        guard let report = run.report() else { throw HTTPError(.conflict, message: "the run has no report yet") }
        return try ids.map { id in
            guard let a = report.action(id) else { throw HTTPError(.badRequest, message: "unknown action \(id)") }
            return a
        }
    }

    /// One operation per run at a time; progress goes to the run's event stream.
    func operate(_ run: RunRecord, phase: String, _ body: (any Reporter) async -> [ExecResult]) async throws -> Response {
        let hub = manager.hub(run.id)
        guard hub.begin(phase) else { throw HTTPError(.conflict, message: "this run is busy (\(hub.busy ?? ""))") }
        let results = await body(WebReporter(hub: hub, phase: phase, verbose: false))
        hub.emit("done", phase, phase: phase)
        return json(results)
    }
}

func json(_ value: some Encodable, status: HTTPResponse.Status = .ok) -> Response {
    let data = (try? JSON.encoder.encode(value)) ?? Data("null".utf8)
    return Response(status: status, headers: [.contentType: "application/json; charset=utf-8"],
                    body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
}

func decode<T: Decodable>(_ req: Request, _ type: T.Type) async throws -> T {
    var req = req
    let buffer = try await req.collectBody(upTo: 1 << 20)
    do {
        return try JSON.decoder.decode(T.self, from: Data(buffer.readableBytesView))
    } catch {
        throw HTTPError(.badRequest, message: "bad request body: \(error)")
    }
}

/// Server-sent events with a keep-alive comment every 15 seconds (so closed tabs are noticed).
func sse(_ events: AsyncStream<WebEvent>) -> Response {
    let body = ResponseBody { writer in
        let (lines, cont) = AsyncStream<String>.makeStream()
        let forward = Task {
            for await e in events { cont.yield("id: \(e.seq)\ndata: \(JSON.string(e))\n\n") }
            cont.finish()
        }
        let beat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                cont.yield(": ping\n\n")
            }
        }
        defer {
            forward.cancel()
            beat.cancel()
        }
        try await writer.write(ByteBuffer(string: ": connected\n\n"))
        for await line in lines { try await writer.write(ByteBuffer(string: line)) }
        try await writer.finish(nil)
    }
    return Response(status: .ok, headers: [.contentType: "text/event-stream", .cacheControl: "no-store"], body: body)
}
