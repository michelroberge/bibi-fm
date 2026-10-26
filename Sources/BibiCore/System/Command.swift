import Foundation

/// Output of an external command. `source` is how bibi cites it as evidence.
public struct CommandOutput: Sendable {
    public var argv: [String]
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public var ok: Bool { status == 0 && !timedOut }
    public var source: String { argv.map(Shell.quoteIfNeeded).joined(separator: " ") }
    public var lines: [String] { stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }

    public init(argv: [String], status: Int32, stdout: String, stderr: String = "", timedOut: Bool = false) {
        self.argv = argv; self.status = status; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut
    }
}

/// Runs external programs with an argv (never a shell string) and a timeout.
public enum Command {
    /// Directories searched in addition to PATH, so tools installed by Homebrew or in sbin are found
    /// even when bibi is started from a GUI context with a minimal PATH.
    static let extraPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/libexec"]

    public static func which(_ name: String) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in path + extraPath where FileManager.default.isExecutableFile(atPath: dir + "/" + name) {
            return dir + "/" + name
        }
        return nil
    }

    public static func run(_ argv: [String], timeout: Double = 30, input: String? = nil,
                           environment: [String: String] = [:]) async -> CommandOutput {
        guard let exe = which(argv[0]) else {
            return CommandOutput(argv: argv, status: 127, stdout: "", stderr: "\(argv[0]): not found")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = Array(argv.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        env["PATH"] = ((env["PATH"].map { [$0] } ?? []) + extraPath).joined(separator: ":")
        env.merge(environment) { $1 }
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        let inPipe = Pipe()
        proc.standardInput = input == nil ? FileHandle.nullDevice : inPipe

        // Drain both pipes on background threads so a chatty command can't fill a pipe buffer and block.
        let outData = Drain(out.fileHandleForReading), errData = Drain(err.fileHandleForReading)
        return await withCheckedContinuation { cont in
            let state = TimeoutState()
            proc.terminationHandler = { p in
                let o = outData.wait(), e = errData.wait()
                cont.resume(returning: CommandOutput(
                    argv: argv, status: p.terminationStatus,
                    stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self),
                    timedOut: state.fired))
            }
            do {
                try proc.run()
            } catch {
                proc.terminationHandler = nil
                cont.resume(returning: CommandOutput(argv: argv, status: 126, stdout: "", stderr: "\(error)"))
                return
            }
            if let input {
                inPipe.fileHandleForWriting.write(Data(input.utf8))
                try? inPipe.fileHandleForWriting.close()
            }
            let pid = proc.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard proc.isRunning else { return }
                state.fire()
                kill(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if proc.isRunning { kill(pid, SIGKILL) } }
            }
        }
    }

    /// Streams stdout line by line (for long-running commands like `du` where progress matters).
    public static func lines(_ argv: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            guard let exe = which(argv[0]) else {
                cont.finish(throwing: CommandError.notFound(argv[0]))
                return
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: exe)
            proc.arguments = Array(argv.dropFirst())
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = FileHandle.nullDevice
            proc.standardInput = FileHandle.nullDevice
            do { try proc.run() } catch {
                cont.finish(throwing: error)
                return
            }
            cont.onTermination = { _ in if proc.isRunning { proc.terminate() } }
            Thread.detachNewThread {
                var buffer = Data()
                let handle = out.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        cont.yield(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
                        buffer.removeSubrange(buffer.startIndex...nl)
                    }
                }
                if !buffer.isEmpty { cont.yield(String(decoding: buffer, as: UTF8.self)) }
                proc.waitUntilExit()
                cont.finish()
            }
        }
    }
}

public enum CommandError: Error, CustomStringConvertible {
    case notFound(String)
    case failed(String)
    public var description: String {
        switch self {
        case .notFound(let n): "\(n): command not found"
        case .failed(let m): m
        }
    }
}

extension CommandOutput {
    /// Throws with stderr (or stdout) when the command failed.
    @discardableResult
    public func check() throws -> CommandOutput {
        if ok { return self }
        let msg = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        throw CommandError.failed(timedOut ? "\(argv[0]) timed out" : String(msg.prefix(300)).ifEmpty("exit \(status)"))
    }
}

extension String {
    public func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

private final class Drain: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)
    init(_ handle: FileHandle) {
        Thread.detachNewThread { [self] in
            data = handle.readDataToEndOfFile()
            done.signal()
        }
    }
    func wait() -> Data {
        done.wait()
        return data
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var _fired = false
    var fired: Bool { lock.withLock { _fired } }
    func fire() { lock.withLock { _fired = true } }
}

public enum Shell {
    /// Single-quote for a POSIX shell.
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func quoteIfNeeded(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=,@%+")
        return !s.isEmpty && s.unicodeScalars.allSatisfy(safe.contains) ? s : quote(s)
    }

    public static func join(_ argv: [String]) -> String { argv.map(quoteIfNeeded).joined(separator: " ") }
}
