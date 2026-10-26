import BibiCore
import Foundation

/// A folder or file in the size tree. Built once by `scan`, then only read.
public final class Node: @unchecked Sendable {
    public let path: String
    public let size: Int  // bytes on disk
    public let isDir: Bool
    public let mtime: Date?
    public var children: [Node] = []

    public init(_ path: String, _ size: Int, isDir: Bool = true, mtime: Date? = nil) {
        self.path = path; self.size = size; self.isDir = isDir; self.mtime = mtime
    }

    public var ageDays: Int { mtime.map { Int(Date().timeIntervalSince($0) / 86400) } ?? -1 }
}

public func diskUsage(_ path: String = "/") -> (free: Int, total: Int) {
    let url = URL(fileURLWithPath: path)
    let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
    return (Int(v?.volumeAvailableCapacityForImportantUsage ?? 0), v?.volumeTotalCapacity ?? 0)
}

/// Runs `du -d depth` once (directories), adds large files found in those directories, and returns the root
/// with children sorted by size. Entries smaller than minKeep are dropped to keep the tree small. Unreadable
/// directories (permissions / TCC) are silently skipped by du, so sizes are a lower bound.
public func scan(_ root: String, depth: Int, minKeep: Int = 1 << 20,
                 progress: (@Sendable (Int, String) -> Void)? = nil) async throws -> Node {
    var sizes: [String: Int] = [:]
    var i = 0
    for try await line in Command.lines(["du", "-k", "-d", String(depth), root]) {
        let parts = line.split(separator: "\t", maxSplits: 1)
        if parts.count == 2, let kb = Int(parts[0]) {
            let p = String(parts[1]), size = kb * 1024
            if size >= minKeep || p == root { sizes[p] = size }
            progress?(i, p)
        }
        i += 1
    }

    var nodes: [String: Node] = [:]
    for (p, size) in sizes { nodes[p] = Node(p, size, isDir: true, mtime: Paths.mtime(p)) }
    // macOS du can't combine -a with -d, so pick up large files with a shallow listing.
    for dir in Array(nodes.keys) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
        for name in entries {
            let p = dir + "/" + name
            var st = stat()
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let bytes = Int(st.st_blocks) * 512
            if bytes >= minKeep {
                nodes[p] = Node(p, bytes, isDir: false, mtime: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
            }
        }
    }
    if nodes[root] == nil { nodes[root] = Node(root, 0) }
    for (p, node) in nodes where p != root {
        nodes[Paths.parent(p)]?.children.append(node)
    }
    for node in nodes.values { node.children.sort { $0.size > $1.size } }
    return nodes[root]!
}
