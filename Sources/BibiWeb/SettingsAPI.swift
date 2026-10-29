import BibiCore
import Foundation
import Hummingbird

struct KnobBody: Decodable {
    var id: String
    var value: Double?
}

struct TextBody: Decodable {
    var text: String
}

struct VersionBody: Decodable {
    var version: String
}

struct TryBody: Decodable {
    var text: String?
    var input: String
    /// chat.extract: the pasted output and what it was for.
    var purpose: String?
}

struct BenchBody: Decodable {
    var request: String
    var model: Bool?
}

struct EnabledBody: Decodable {
    var enabled: Bool
}

struct ParamsBody: Decodable {
    var params: [String: String]
}

struct PolicyBody: Decodable {
    var allow: [String]
    var block: [String]
}

struct CommandBody: Decodable {
    var command: String
}

struct SkillBody: Decodable {
    var name: String
    var help: String
    var keywords: String?
    var params: [String]?
    var steps: [PlannedStep]
    var active: Bool?
}

struct FactBody: Decodable {
    var id: String?
    var subject: String
    var statement: String
}

struct RestoreBody: Decodable {
    var name: String
}

struct CleanupBody: Decodable {
    var days: Int?
    var dryRun: Bool?
}

struct ImportResult: Encodable {
    var report: Settings.ImportReport
    var backup: String
}

struct CleanupItem: Encodable {
    var op: CleanupOp
    var group, title, detail: String
    var takesDays, safe: Bool
    var count: Int
}

extension API {
    func settings() throws -> Settings { Settings(graph: try engine().graph, harness: harness) }

    /// Settings: every knob, prompt, tool and stored item, with its built-in value and the user's override.
    func registerSettings(_ api: RouterGroup<BasicRequestContext>) {
        api.get("settings/overview") { _, _ in json(try settings().overview()) }

        api.get("settings/knobs") { _, _ in json(try settings().knobList()) }
        api.post("settings/knobs") { req, _ in
            let b = try await decode(req, KnobBody.self)
            let s = try settings()
            try checked { try s.setKnob(b.id, b.value) }
            return json(s.knobList())
        }
        api.post("settings/knobs/reset") { _, _ in
            let s = try settings()
            _ = s.cleanup(.knobs, dryRun: false)
            return json(s.knobList())
        }
        api.get("settings/model") { _, _ in json(["unavailable": FoundationModel.unavailableReason()]) }

        api.get("settings/prompts") { _, _ in json(try settings().promptList()) }
        api.get("settings/prompts/:id") { _, ctx in json(try checked { try settings().prompt(ctx.parameters.require("id")) }) }
        api.post("settings/prompts/:id") { req, ctx in
            let b = try await decode(req, TextBody.self)
            return json(try checked { try settings().savePrompt(ctx.parameters.require("id"), text: b.text) })
        }
        api.post("settings/prompts/:id/revert") { _, ctx in json(try checked { try settings().revertPrompt(ctx.parameters.require("id")) }) }
        api.post("settings/prompts/:id/activate") { req, ctx in
            let b = try await decode(req, VersionBody.self)
            return json(try checked { try settings().activatePrompt(ctx.parameters.require("id"), version: b.version) })
        }
        api.post("settings/prompts/:id/try") { req, ctx in
            let id = try ctx.parameters.require("id")
            let b = try await decode(req, TryBody.self)
            guard let def = harness.promptCatalog.first(where: { $0.id == id }) else { throw HTTPError(.notFound, message: "no prompt \(id)") }
            if id == "chat.extract", let purpose = b.purpose {
                // The real notes path, with its grounding filter, on pasted output (uses the saved prompt).
                let lines = try await engine().tryExtract(output: b.input, purpose: purpose, request: purpose)
                return json(["lines": lines])
            }
            guard def.schema != nil else { throw HTTPError(.badRequest, message: "\(id) is part of another prompt; try it in the Test bench") }
            return json(await harness.tryPrompt(def, instructions: b.text ?? PromptBook(harness.graph).text(id, default: def.builtIn), input: b.input))
        }

        api.post("settings/test") { req, _ in
            let b = try await decode(req, BenchBody.self)
            guard !b.request.trimmingCharacters(in: .whitespaces).isEmpty else { throw HTTPError(.badRequest, message: "type a request") }
            return json(try await engine().dryTurn(b.request, askModel: b.model ?? false))
        }

        api.get("settings/tools") { _, _ in json(try settings().actions()) }
        api.post("settings/tools/:id") { req, ctx in
            let b = try await decode(req, EnabledBody.self)
            let s = try settings()
            try checked { try s.setAction(ctx.parameters.require("id"), enabled: b.enabled) }
            return json(s.actions())
        }
        api.post("settings/tools/:id/preview") { req, ctx in
            let b = try await decode(req, ParamsBody.self)
            return json(try checked { try settings().previewAction(ctx.parameters.require("id"), params: b.params) })
        }
        api.get("settings/diagnostics") { _, _ in json(Diagnostics.all) }

        api.get("settings/apps") { _, _ in json(try settings().apps()) }
        api.post("settings/apps/rescan") { _, _ in
            let s = try settings()
            _ = s.rescanApps()
            return json(s.apps())
        }
        api.post("settings/apps/:bundle") { req, ctx in
            let b = try await decode(req, EnabledBody.self)
            let s = try settings()
            s.setApp(try ctx.parameters.require("bundle"), enabled: b.enabled)
            return json(s.apps())
        }

        api.get("settings/policy") { _, _ in json(try settings().policy()) }
        api.post("settings/policy") { req, _ in
            let b = try await decode(req, PolicyBody.self)
            return json(try checked { try settings().setPolicy(allow: b.allow, block: b.block) })
        }
        api.post("settings/policy/test") { req, _ in
            let b = try await decode(req, CommandBody.self)
            return json(try settings().checkCommand(b.command))
        }

        api.post("settings/skills") { req, _ in
            let b = try await decode(req, SkillBody.self)
            return json(try checked {
                try settings().createSkill(name: b.name, help: b.help, keywords: b.keywords ?? "", params: b.params ?? [], steps: b.steps,
                                           active: b.active ?? true)
            })
        }
        api.delete("settings/skills/:name") { _, ctx in
            try checked { try settings().deleteSkill(ctx.parameters.require("name")) }
            return json(["ok": true])
        }

        api.get("settings/examples") { req, _ in
            let q = req.uri.queryParameters
            return json(try settings().examples(query: q["q"].map(String.init) ?? "", source: q["source"].map(String.init),
                                                skill: q["skill"].map(String.init)))
        }
        // Example ids contain ":", so they travel in the query.
        api.post("settings/examples/revert") { req, _ in
            try checked { try settings().revertExample(req.uri.queryParameters["id"].map(String.init) ?? "") }
            return json(["ok": true])
        }
        api.delete("settings/examples") { req, _ in
            try checked { try settings().deleteExample(req.uri.queryParameters["id"].map(String.init) ?? "") }
            return json(["ok": true])
        }

        api.get("settings/facts") { req, _ in json(try settings().facts(query: req.uri.queryParameters["q"].map(String.init) ?? "")) }
        api.post("settings/facts") { req, _ in
            let b = try await decode(req, FactBody.self)
            return json(try checked { try settings().saveFact(id: b.id, subject: b.subject, statement: b.statement) })
        }
        api.delete("settings/facts") { req, _ in
            try checked { try settings().deleteFact(req.uri.queryParameters["id"].map(String.init) ?? "") }
            return json(["ok": true])
        }

        api.get("settings/data") { _, _ in json(try settings().data()) }
        api.get("settings/events") { req, _ in
            let q = req.uri.queryParameters
            return json(try settings().events(kind: q["kind"].map(String.init), node: q["node"].map(String.init)))
        }
        api.get("settings/export") { req, _ in
            json(try settings().export(learned: req.uri.queryParameters["learned"].map(String.init) == "1"))
        }
        api.post("settings/import") { req, _ in
            let b = try await decode(req, JSONValue.self)
            let s = try settings()
            let backup = try s.backup(label: "before-import")
            var r = try checked { try s.importOverrides(b) }
            r.skipped = Array(r.skipped.prefix(20))
            return json(ImportResult(report: r, backup: backup.name))
        }
        api.get("settings/backups") { _, _ in json(try settings().backups()) }
        api.post("settings/backups") { _, _ in json(try checked { try settings().backup() }) }
        api.post("settings/backups/restore") { req, _ in
            let b = try await decode(req, RestoreBody.self)
            return json(try checked { try settings().restore(b.name) })
        }
        api.post("settings/backups/reveal") { _, _ in
            let s = try settings()
            try? FileManager.default.createDirectory(atPath: s.backupDir, withIntermediateDirectories: true)
            _ = await Command.run(["open", s.backupDir])
            return json(["ok": true])
        }

        api.get("settings/cleanup") { _, _ in
            let s = try settings()
            return json(CleanupOp.allCases.map { op in
                CleanupItem(op: op, group: op.group, title: op.title, detail: op.detail, takesDays: op.takesDays, safe: op.safe,
                            count: s.cleanup(op, dryRun: true).count)
            })
        }
        api.post("settings/cleanup/:op") { req, ctx in
            guard let op = CleanupOp(rawValue: try ctx.parameters.require("op")) else { throw HTTPError(.notFound, message: "unknown cleanup") }
            let b = try await decode(req, CleanupBody.self)
            let s = try settings()
            if b.dryRun ?? false { return json(s.cleanup(op, dryRun: true, days: b.days ?? 0)) }
            // Undo is a restore: every real cleanup starts with a backup.
            let backup = try checked { try s.backup(label: op.rawValue) }
            var r = s.cleanup(op, dryRun: false, days: b.days ?? 0)
            r.backup = backup.name
            return json(r)
        }
    }
}
