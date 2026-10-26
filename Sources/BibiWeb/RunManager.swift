import BibiCore
import Foundation

/// Runs started from the browser, keyed by history run id. Finished runs are loaded from history on demand.
public final class RunManager: Sendable {
    let harness: Harness
    private let hubs = Mutex<[String: EventHub]>([:])

    public init(harness: Harness) { self.harness = harness }

    public func hub(_ id: String) -> EventHub {
        hubs.withLock { h in
            if let hub = h[id] { return hub }
            let hub = EventHub()
            h[id] = hub
            return hub
        }
    }

    /// Starts a skill in the background and returns its run id as soon as the run exists.
    public func start(_ skill: any Skill, argv: [String], online: Bool?, since: String?, verbose: Bool) async throws -> String {
        // Validate arguments up front so the browser gets a 400 instead of a failed run.
        _ = try Args.parse(argv, params: skill.params)
        let created = AsyncStream<Result<String, Error>>.makeStream()
        let harness = self.harness
        Task {
            let reporter = ForwardingReporter()
            do {
                let (record, result) = try await harness.run(skill, argv: argv, reporter: reporter,
                                                             options: RunOptions(online: online, verbose: verbose, since: since),
                                                             onCreate: { record in
                    let h = self.hub(record.id)
                    _ = h.begin("run")
                    reporter.attach(h, verbose: verbose)
                    created.continuation.yield(.success(record.id))
                })
                let hub = self.hub(record.id)
                hub.emit("ok", result.summary, phase: "run")
                hub.emit("done", "finished", phase: "run")
            } catch {
                if let h = reporter.attached {
                    h.emit("error", "\(error)", phase: "run")
                    h.emit("done", "failed", phase: "run")
                } else {
                    created.continuation.yield(.failure(error))
                }
            }
            created.continuation.finish()
        }
        for await r in created.stream { return try r.get() }
        throw SkillError("the run did not start")
    }
}

/// Forwards to the run's hub once the run exists (the first lines are buffered until then).
final class ForwardingReporter: Reporter, @unchecked Sendable {
    private let lock = NSLock()
    private var hub: EventHub?
    private var verbose = false
    private var buffered: [(String, String)] = []

    var attached: EventHub? { lock.withLock { hub } }

    func attach(_ h: EventHub, verbose: Bool) {
        let backlog = lock.withLock { () -> [(String, String)] in
            hub = h
            self.verbose = verbose
            defer { buffered = [] }
            return buffered
        }
        for (t, m) in backlog { h.emit(t, m, phase: "run") }
    }

    private func send(_ type: String, _ m: String) {
        let h = lock.withLock { () -> EventHub? in
            if hub == nil { buffered.append((type, m)) }
            return hub
        }
        h?.emit(type, m, phase: "run")
    }

    func progress(_ m: String) { send("progress", m) }
    func info(_ m: String) { send("info", m) }
    func debug(_ m: String) { if lock.withLock({ verbose }) { send("debug", m) } }
    func ok(_ m: String) { send("ok", m) }
    func error(_ m: String) { send("error", m) }
    func heading(_ m: String) { send("heading", m) }
}
