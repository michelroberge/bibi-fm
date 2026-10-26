import Foundation

/// Terminal: `sudo -k` ignores any cached credentials, so the password is asked for every single time.
public struct SudoRunner: AdminRunner {
    public init() {}

    public func run(_ argv: [String]) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-k", "-p", "bibi needs your password to run \(argv[0]): ", "--"] + argv
            p.standardInput = FileHandle.standardInput
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.standardError
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw ActionError("sudo \(argv[0]) failed (exit \(p.terminationStatus))") }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

/// Web UI: the native macOS password dialog. bibi and the browser never see the password, and
/// `with administrator privileges` asks again on every call from a new osascript process.
public struct OsascriptRunner: AdminRunner {
    public init() {}

    public static func script(_ argv: [String]) -> String {
        let shell = Shell.join(argv)
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges with prompt \"bibi needs your password to run \(argv[0].replacingOccurrences(of: "\"", with: "")).\""
    }

    public func run(_ argv: [String]) async throws -> String {
        let out = await Command.run(["/usr/bin/osascript", "-e", Self.script(argv)], timeout: 600)
        if out.stderr.contains("User canceled") || out.stderr.contains("(-128)") { throw ActionError("password prompt was cancelled") }
        try out.check()
        return out.stdout
    }
}

/// For tests and dry runs: records what would have run.
public final class RecordingAdminRunner: AdminRunner, @unchecked Sendable {
    public private(set) var calls: [[String]] = []
    private let lock = NSLock()
    public init() {}
    public func run(_ argv: [String]) async throws -> String {
        lock.withLock { calls.append(argv) }
        return ""
    }
}

/// Moves files into bibi's quarantine folder (instead of deleting them) so they can be restored.
public enum Quarantine {
    public static var root: String { Paths.bibiHome + "/quarantine" }

    public static func destination(for path: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        return root + "/" + stamp + "/" + Paths.name(path)
    }
}
