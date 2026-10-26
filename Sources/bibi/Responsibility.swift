import Darwin
import Foundation

/// macOS charges privacy permissions (Contacts, Calendars, Reminders, Automation) to the "responsible" app: the
/// terminal or editor bibi was started from. That app's Info.plist usually has no Contacts or Calendars text, so
/// macOS refuses without asking. Relaunching with responsibility disclaimed makes bibi its own responsible process:
/// macOS asks for bibi, with the texts in bibi's embedded Info.plist, and remembers the answer for bibi.
nonisolated(unsafe) private var child: pid_t = 0

enum Responsibility {
    static let marker = "BIBI_DISCLAIMED"

    typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    /// Runs this command again as its own responsible process and returns its exit code, or nil if that isn't
    /// possible (already relaunched, or the system call is missing), in which case the caller just carries on.
    static func relaunch() -> Int32? {
        guard ProcessInfo.processInfo.environment[marker] == nil,
              let sym = dlsym(dlopen(nil, RTLD_NOW), "responsibility_spawnattrs_setdisclaim") else { return nil }
        let disclaim = unsafeBitCast(sym, to: Disclaim.self)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        guard disclaim(&attr, 1) == 0 else { return nil }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let args: [String] = [exe] + CommandLine.arguments.dropFirst()
        let vars: [String] = ProcessInfo.processInfo.environment.map { "\($0)=\($1)" } + ["\(marker)=1"]
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        let env: [UnsafeMutablePointer<CChar>?] = vars.map { strdup($0) } + [nil]
        defer { (argv + env).forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, exe, nil, &attr, argv, env) == 0 else { return nil }
        child = pid
        // Ctrl-C reaches both processes (same process group): the child handles it, the parent waits.
        // A kill or a closed terminal aimed at the parent is passed on.
        signal(SIGINT, SIG_IGN)
        for sig in [SIGTERM, SIGHUP] { signal(sig) { kill(child, $0) } }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let low = status & 0x7f
        return low == 0 ? (status >> 8) & 0xff : 128 + low
    }
}
