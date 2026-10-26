import BibiCore
import Foundation

/// net.identify: figure out what a device on the network is, from a MAC, IP or name.
public struct NetIdentify: Skill {
    public init() {}
    public let name = "net.identify"
    public let help = "Identify a network device from a MAC address, IP address or hostname"
    public var aliases: [String] { ["net-identify"] }
    public var usesWeb: Bool { true }
    public var onlineByDefault: Bool { true }
    public var params: [Param] {
        [
            .positional("target", help: "MAC (00:dd:1f:e2:aa:44), IP (10.0.0.42) or hostname (printer.local)"),
            .flag("offline", "--offline", help: "no internet lookups (vendor, web search)"),
            .flag("no_sweep", "--no-sweep", help: "don't ping the local subnet to find an unknown MAC"),
            .flag("deep", "--deep", help: "scan TCP ports 1-10000 instead of ~75 common ones (slower)"),
        ]
    }

    static let schema = Schema("Identification", [
        .init("device_type", .string, "e.g. printer, phone, NAS, Linux server VM, router, IP camera"),
        .init("operating_system", .string, "e.g. Ubuntu Linux, Windows, iOS, embedded firmware, or unknown"),
        .init("vendor", .string),
        .init("model_guess", .string, "specific model if the evidence shows it, else 'unknown'"),
        .init("confidence", .int(0...100)),
        .init("reasoning", .string, "two sentences citing the evidence"),
        .init("next_steps", .array(.string, max: 3), "up to 3 ways to confirm"),
    ])

    static let instructions = """
    You identify devices on a home or office network from technical evidence.
    The "Detected" line comes from reliable rules (service banners, web pages, MAC prefixes): treat it as fact and
    build on it. Then weigh service greetings and web titles, hostname hints, the MAC vendor, open ports and the TTL.
    A VM platform MAC means a virtual machine; an SSH greeting usually names the Linux distribution.
    Ports 9100/631 mean a printer unless a banner says otherwise; 62078 an iPhone/iPad; 8008/8009 Google Cast;
    7000 AirPlay; 554 a camera. A randomized MAC usually means a phone, tablet or laptop with MAC privacy enabled.
    If evidence is thin, say so and keep confidence low. Never invent model numbers.
    """

    struct Identification: Decodable {
        var device_type: String
        var operating_system: String
        var vendor: String
        var model_guess: String
        var confidence: Int
        var reasoning: String
        var next_steps: [String]
    }

    struct DeviceEvidence {
        var query: String
        var mac: String?
        var ip: String?
        var names: [(String, String)] = []  // (source, name), in discovery order
        var vendor: String?
        var vm: String?
        var randomized = false
        var ttl: Int?
        var ports: [Int] = []
        var services: [Int: String] = [:]
        var web: [Int: String] = [:]
        var detected: [String] = []
        var search: [String] = []
        var problems: [String] = []

        var hints: [String] { Probe.nameHints(names.map(\.1)) }

        /// The prompt, one fact per line. Each line also becomes an observation.
        func lines() -> [(source: String, text: String)] {
            var l: [(String, String)] = [("query", "Looked up: \(query)")]
            l.append(("arp -an", "MAC: \(mac ?? "unknown")" + (randomized ? " (randomized/private address)" : "")))
            l.append(("lookup", "IP: \(ip ?? "unknown")"))
            l.append(("api.macvendors.com", "MAC vendor: \(vendor ?? "unknown")" + (vm.map { " (virtualization: \($0))" } ?? "")))
            if let os = Probe.osFromTTL(ttl) { l.append(("ping", "Ping TTL: \(ttl!), typical of \(os)")) }
            for (source, name) in names { l.append((source, "Name (\(source)): \(name)")) }
            if !ports.isEmpty {
                l.append(("tcp connect scan", "Open ports: " + ports.prefix(25).map { "\($0) (\(Probe.ports[$0] ?? "unknown service"))" }.joined(separator: ", ")))
            } else if ip != nil {
                l.append(("tcp connect scan", "Open ports: none found"))
            }
            for port in services.keys.sorted().prefix(15) { l.append(("port \(port) banner", "Port \(port): \(services[port]!)")) }
            if !detected.isEmpty { l.append(("bibi signature rules", "Detected: " + detected.joined(separator: ", "))) }
            if !hints.isEmpty { l.append(("bibi name rules", "Hints: " + hints.joined(separator: ", "))) }
            for s in search { l.append(("duckduckgo", "Web result: \(s)")) }
            return l
        }
    }

    public func run(_ args: Args, _ ctx: SkillContext) async throws -> SkillResult {
        let ui = ctx.reporter
        let online = ctx.online && !args.flag("offline")
        var ev = DeviceEvidence(query: args.string("target") ?? "")
        await locate(&ev, args: args, ui: ui)
        if ev.ip != nil { await probeHost(&ev, ui: ui, deep: args.flag("deep")) }
        if let mac = ev.mac {
            ev.vm = Probe.vmPlatform(mac)
            ev.randomized = Probe.isRandomized(mac) && ev.vm == nil
            if let vm = ev.vm { ev.detected.insert("virtual machine (\(vm))", at: 0) }
            if !ev.randomized && ev.vm == nil && online {
                ui.progress("Looking up MAC vendor...")
                ev.vendor = await Probe.macVendor(mac, fetcher: ctx.fetcher)
            }
        }
        if online, let vendor = ev.vendor {
            // Search with the vendor + generic findings only; never the user's own hostnames or addresses.
            let terms = [vendor] + ev.detected.prefix(3) + ev.hints.prefix(1)
            let query = terms.filter { !$0.isEmpty }.joined(separator: " ") + " network device"
            ui.progress("Searching the web: \(query)")
            ev.search = await WebSearch.search(query, fetcher: ctx.fetcher)
        }

        if ev.ip == nil && ev.vendor == nil {
            // Nothing but the query itself: a model guess would be pure invention.
            return SkillResult(summary: "Could not reach or look up \(ev.query); nothing to identify it from.", notes: ev.problems)
        }

        let evidence = Evidence()
        let lines = ev.lines()
        let ids = lines.map { evidence.observe($0.source, $0.text) }
        let report = lines.map(\.text).joined(separator: "\n")
        ui.heading("Evidence")
        ui.info(report)
        ui.progress("Asking fm to identify the device...")
        let facts = facts(ev)
        let r: Identification
        do {
            r = try await ctx.model.respond(report, instructions: Self.instructions, schema: Self.schema, as: Identification.self)
        } catch {
            return SkillResult(summary: "fm could not produce an identification: \(error)", observations: evidence.allObservations,
                               facts: facts, notes: ev.problems)
        }

        let model = r.model_guess.lowercased() == "unknown" || r.model_guess.isEmpty ? "" : " (\(r.model_guess))"
        let title = "Likely: \(r.device_type) by \(r.vendor)\(model)"
        var summary = ["", title, "OS: \(r.operating_system)", "Confidence: \(r.confidence)%", "Why: \(r.reasoning)"]
        if !r.next_steps.isEmpty { summary.append("To confirm: " + r.next_steps.prefix(3).joined(separator: "; ")) }
        evidence.find("network", title, severity: .info, cites: ids, confidence: max(0, min(100, r.confidence)),
                      explanation: r.reasoning + (r.next_steps.isEmpty ? "" : " To confirm: " + r.next_steps.prefix(3).joined(separator: "; ")),
                      subject: ["ip": ev.ip ?? ""], actions: webActions(ev))
        var f = evidence.allFindings[0]
        f.explainedBy = "model"
        return SkillResult(summary: summary.joined(separator: "\n"), observations: evidence.allObservations, findings: [f],
                           facts: facts, notes: ev.problems)
    }

    public func comparable(_ old: [String: JSONValue], _ new: [String: JSONValue]) -> Bool {
        old["target"] == new["target"]
    }

    func facts(_ ev: DeviceEvidence) -> [String: JSONValue] {
        var services: [String: JSONValue] = [:]
        for (port, banner) in ev.services { services[String(port)] = .string(banner) }
        return ["target": .string(ev.query), "ip": .string(ev.ip ?? ""), "mac": .string(ev.mac ?? ""),
                "ports": .strings(ev.ports.map(String.init)), "services": .object(services)]
    }

    func locate(_ ev: inout DeviceEvidence, args: Args, ui: any Reporter) async {
        let target = ev.query.trimmingCharacters(in: .whitespaces)
        if let mac = Probe.normalizeMAC(target) {
            ev.mac = mac
            let table = await Probe.arpTable()
            if table.isEmpty {
                ev.problems.append("the ARP table came back empty: macOS hides it from apps without Local Network access. Allow the app that runs bibi (Terminal, iTerm, VS Code) under System Settings > Privacy & Security > Local Network, or look the device up by IP")
            }
            ev.ip = table[mac]
            if ev.ip == nil && !args.flag("no_sweep"), let net = await Probe.localNetwork() {
                ui.progress("MAC not in ARP cache; pinging \(net.label) to find it...")
                await Probe.sweep(net.hosts)
                ev.ip = await Probe.arpTable()[mac]
            }
            if ev.ip == nil { ev.problems.append("device not found on the local network (offline, asleep, or another subnet)") }
            return
        }
        if IPv4.isIP(target) {
            ev.ip = target
        } else {
            ev.names.append(("queried name", target))
            ev.ip = await Probe.resolve(target)
            if ev.ip == nil {
                ev.problems.append("could not resolve \(target)")
                return
            }
        }
        ui.progress("Pinging \(ev.ip!)...")
        ev.ttl = await Probe.ping(ev.ip!)
        let ip = ev.ip
        ev.mac = await Probe.arpTable().first { $0.value == ip }?.key
        if ev.ttl == nil && ev.mac == nil { ev.problems.append("\(ev.ip!) did not answer ping (it may still block ICMP)") }
    }

    func probeHost(_ ev: inout DeviceEvidence, ui: any Reporter, deep: Bool) async {
        let ip = ev.ip!
        if ev.ttl == nil { ev.ttl = await Probe.ping(ip) }
        ui.progress("Looking up names for \(ip)...")
        for (source, name) in [("reverse DNS", await Probe.reverseDNS(ip)), ("mDNS", await Probe.mdnsName(ip)),
                               ("NetBIOS", await Probe.netbiosName(ip))] {
            if let name, !ev.names.contains(where: { $0.1 == name }) { ev.names.append((source, name)) }
        }
        let ports = deep ? Array(Set(Probe.ports.keys).union(1...10000)).sorted() : nil
        ui.progress("Scanning \(deep ? "10,000" : String(Probe.ports.count)) TCP ports on \(ip)...")
        ev.ports = await Probe.openPorts(ip, ports, timeout: deep ? 0.4 : 0.6, batch: deep ? 128 : 64)
        ui.progress("Reading what answers on \(ev.ports.count) open port(s)...")
        let open = ev.ports
        let grabs = await withTaskGroup(of: (Int, (summary: String, raw: String, scheme: String?)?).self) { group in
            for port in open { group.addTask { (port, await Probe.grab(ip, port)) } }
            var out: [Int: (summary: String, raw: String, scheme: String?)] = [:]
            for await (port, g) in group { if let g { out[port] = g } }
            return out
        }
        var raw: [String] = []
        for port in open {
            guard let g = grabs[port] else { continue }
            ev.services[port] = g.summary
            raw.append(g.raw)
            if let scheme = g.scheme { ev.web[port] = scheme }
        }
        for d in Probe.signatures(raw) where !ev.detected.contains(d) { ev.detected.append(d) }
    }

    func webActions(_ ev: DeviceEvidence) -> [BoundAction] {
        var ports = ev.web.keys.sorted()
        if ports.contains(80) && ports.contains(443) { ports.removeAll { $0 == 80 } }  // same interface; prefer https
        return ports.map { port in
            let scheme = ev.web[port]!
            let isDefault = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
            let url = "\(scheme)://\(ev.ip!)" + (isDefault ? "" : ":\(port)")
            return BoundAction(ActionCall("open_url", ["url": url]), title: "Open web interface \(url)", kind: "open", target: url,
                               safety: 10, confidence: 10, reason: ev.services[port] ?? "web page", command: "open \(url)")
        }
    }
}
