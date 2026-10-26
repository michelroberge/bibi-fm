import Foundation

/// A node of bibi's knowledge graph: a skill, namespace, action, prompt (and its versions), intent, fact or conversation.
public struct GraphNode: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var name: String
    public var text: String
    public var props: [String: JSONValue]
    public var status: String  // active, candidate, dismissed, disabled, retired, rolled-back
    public var created: Date
    public var updated: Date

    public init(id: String, kind: String, name: String, text: String = "", props: [String: JSONValue] = [:],
                status: String = "active") {
        self.id = id; self.kind = kind; self.name = name; self.text = text; self.props = props; self.status = status
        self.created = Date(); self.updated = Date()
    }
}

public struct GraphEdge: Codable, Sendable, Equatable {
    public var src: String
    public var dst: String
    public var kind: String
    public var weight: Double
    public var props: [String: JSONValue]
}

/// One statistics event: what was asked, proposed, approved, skipped, executed.
public struct GraphEvent: Codable, Sendable {
    public var id: Int64
    public var time: Date
    public var kind: String
    public var node: String
    public var conversation: String?
    public var payload: JSONValue?
}

/// bibi's built-in database: a property graph (nodes, edges), an append-only event log for statistics,
/// embeddings for similarity, and full-text search. One SQLite file, $BIBI_HOME/bibi.db.
public final class GraphStore: Sendable {
    private let db: Mutex<SQLiteDB>
    public let path: String

    static let migrations = [
        """
        CREATE TABLE nodes(id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, text TEXT NOT NULL DEFAULT '',
                           props TEXT NOT NULL DEFAULT '{}', status TEXT NOT NULL DEFAULT 'active',
                           created REAL NOT NULL, updated REAL NOT NULL);
        CREATE INDEX nodes_kind ON nodes(kind, status);
        CREATE TABLE edges(src TEXT NOT NULL, dst TEXT NOT NULL, kind TEXT NOT NULL, weight REAL NOT NULL DEFAULT 1,
                           props TEXT NOT NULL DEFAULT '{}', PRIMARY KEY(src, dst, kind));
        CREATE INDEX edges_dst ON edges(dst, kind);
        CREATE TABLE events(id INTEGER PRIMARY KEY AUTOINCREMENT, time REAL NOT NULL, kind TEXT NOT NULL, node TEXT NOT NULL,
                            conversation TEXT, payload TEXT);
        CREATE INDEX events_node ON events(node, kind);
        CREATE TABLE vectors(node TEXT PRIMARY KEY, data BLOB NOT NULL);
        CREATE VIRTUAL TABLE nodes_fts USING fts5(id UNINDEXED, name, text);
        """,
    ]

    public init(path: String = Paths.bibiHome + "/bibi.db") throws {
        if path != ":memory:" {
            try FileManager.default.createDirectory(atPath: Paths.parent(path), withIntermediateDirectories: true)
        }
        let d = try SQLiteDB(path: path)
        try d.migrate(Self.migrations)
        self.db = Mutex(d)
        self.path = path
    }

    // MARK: nodes

    static func encode(_ props: [String: JSONValue]) -> String { JSON.string(props) }
    static func decodeProps(_ text: String?) -> [String: JSONValue] {
        text.flatMap { try? JSON.decode([String: JSONValue].self, from: $0) } ?? [:]
    }

    static func node(_ r: [String: SQLValue]) -> GraphNode {
        var n = GraphNode(id: r["id"]?.string ?? "", kind: r["kind"]?.string ?? "", name: r["name"]?.string ?? "",
                          text: r["text"]?.string ?? "", props: decodeProps(r["props"]?.string), status: r["status"]?.string ?? "")
        n.created = Date(timeIntervalSince1970: r["created"]?.double ?? 0)
        n.updated = Date(timeIntervalSince1970: r["updated"]?.double ?? 0)
        return n
    }

    /// Inserts or replaces a node (keeping its creation time) and its search entry.
    public func upsert(_ n: GraphNode) {
        _ = try? db.withLock { d in
            try d.transaction {
                // A changed text makes its embedding stale.
                try d.query("DELETE FROM vectors WHERE node = ? AND EXISTS(SELECT 1 FROM nodes WHERE id = ? AND text != ?)",
                            [.text(n.id), .text(n.id), .text(n.text)])
                try d.query("""
                    INSERT INTO nodes(id, kind, name, text, props, status, created, updated) VALUES(?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, name=excluded.name, text=excluded.text,
                      props=excluded.props, status=excluded.status, updated=excluded.updated
                    """, [.text(n.id), .text(n.kind), .text(n.name), .text(n.text), .text(Self.encode(n.props)), .text(n.status),
                          .double(n.created.timeIntervalSince1970), .double(Date().timeIntervalSince1970)])
                try d.query("DELETE FROM nodes_fts WHERE id = ?", [.text(n.id)])
                try d.query("INSERT INTO nodes_fts(id, name, text) VALUES(?,?,?)", [.text(n.id), .text(n.name), .text(n.text)])
            }
        }
    }

    public func node(_ id: String) -> GraphNode? {
        (try? db.withLock { try $0.query("SELECT * FROM nodes WHERE id = ?", [.text(id)]) })?.first.map(Self.node)
    }

    /// Nodes of a kind, newest first; `status` nil = any.
    public func nodes(kind: String, status: String? = nil) -> [GraphNode] {
        let rows = try? db.withLock { d in
            status == nil
                ? try d.query("SELECT * FROM nodes WHERE kind = ? ORDER BY updated DESC", [.text(kind)])
                : try d.query("SELECT * FROM nodes WHERE kind = ? AND status = ? ORDER BY updated DESC", [.text(kind), .text(status!)])
        }
        return (rows ?? []).map(Self.node)
    }

    /// Changes a node in place; does nothing if it doesn't exist.
    public func update(_ id: String, _ change: (inout GraphNode) -> Void) {
        guard var n = node(id) else { return }
        change(&n)
        upsert(n)
    }

    public func setStatus(_ id: String, _ status: String) { update(id) { $0.status = status } }

    /// Removes a node with its edges, search entry and embedding. Events about it stay (they are statistics).
    public func delete(_ id: String) {
        _ = try? db.withLock { d in
            try d.transaction {
                for sql in ["DELETE FROM nodes WHERE id = ?", "DELETE FROM edges WHERE src = ? OR dst = ?",
                            "DELETE FROM nodes_fts WHERE id = ?", "DELETE FROM vectors WHERE node = ?"] {
                    try d.query(sql, Array(repeating: SQLValue.text(id), count: sql.filter { $0 == "?" }.count))
                }
            }
        }
    }

    // MARK: edges

    public func link(_ src: String, _ dst: String, _ kind: String, weight: Double = 1, props: [String: JSONValue] = [:]) {
        _ = try? db.withLock { d in
            try d.query("""
                INSERT INTO edges(src, dst, kind, weight, props) VALUES(?,?,?,?,?)
                ON CONFLICT(src, dst, kind) DO UPDATE SET weight=excluded.weight, props=excluded.props
                """, [.text(src), .text(dst), .text(kind), .double(weight), .text(Self.encode(props))])
        }
    }

    /// Adds to an edge's weight, creating it with that weight if needed.
    public func strengthen(_ src: String, _ dst: String, _ kind: String, by delta: Double = 1) {
        _ = try? db.withLock { d in
            try d.query("""
                INSERT INTO edges(src, dst, kind, weight) VALUES(?,?,?,?)
                ON CONFLICT(src, dst, kind) DO UPDATE SET weight = weight + excluded.weight
                """, [.text(src), .text(dst), .text(kind), .double(delta)])
        }
    }

    public func unlink(_ src: String, _ dst: String, _ kind: String) {
        _ = try? db.withLock { try $0.query("DELETE FROM edges WHERE src=? AND dst=? AND kind=?", [.text(src), .text(dst), .text(kind)]) }
    }

    static func edge(_ r: [String: SQLValue]) -> GraphEdge {
        GraphEdge(src: r["src"]?.string ?? "", dst: r["dst"]?.string ?? "", kind: r["kind"]?.string ?? "",
                  weight: r["weight"]?.double ?? 0, props: decodeProps(r["props"]?.string))
    }

    public func edges(from src: String, kind: String? = nil) -> [GraphEdge] {
        let rows = try? db.withLock { d in
            kind == nil ? try d.query("SELECT * FROM edges WHERE src = ? ORDER BY weight DESC", [.text(src)])
                : try d.query("SELECT * FROM edges WHERE src = ? AND kind = ? ORDER BY weight DESC", [.text(src), .text(kind!)])
        }
        return (rows ?? []).map(Self.edge)
    }

    public func edges(to dst: String, kind: String? = nil) -> [GraphEdge] {
        let rows = try? db.withLock { d in
            kind == nil ? try d.query("SELECT * FROM edges WHERE dst = ? ORDER BY weight DESC", [.text(dst)])
                : try d.query("SELECT * FROM edges WHERE dst = ? AND kind = ? ORDER BY weight DESC", [.text(dst), .text(kind!)])
        }
        return (rows ?? []).map(Self.edge)
    }

    /// Nodes reachable from `id` along `kind` edges in either direction (incoming when `reverse`), up to `depth` hops.
    public func neighbors(_ id: String, kind: String, depth: Int = 1, reverse: Bool = false) -> [GraphNode] {
        let (from, to) = reverse ? ("dst", "src") : ("src", "dst")
        let sql = """
            WITH RECURSIVE walk(id, d) AS (
              SELECT ?, 0
              UNION
              SELECT e.\(to), walk.d + 1 FROM edges e JOIN walk ON e.\(from) = walk.id WHERE e.kind = ? AND walk.d < ?
            )
            SELECT n.* FROM nodes n JOIN (SELECT id, MIN(d) AS d FROM walk WHERE d > 0 GROUP BY id) w ON n.id = w.id
            ORDER BY w.d, n.name
            """
        return ((try? db.withLock { try $0.query(sql, [.text(id), .text(kind), .int(Int64(depth))]) }) ?? []).map(Self.node)
    }

    // MARK: search

    /// Full-text matches of any word in `text`, best first. Words are reduced to letters and digits so user text
    /// can never be FTS syntax.
    public func search(_ text: String, kind: String? = nil, limit: Int = 10) -> [GraphNode] {
        let words = Similarity.tokens(text).filter { $0.count > 2 }.prefix(12)
        guard !words.isEmpty else { return [] }
        let match = words.map { "\"\($0)\"" }.joined(separator: " OR ")
        let rows = try? db.withLock { d in
            try d.query("""
                SELECT n.* FROM nodes_fts f JOIN nodes n ON n.id = f.id
                WHERE nodes_fts MATCH ? \(kind == nil ? "" : "AND n.kind = ?") ORDER BY bm25(nodes_fts) LIMIT ?
                """, [.text(match)] + (kind.map { [.text($0)] } ?? []) + [.int(Int64(limit))])
        }
        return (rows ?? []).map(Self.node)
    }

    // MARK: vectors

    public func setVector(_ id: String, _ v: [Float]) {
        let data = v.withUnsafeBufferPointer { Data(buffer: $0) }
        _ = try? db.withLock { try $0.query("INSERT OR REPLACE INTO vectors(node, data) VALUES(?,?)", [.text(id), .blob(data)]) }
    }

    public func vector(_ id: String) -> [Float]? {
        guard let data = (try? db.withLock { try $0.query("SELECT data FROM vectors WHERE node = ?", [.text(id)]) })?.first?["data"]?.data
        else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: events and statistics

    @discardableResult
    public func record(_ kind: String, node: String, conversation: String? = nil, payload: JSONValue? = nil) -> Int64 {
        (try? db.withLock { d -> Int64 in
            try d.query("INSERT INTO events(time, kind, node, conversation, payload) VALUES(?,?,?,?,?)",
                        [.double(Date().timeIntervalSince1970), .text(kind), .text(node),
                         conversation.map { .text($0) } ?? .null, payload.map { .text(JSON.string($0)) } ?? .null])
            return d.lastInsertID
        }) ?? 0
    }

    /// Event counts for a node by kind, e.g. ["proposed": 4, "approved": 3].
    public func stats(_ node: String) -> [String: Int] {
        let rows = (try? db.withLock { try $0.query("SELECT kind, COUNT(*) AS n FROM events WHERE node = ? GROUP BY kind", [.text(node)]) }) ?? []
        var out: [String: Int] = [:]
        for r in rows { out[r["kind"]?.string ?? ""] = Int(r["n"]?.int ?? 0) }
        return out
    }

    public func events(node: String? = nil, kind: String? = nil, limit: Int = 200) -> [GraphEvent] {
        var sql = "SELECT * FROM events WHERE 1=1", args: [SQLValue] = []
        if let node { sql += " AND node = ?"; args.append(.text(node)) }
        if let kind { sql += " AND kind = ?"; args.append(.text(kind)) }
        sql += " ORDER BY id DESC LIMIT ?"
        args.append(.int(Int64(limit)))
        return ((try? db.withLock { try $0.query(sql, args) }) ?? []).map { r in
            GraphEvent(id: r["id"]?.int ?? 0, time: Date(timeIntervalSince1970: r["time"]?.double ?? 0), kind: r["kind"]?.string ?? "",
                       node: r["node"]?.string ?? "", conversation: r["conversation"]?.string,
                       payload: r["payload"]?.string.flatMap { try? JSON.decode(JSONValue.self, from: $0) })
        }
    }

    /// Posterior mean of the approval rate with a uniform prior: (approved + 1) / (approved + skipped + 2).
    public func approvalRate(_ node: String) -> Double {
        let s = stats(node)
        let ok = Double(s["approved", default: 0]), no = Double(s["skipped", default: 0] + s["failed", default: 0])
        return (ok + 1) / (ok + no + 2)
    }
}

/// Text similarity without the model: embeddings when available, otherwise word overlap.
public enum Similarity {
    public static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static let stopwords: Set<String> = ["the", "a", "an", "my", "of", "to", "in", "on", "for", "is", "are", "what", "how", "me",
                                         "and", "or", "do", "i", "it", "this", "that", "please", "can", "you", "with", "much", "many"]

    /// Lowercase content words with a plural s removed.
    public static func terms(_ text: String) -> Set<String> {
        Set(tokens(text).filter { !stopwords.contains($0) && $0.count > 1 }.map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
    }

    /// How many content words of `query` appear in `text`.
    public static func hits(_ query: String, _ text: String) -> Int { terms(query).intersection(terms(text)).count }

    public static func jaccard(_ a: String, _ b: String) -> Double {
        let x = Set(tokens(a)).subtracting(stopwords), y = Set(tokens(b)).subtracting(stopwords)
        guard !x.isEmpty || !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var d: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? Double(d / (na.squareRoot() * nb.squareRoot())) : 0
    }

    /// 0...1: the better of cosine (when both vectors exist) and word overlap.
    public static func score(_ a: String, _ va: [Float]?, _ b: String, _ vb: [Float]?) -> Double {
        let j = jaccard(a, b)
        guard let va, let vb else { return j }
        return max(j, cosine(va, vb))
    }
}
