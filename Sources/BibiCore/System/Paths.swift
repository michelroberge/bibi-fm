import Foundation

/// Absolute paths are plain strings throughout bibi; these helpers give them Path-like behavior.
public enum Paths {
    public static let home = NSHomeDirectory()

    /// Where bibi keeps history, quarantined files and settings. Override with BIBI_HOME.
    public static var bibiHome: String {
        if let env = ProcessInfo.processInfo.environment["BIBI_HOME"], !env.isEmpty { return expand(env) }
        return home + "/Library/Application Support/bibi"
    }

    public static func expand(_ path: String) -> String {
        let p = (path as NSString).expandingTildeInPath
        return p.hasPrefix("/") ? standardize(p) : standardize(FileManager.default.currentDirectoryPath + "/" + p)
    }

    public static func standardize(_ path: String) -> String {
        let s = (path as NSString).standardizingPath
        return s.isEmpty ? "/" : s
    }

    /// Resolves symlinks (e.g. /var -> /private/var) like Python's Path.resolve().
    public static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: expand(path)).resolvingSymlinksInPath().path
    }

    /// True if path equals base or lies inside it.
    public static func isWithin(_ path: String, _ base: String) -> Bool {
        if path == base { return true }
        let b = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(b)
    }

    public static func parts(_ path: String) -> [String] { (path as NSString).pathComponents }
    public static func name(_ path: String) -> String { (path as NSString).lastPathComponent }
    public static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
    public static func ext(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }
    public static func join(_ base: String, _ rest: String...) -> String {
        rest.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// "~/x" for paths in the home folder.
    public static func short(_ path: String) -> String {
        if path == home { return "~" }
        if isWithin(path, home) { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }

    public static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    public static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    public static func mtime(_ path: String) -> Date? {
        var st = stat()
        return lstat(path, &st) == 0 ? Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)) : nil
    }

    public static func children(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted().map { join(path, $0) }
    }
}

public func human(_ bytes: Double) -> String {
    var n = bytes
    for unit in ["B", "KB", "MB", "GB", "TB"] {
        if abs(n) < 1024 || unit == "TB" {
            return unit == "B" || unit == "KB" ? String(format: "%.0f %@", n, unit) : String(format: "%.1f %@", n, unit)
        }
        n /= 1024
    }
    return String(format: "%.1f TB", n)
}

public func human(_ bytes: Int) -> String { human(Double(bytes)) }

/// "3 days ago" style age.
public func ago(_ date: Date, now: Date = Date()) -> String {
    let days = Int(now.timeIntervalSince(date) / 86400)
    if days <= 0 { return "today" }
    if days == 1 { return "yesterday" }
    return "\(days) days ago"
}
