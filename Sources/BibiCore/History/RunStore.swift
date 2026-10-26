import Foundation

public struct RunMeta: Codable, Sendable {
    public var id: String
    public var skill: String
    public var args: [String]
    public var online: Bool
    public var started: Date
    public var finished: Date?
    public var version: String
    public var summary: String?
    public var findings: Int?
    public var actions: Int?
    public var error: String?
}

extension RunMeta {
    /// Case-insensitive match on what the History page shows: command, arguments, summary, error and id.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [skill, args.joined(separator: " "), summary ?? "", error ?? "", id].contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

public struct JournalEntry: Codable, Sendable {
    public enum Event: String, Codable, Sendable {
        case selected, previewed, dryRun = "dry-run", executed, failed, undone, undoFailed = "undo-failed"
    }
    public var time: Date
    public var event: Event
    public var actionID: String?
    public var title: String?
    public var call: ActionCall?
    public var message: String?
    public var undo: ActionCall?
    public var error: String?
    public var frontend: String?

    public init(_ event: Event, actionID: String? = nil, title: String? = nil, call: ActionCall? = nil, message: String? = nil,
                undo: ActionCall? = nil, error: String? = nil, frontend: String? = nil) {
        self.time = Date(); self.event = event; self.actionID = actionID; self.title = title; self.call = call
        self.message = message; self.undo = undo; self.error = error; self.frontend = frontend
    }
}

public struct NetworkEntry: Codable, Sendable {
    public var time: Date
    public var method: String
    public var url: String
    public var sent: String?
    public var status: Int?
    public var error: String?
}

/// One saved run: report.json, meta.json and append-only logs (journal, model, network).
public final class RunRecord: Sendable {
    public let dir: String
    private let metaBox: Mutex<RunMeta>
    private let lock = NSLock()

    init(dir: String, meta: RunMeta) {
        self.dir = dir
        self.metaBox = Mutex(meta)
    }

    public var meta: RunMeta { metaBox.withLock { $0 } }
    public var id: String { meta.id }

    public func updateMeta(_ change: (inout RunMeta) -> Void) {
        let m = metaBox.withLock { m -> RunMeta in
            change(&m)
            return m
        }
        try? JSON.prettyEncoder.encode(m).write(to: URL(fileURLWithPath: dir + "/meta.json"), options: .atomic)
    }

    public func save(_ result: SkillResult) {
        try? JSON.prettyEncoder.encode(result).write(to: URL(fileURLWithPath: dir + "/report.json"), options: .atomic)
        updateMeta {
            $0.finished = $0.finished ?? Date()
            $0.summary = result.summary
            $0.findings = result.findings.count
            $0.actions = result.actions.count
        }
    }

    public func report() -> SkillResult? {
        guard let data = FileManager.default.contents(atPath: dir + "/report.json") else { return nil }
        return try? JSON.decoder.decode(SkillResult.self, from: data)
    }

    private func append(_ file: String, _ value: some Encodable) {
        guard var data = try? JSON.encoder.encode(value) else { return }
        data.append(0x0A)
        lock.withLock {
            let path = dir + "/" + file
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }

    private func read<T: Decodable>(_ file: String, _ type: T.Type) -> [T] {
        guard let text = try? String(contentsOfFile: dir + "/" + file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSON.decoder.decode(T.self, from: Data($0.utf8)) }
    }

    /// Extra per-run files (chat state and transcript).
    public func saveFile(_ file: String, _ value: some Encodable) {
        try? JSON.prettyEncoder.encode(value).write(to: URL(fileURLWithPath: dir + "/" + file), options: .atomic)
    }
    public func loadFile<T: Decodable>(_ file: String, _ type: T.Type) -> T? {
        FileManager.default.contents(atPath: dir + "/" + file).flatMap { try? JSON.decoder.decode(T.self, from: $0) }
    }
    public func appendLine(_ file: String, _ value: some Encodable) { append(file, value) }
    public func lines<T: Decodable>(_ file: String, _ type: T.Type) -> [T] { read(file, type) }

    public func journal(_ e: JournalEntry) { append("journal.jsonl", e) }
    public func model(_ e: ModelLogEntry) { append("model.jsonl", e) }
    public func network(_ e: NetworkEntry) { append("network.jsonl", e) }

    public var journalEntries: [JournalEntry] { read("journal.jsonl", JournalEntry.self) }
    public var modelEntries: [ModelLogEntry] { read("model.jsonl", ModelLogEntry.self) }
    public var networkEntries: [NetworkEntry] { read("network.jsonl", NetworkEntry.self) }

    /// Executed actions that recorded an undo and haven't been undone yet, newest first.
    public var undoable: [JournalEntry] {
        let entries = journalEntries
        let undone = Set(entries.filter { $0.event == .undone }.compactMap(\.actionID))
        return entries.filter { $0.event == .executed && $0.undo != nil && !undone.contains($0.actionID ?? "") }.reversed()
    }
}

/// All runs, under $BIBI_HOME/runs/<skill>/<id>/.
public final class RunStore: Sendable {
    public let root: String

    public init(root: String = Paths.bibiHome + "/runs") { self.root = root }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    public func create(skill: String, args: [String], online: Bool, version: String) throws -> RunRecord {
        let suffix = String(UInt32.random(in: 0...0xFFFF), radix: 16)
        let id = Self.stamp.string(from: Date()) + "-" + suffix
        let dir = root + "/" + skill + "/" + id
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let meta = RunMeta(id: id, skill: skill, args: args, online: online, started: Date(), finished: nil, version: version)
        let run = RunRecord(dir: dir, meta: meta)
        run.updateMeta { _ in }
        return run
    }

    func load(_ dir: String) -> RunRecord? {
        guard let data = FileManager.default.contents(atPath: dir + "/meta.json"),
              let meta = try? JSON.decoder.decode(RunMeta.self, from: data) else { return nil }
        return RunRecord(dir: dir, meta: meta)
    }

    /// Newest first.
    public func list(skill: String? = nil) -> [RunRecord] {
        let skills = skill.map { [$0] } ?? ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
        return skills.flatMap { s in
            ((try? FileManager.default.contentsOfDirectory(atPath: root + "/" + s)) ?? []).compactMap { load(root + "/" + s + "/" + $0) }
        }.sorted { $0.meta.started > $1.meta.started }
    }

    /// Removes a run and everything saved with it (only folders inside this store).
    public func delete(_ run: RunRecord) throws {
        guard Paths.isWithin(run.dir, root), run.dir != root else { throw ActionError("\(run.dir) is not a run folder") }
        try FileManager.default.removeItem(atPath: run.dir)
    }

    /// By full id or unique prefix.
    public func find(_ id: String) -> RunRecord? {
        let all = list()
        return all.first { $0.id == id } ?? { let m = all.filter { $0.id.hasPrefix(id) }; return m.count == 1 ? m[0] : nil }()
    }

    /// The run to compare against: `since` is a run id or an age like "7d"/"24h". Default: the newest finished run
    /// at least 6 days old, else the newest finished one.
    public func baseline(skill: String, since: String? = nil, excluding: String? = nil, now: Date = Date()) -> RunRecord? {
        let runs = list(skill: skill).filter { $0.id != excluding && $0.meta.finished != nil && $0.meta.error == nil }
        if let since {
            if let age = Self.age(since) { return runs.first { now.timeIntervalSince($0.meta.started) >= age } ?? runs.last }
            return runs.first { $0.id == since || $0.id.hasPrefix(since) }
        }
        return runs.first { now.timeIntervalSince($0.meta.started) >= 6 * 86400 } ?? runs.first
    }

    public static func age(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let n = Double(text.dropLast()) else { return nil }
        switch unit {
        case "d": return n * 86400
        case "h": return n * 3600
        case "w": return n * 7 * 86400
        default: return nil
        }
    }
}
