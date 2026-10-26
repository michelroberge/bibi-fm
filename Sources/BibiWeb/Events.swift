import BibiCore
import Foundation

/// One line of progress for the browser.
public struct WebEvent: Codable, Sendable {
    public var seq: Int
    public var type: String  // progress, info, debug, ok, error, heading, done
    public var text: String
    public var phase: String?  // run, execute, undo
}

/// Buffers every event of a run (so a page that connects late replays them) and fans them out to subscribers.
public final class EventHub: Sendable {
    struct State {
        var events: [WebEvent] = []
        var subscribers: [UUID: AsyncStream<WebEvent>.Continuation] = [:]
        var busy: String?  // phase in progress
    }
    private let state = Mutex(State())

    public init() {}

    public func emit(_ type: String, _ text: String, phase: String? = nil) {
        let (event, subs) = state.withLock { s -> (WebEvent, [AsyncStream<WebEvent>.Continuation]) in
            // Consecutive progress lines replace each other; keep the buffer from growing without bound.
            if type == "progress", let last = s.events.last, last.type == "progress" { s.events.removeLast() }
            let e = WebEvent(seq: (s.events.last?.seq ?? 0) + 1, type: type, text: text, phase: phase)
            s.events.append(e)
            if type == "done" { s.busy = nil }
            return (e, Array(s.subscribers.values))
        }
        for c in subs { c.yield(event) }
    }

    /// Marks a phase as running; false if another one is (one operation per run at a time).
    public func begin(_ phase: String) -> Bool {
        state.withLock { s in
            guard s.busy == nil else { return false }
            s.busy = phase
            return true
        }
    }

    public var busy: String? { state.withLock { $0.busy } }

    /// Events after `from`, then live ones.
    public func subscribe(from: Int) -> AsyncStream<WebEvent> {
        let id = UUID()
        return AsyncStream { cont in
            let backlog = state.withLock { s -> [WebEvent] in
                s.subscribers[id] = cont
                return s.events.filter { $0.seq > from }
            }
            for e in backlog { cont.yield(e) }
            cont.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) } }
        }
    }
}

/// Sends skill output to the browser instead of the terminal.
public struct WebReporter: Reporter {
    let hub: EventHub
    let phase: String
    let verbose: Bool

    public func progress(_ m: String) { hub.emit("progress", m, phase: phase) }
    public func info(_ m: String) { hub.emit("info", m, phase: phase) }
    public func debug(_ m: String) { if verbose { hub.emit("debug", m, phase: phase) } }
    public func ok(_ m: String) { hub.emit("ok", m, phase: phase) }
    public func error(_ m: String) { hub.emit("error", m, phase: phase) }
    public func heading(_ m: String) { hub.emit("heading", m, phase: phase) }
}
