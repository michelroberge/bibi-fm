import Foundation

/// Where a skill reports progress. The terminal and the web UI each implement it,
/// so skills never know which front end they run under.
public protocol Reporter: Sendable {
    /// Transient status shown next to a spinner; replaced by the next call.
    func progress(_ message: String)
    func info(_ message: String)
    /// Shown only in verbose mode.
    func debug(_ message: String)
    func ok(_ message: String)
    func error(_ message: String)
    func heading(_ message: String)
}

/// Discards everything (tests, background runs).
public struct SilentReporter: Reporter {
    public init() {}
    public func progress(_: String) {}
    public func info(_: String) {}
    public func debug(_: String) {}
    public func ok(_: String) {}
    public func error(_: String) {}
    public func heading(_: String) {}
}
