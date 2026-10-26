import BibiCore
import Foundation

/// Terminal output with a stderr spinner. The only place that writes to the terminal.
final class TerminalReporter: Reporter, @unchecked Sendable {
    let verbose: Bool
    let color: Bool
    private let lock = NSLock()
    private var message: String?
    private var started = Date()
    private var shown = false
    private var spinner: Thread?

    init(verbose: Bool) {
        self.verbose = verbose
        color = isatty(1) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }

    func c(_ code: String, _ s: String) -> String { color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }

    private func clear() {
        if shown {
            FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
            shown = false
        }
    }

    private func spin() {
        let frames = Array("|/-\\")
        var i = 0
        while true {
            lock.withLock {
                if let msg = message {
                    var ws = winsize()
                    let width = ioctl(2, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 ? Int(ws.ws_col) - 1 : 79
                    let line = "\(frames[i % 4]) \(msg)  (\(Int(Date().timeIntervalSince(started)))s)"
                    FileHandle.standardError.write(Data(("\r\u{1B}[K" + String(line.prefix(width))).utf8))
                    shown = true
                }
            }
            i += 1
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func progress(_ msg: String) {
        guard isatty(2) == 1 else { return }
        lock.withLock {
            if message == nil { started = Date() }
            message = msg
            if spinner == nil {
                let t = Thread { [weak self] in self?.spin() }
                spinner = t
                t.start()
            }
        }
    }

    func stopProgress() { lock.withLock { message = nil; clear() } }

    private func emit(_ s: String, endProgress: Bool = true) {
        lock.withLock {
            if endProgress { message = nil }
            clear()
            print(s)
            fflush(stdout)
        }
    }

    func info(_ s: String) { emit(s) }
    func debug(_ s: String) { if verbose { emit(c("2", s), endProgress: false) } }
    func ok(_ s: String) { emit(c("32", s)) }
    func error(_ s: String) { emit(c("31", s)) }
    func heading(_ s: String) { emit("\n" + c("1", s)) }

    func ask(_ prompt: String) -> String {
        stopProgress()
        print(c("36", prompt), terminator: "")
        fflush(stdout)
        return readLine() ?? ""
    }
}
