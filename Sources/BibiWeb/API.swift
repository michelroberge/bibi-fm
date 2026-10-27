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
    /// Form fields the card shows (chat proposals); empty for actions approved as they are.
    var fields: [ActionField] = []
}

struct HistoryItem: Encodable {
    var meta: RunMeta
    var undoable: Int
}

struct HistoryPage: Encodable {
    var items: [HistoryItem]
    var total, offset, limit: Int
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

struct ChatBody: Decodable {
    var conversation: String?
    var message: String
}

struct DecideBody: Decodable {
    var approve: [String]?
    var skip: [String]?
    var reason: String?
    var confirmAdmin: Bool?
    var dryRun: Bool?
}

struct EditBody: Decodable {
    var action: String
    var params: [String: String]
}

struct GuidanceBody: Decodable {
    var text: String
}

struct OverrideBody: Decodable {
    var keywords: String?
    var text: String?
}

struct ExampleBody: Decodable {
    var id: String?
    var text: String?
    var steps: [PlannedStep]?
    var weight: Double?
    var status: String?
    var remove: Bool?
}

struct LinkActionBody: Decodable {
    var action: String
    var linked: Bool
}

struct StepsBody: Decodable {
    var steps: [PlannedStep]
    var params: [String]?
}

struct NodeBody: Decodable {
    var id: String
    var name: String?
    var text: String?
    var status: String?
    var props: [String: JSONValue]?
}

struct EdgeBody: Decodable {
    var src, dst, kind: String
    var weight: Double?
    var remove: Bool?
}

struct ChatView: Encodable {
    var state: ChatState
    var transcript: [ChatMessage]
    var report: SkillResult?
    var actionInfo: [String: ActionInfo]
    var executed: [String]
    var undoable: [String]
    var undoNeedsAdmin: Bool
    var busy: String?
    var candidates: [SkillLibrary.SkillView]
}

struct ChatItem: Encodable {
    var id: String
    var title: String
    var started: Date
    var actions: Int
    var undoable: Int
    var snippet: String?
}

struct API: Sendable {
    let harness: Harness
    let manager: RunManager
    let chat: ChatEngine?

    func register(_ api: RouterGroup<BasicRequestContext>) {
        api.get("skills") { _, _ in json(harness.sortedSkills.map(info)) }
        let hostName = Host.current().localizedName ?? "" // the Computer Name set in System Settings > Sharing
        api.get("catalog") { _, _ in
            json(["version": JSONValue.string(Bibi.version), "hostName": .string(hostName),
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
            let params = req.uri.queryParameters
            let skill = params["skill"].map(String.init)
            let query = params["q"].map(String.init) ?? ""
            let offset = max(0, params["offset"].flatMap { Int($0) } ?? 0)
            let limit = min(100, max(1, params["limit"].flatMap { Int($0) } ?? 25))
            let runs = harness.store.list(skill: skill?.isEmpty == false ? skill : nil).filter { $0.meta.matches(query) }
            // Undo counts read each run's journal, so only the requested page pays for them.
            let page = runs.dropFirst(offset).prefix(limit).map { HistoryItem(meta: $0.meta, undoable: $0.undoable.count) }
            return json(HistoryPage(items: Array(page), total: runs.count, offset: offset, limit: limit))
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
        registerChat(api)
        registerGraph(api)
    }

    func engine() throws -> ChatEngine {
        guard let chat else { throw HTTPError(.serviceUnavailable, message: "chat needs bibi.db, which could not be opened") }
        return chat
    }

    func chatRun(_ ctx: BasicRequestContext) throws -> RunRecord {
        let r = try run(ctx)
        guard r.meta.skill == "chat" else { throw HTTPError(.notFound, message: "\(r.id) is not a chat") }
        return r
    }

    /// Chat: each conversation is a run of the `chat` skill, so its events, journal and undo use the run machinery.
    /// Turns run in the background; the page follows them on the run's event stream.
    func registerChat(_ api: RouterGroup<BasicRequestContext>) {
        api.get("chats") { req, _ in
            let q = req.uri.queryParameters["q"].map(String.init) ?? ""
            return json(try engine().search(q).prefix(200).map { m in
                ChatItem(id: m.run.id, title: m.run.meta.summary ?? "Chat", started: m.run.meta.started,
                         actions: m.run.meta.actions ?? 0, undoable: m.run.undoable.count, snippet: m.snippet)
            })
        }
        api.delete("chat/:id") { _, ctx in
            let chat = try engine()
            let run = try chatRun(ctx)
            guard manager.hub(run.id).busy == nil else { throw HTTPError(.conflict, message: "bibi is still working on this chat") }
            try chat.delete(run)
            return json(["ok": true])
        }
        api.post("chat") { req, _ in
            let chat = try engine()
            let b = try await decode(req, ChatBody.self)
            guard !b.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HTTPError(.badRequest, message: "empty message")
            }
            let run: RunRecord
            if let id = b.conversation, !id.isEmpty {
                guard let r = harness.store.find(id), r.meta.skill == "chat" else { throw HTTPError(.notFound, message: "no chat \(id)") }
                run = r
            } else {
                run = try chat.start()
            }
            let hub = manager.hub(run.id)
            guard hub.begin("chat") else { throw HTTPError(.conflict, message: "bibi is still busy with this chat (\(hub.busy ?? ""))") }
            Task {
                await chat.send(run, b.message) { hub.emit($0, $1, phase: "chat") }
                hub.emit("done", "turn", phase: "chat")
            }
            return json(["id": run.id])
        }
        api.get("chat/:id") { _, ctx in
            let chat = try engine()
            let run = try chatRun(ctx)
            let report = run.report()
            var info: [String: ActionInfo] = [:]
            for a in report?.actions ?? [] {
                if let s = harness.registry.spec(a.call.spec) {
                    info[a.id] = ActionInfo(privilege: s.privilege, reversible: s.reversible || a.reversible, summary: s.summary, fields: s.fields)
                }
            }
            let state = chat.state(run)
            let journal = run.journalEntries
            return json(ChatView(state: state, transcript: chat.transcript(run), report: report, actionInfo: info,
                                 executed: journal.filter { $0.event == .executed }.compactMap(\.actionID),
                                 undoable: run.undoable.compactMap(\.actionID), undoNeedsAdmin: harness.undoNeedsAdmin(run),
                                 busy: manager.hub(run.id).busy,
                                 candidates: state.candidates.compactMap { id in
                                     chat.graph.node(id).map { SkillLibrary.view($0, graph: chat.graph) }
                                 }))
        }
        // A field changed on a proposal's card: checked again and saved; the page reloads the chat to show it.
        api.post("chat/:id/edit") { req, ctx in
            let chat = try engine()
            let run = try chatRun(ctx)
            let b = try await decode(req, EditBody.self)
            guard manager.hub(run.id).busy == nil else { throw HTTPError(.conflict, message: "bibi is still working on this chat") }
            do {
                return json(try chat.edit(run, action: b.action, changes: b.params))
            } catch let e as ActionError {
                throw HTTPError(.badRequest, message: e.description)
            }
        }
        // The options of a choice field: Mail's sending addresses, calendars, reminder lists.
        api.get("choices/:source") { _, ctx in
            do {
                return json(try await harness.apps.choices(ctx.parameters.get("source") ?? ""))
            } catch {
                throw HTTPError(.badRequest, message: "\(error)")
            }
        }
        api.get("chat/:id/events") { req, ctx in
            let run = try chatRun(ctx)
            let from = req.uri.queryParameters["from"].flatMap { Int(String($0)) } ?? 0
            return sse(manager.hub(run.id).subscribe(from: from))
        }
        api.post("chat/:id/decide") { req, ctx in
            let chat = try engine()
            let run = try chatRun(ctx)
            let b = try await decode(req, DecideBody.self)
            let approve = b.approve ?? [], skip = b.skip ?? []
            // Unknown or superseded ids are a 400 now, not a failed background turn.
            _ = try bound(run, approve + skip)
            let pending = chat.state(run).pending
            let open = Set(run.report()?.findings.first { $0.id == pending }?.recommendations.map(\.id) ?? [])
            if let stale = (approve + skip).first(where: { !open.contains($0) }) {
                throw HTTPError(.badRequest, message: "\(stale) belongs to an earlier proposal; ask again")
            }
            let hub = manager.hub(run.id)
            guard hub.begin("decide") else { throw HTTPError(.conflict, message: "bibi is still busy with this chat (\(hub.busy ?? ""))") }
            let decision = ChatDecision(approve: approve, skip: skip, reason: b.reason, adminConfirmed: b.confirmAdmin ?? false,
                                        dryRun: b.dryRun ?? false)
            Task {
                do {
                    _ = try await chat.decide(run, decision, admin: OsascriptRunner()) { hub.emit($0, $1, phase: "chat") }
                } catch {
                    hub.emit("error", "\(error)", phase: "chat")
                }
                hub.emit("done", "decide", phase: "chat")
            }
            return json(["ok": true])
        }

        api.get("graph/quick") { _, _ in json(try engine().quickSkills()) }
        api.get("graph/skills") { _, _ in json(SkillLibrary.all(try engine().graph)) }
        api.post("graph/skills/:name/:verb") { _, ctx in
            let chat = try engine()
            let name = try ctx.parameters.require("name"), verb = try ctx.parameters.require("verb")
            guard ["accept", "dismiss", "disable", "enable"].contains(verb) else { throw HTTPError(.notFound, message: "unknown verb \(verb)") }
            do {
                return json(try SkillLibrary.decide(name, verb, graph: chat.graph, harness: harness))
            } catch let e as ActionError {
                throw HTTPError(.badRequest, message: e.description)
            }
        }
        api.post("graph/skills/:name/guidance") { req, ctx in
            let chat = try engine()
            let name = try ctx.parameters.require("name")
            let b = try await decode(req, GuidanceBody.self)
            guard let n = chat.graph.node(GraphSync.skillID(name)), n.kind == "skill" else { throw HTTPError(.notFound, message: "no skill \(name)") }
            PromptBook(chat.graph).revise("skill." + name, text: String(b.text.prefix(2000)), reason: "edited in the web UI")
            return json(SkillLibrary.view(n, graph: chat.graph))
        }
    }

    func tuning() throws -> GraphTuning { GraphTuning(graph: try engine().graph, harness: harness) }

    /// The Graph page: fine-tuning what chat retrieves for each skill, and an advanced editor for any node or edge.
    /// Node ids contain ":", so they travel in the query or the body.
    func registerGraph(_ api: RouterGroup<BasicRequestContext>) {
        api.get("graph/tune/:name") { _, ctx in json(try checked { try tuning().view(ctx.parameters.require("name")) }) }
        api.post("graph/tune/:name/override") { req, ctx in
            let b = try await decode(req, OverrideBody.self)
            return json(try checked { try tuning().override(ctx.parameters.require("name"), keywords: b.keywords, text: b.text) })
        }
        api.post("graph/tune/:name/examples") { req, ctx in
            let b = try await decode(req, ExampleBody.self)
            return json(try checked { try tuning().addExample(ctx.parameters.require("name"), text: b.text ?? "", steps: b.steps ?? []) })
        }
        api.post("graph/tune/:name/example") { req, ctx in
            let b = try await decode(req, ExampleBody.self)
            let name = try ctx.parameters.require("name"), t = try tuning()
            guard let id = b.id else { throw HTTPError(.badRequest, message: "id is required") }
            return json(try checked {
                b.remove == true ? try t.removeExample(name, id: id)
                    : try t.updateExample(name, id: id, text: b.text, steps: b.steps, weight: b.weight, status: b.status)
            })
        }
        api.post("graph/tune/:name/actions") { req, ctx in
            let b = try await decode(req, LinkActionBody.self)
            return json(try checked { try tuning().linkAction(ctx.parameters.require("name"), action: b.action, linked: b.linked) })
        }
        api.post("graph/tune/:name/steps") { req, ctx in
            let b = try await decode(req, StepsBody.self)
            return json(try checked { try tuning().setSteps(ctx.parameters.require("name"), steps: b.steps, params: b.params ?? []) })
        }
        api.get("graph/preview") { req, _ in json(try engine().retrieval(req.uri.queryParameters["q"].map(String.init) ?? "")) }
        api.get("graph/kinds") { _, _ in json(try tuning().kinds()) }
        api.get("graph/nodes") { req, _ in
            let q = req.uri.queryParameters
            return json(try tuning().nodes(kind: q["kind"].map(String.init), query: q["q"].map(String.init) ?? ""))
        }
        api.get("graph/node") { req, _ in json(try checked { try tuning().node(req.uri.queryParameters["id"].map(String.init) ?? "") }) }
        api.post("graph/node") { req, _ in
            let b = try await decode(req, NodeBody.self)
            return json(try checked { try tuning().updateNode(b.id, name: b.name, text: b.text, status: b.status, props: b.props) })
        }
        api.delete("graph/node") { req, _ in
            try checked { try tuning().deleteNode(req.uri.queryParameters["id"].map(String.init) ?? "") }
            return json(["ok": true])
        }
        api.post("graph/edge") { req, _ in
            let b = try await decode(req, EdgeBody.self)
            try checked { try tuning().edge(b.src, b.dst, b.kind, weight: b.weight, remove: b.remove ?? false) }
            return json(["ok": true])
        }
    }

    /// A change the graph refuses is the request's fault: 400 with the reason.
    @discardableResult
    func checked<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as ActionError { throw HTTPError(.badRequest, message: e.description) }
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
                info[a.id] = ActionInfo(privilege: s.privilege, reversible: s.reversible || a.reversible, summary: s.summary)
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
