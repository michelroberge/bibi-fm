import BibiCore
import Foundation

/// Evidence gathering for network devices: local lookups first, internet lookups only when allowed.
public enum Probe {
    public static let ports: [Int: String] = [
        21: "FTP",
        22: "SSH",
        23: "Telnet (often old embedded devices)",
        25: "SMTP mail",
        53: "DNS (router, Pi-hole)",
        80: "HTTP",
        110: "POP3 mail",
        111: "rpcbind (Linux/Unix, NFS)",
        139: "NetBIOS (Windows/Samba)",
        143: "IMAP mail",
        443: "HTTPS",
        445: "SMB file sharing (Windows, Samba, NAS)",
        548: "AFP (Mac, NAS)",
        554: "RTSP video stream (IP camera, NVR)",
        631: "IPP printing (printer, CUPS)",
        873: "rsync (NAS, Linux)",
        1400: "Sonos speaker",
        1880: "Node-RED",
        1883: "MQTT (IoT hub)",
        2049: "NFS file sharing",
        2375: "Docker Engine API (unencrypted)",
        2376: "Docker Engine API (TLS)",
        3000: "web app (Grafana, dev server)",
        3001: "web app (Uptime Kuma)",
        3306: "MySQL/MariaDB",
        3389: "Remote Desktop (Windows)",
        4000: "web app",
        5000: "web app (Synology DSM, Docker registry, Flask, AirPlay)",
        5001: "Synology DSM (HTTPS)",
        5432: "PostgreSQL",
        5601: "Kibana",
        5900: "VNC / Screen Sharing",
        5985: "WinRM (Windows)",
        6379: "Redis",
        6443: "Kubernetes API",
        7000: "AirPlay (Apple TV, HomePod, AirPlay speaker)",
        7474: "Neo4j",
        8000: "web app",
        8006: "Proxmox VE web UI",
        8008: "Google Cast or web app",
        8009: "Google Cast",
        8080: "web app / proxy",
        8081: "web app",
        8086: "InfluxDB",
        8088: "web app",
        8096: "Jellyfin/Emby",
        8123: "Home Assistant",
        8200: "Vault",
        8443: "HTTPS (alternate)",
        8888: "web app (Jupyter)",
        9000: "web app (Portainer, MinIO, SonarQube)",
        9090: "Cockpit or Prometheus",
        9091: "Transmission",
        9093: "Alertmanager",
        9100: "printer (JetDirect) or Prometheus node_exporter",
        9200: "Elasticsearch",
        9443: "Portainer (HTTPS)",
        10000: "Webmin",
        10250: "Kubernetes kubelet",
        11434: "Ollama",
        27017: "MongoDB",
        32400: "Plex Media Server",
        49152: "UPnP device",
        62078: "Apple iPhone/iPad sync service",
    ]

    public static let nameHintRules: [(String, String)] = [
        ("^BRN|^BRW", "Brother printer"),
        ("^NPI|^HP[0-9A-F]{6}", "HP printer"),
        ("EPSON", "Epson printer"),
        ("Canon", "Canon printer"),
        ("iPhone", "iPhone"),
        ("iPad", "iPad"),
        ("MacBook|iMac|Mac-?mini|Mac-?Studio", "Mac"),
        ("Apple-?TV", "Apple TV"),
        ("HomePod", "HomePod"),
        ("Galaxy|SM-[A-Z]\\d", "Samsung phone/tablet"),
        ("android", "Android device"),
        ("^ESP[_-]|esp32|esp8266", "ESP8266/ESP32 IoT module"),
        ("raspberrypi", "Raspberry Pi"),
        ("^DESKTOP-|^LAPTOP-|^WIN-", "Windows PC"),
        ("Chromecast", "Chromecast"),
        ("Roku", "Roku"),
        ("Sonos", "Sonos speaker"),
        ("tapo|kasa|^TL-|tplink", "TP-Link device"),
        ("shelly", "Shelly smart relay"),
        ("DiskStation|synology", "Synology NAS"),
        ("unifi|^U[67]", "Ubiquiti UniFi device"),
        ("^ring-|Ring", "Ring doorbell/camera"),
        ("nest|google-home", "Google Nest device"),
        ("Echo|amazon", "Amazon Echo/Fire device"),
        ("PS[45]|PlayStation", "PlayStation"),
        ("XBOX", "Xbox"),
        ("Nintendo|Switch", "Nintendo Switch"),
        ("docker", "Docker host"),
        ("ci-?cd|jenkins|runner|gitlab|build", "CI/CD build server"),
        ("k8s|kube|k3s", "Kubernetes node"),
        ("proxmox|^pve", "Proxmox hypervisor"),
        ("\\bvm\\b|-vm\\d*$|^vm-", "virtual machine"),
        ("ubuntu", "Ubuntu Linux"),
        ("debian", "Debian Linux"),
        ("\\bnas\\b|-nas", "NAS"),
    ]

    /// Rule-based product/OS signatures, matched against service banners, HTTP headers and page bodies.
    public static let signatureRules: [(String, String)] = [
        ("cockpit", "Cockpit web console (Linux server admin)"),
        ("ubuntu", "Ubuntu Linux"),
        ("debian|deb\\d+u\\d", "Debian Linux"),
        ("raspbian", "Raspberry Pi OS"),
        ("\\.el[789]|red ?hat|centos|rocky linux|almalinux|fedora", "Red Hat family Linux"),
        ("alpine", "Alpine Linux"),
        ("freebsd", "FreeBSD"),
        ("OpenSSH_for_Windows|Microsoft-IIS|Microsoft-HTTPAPI", "Windows"),
        ("openwrt|luci", "OpenWrt router"),
        ("portainer", "Portainer (Docker management)"),
        ("grafana", "Grafana"),
        ("proxmox|pve-api", "Proxmox VE hypervisor"),
        ("synology|diskstation", "Synology NAS"),
        ("\\bqnap\\b|\\bQTS\\b", "QNAP NAS"),
        ("truenas|freenas", "TrueNAS"),
        ("unifi|ubiquiti", "Ubiquiti UniFi"),
        ("home assistant", "Home Assistant"),
        ("jellyfin", "Jellyfin"),
        ("\\bplex\\b", "Plex"),
        ("pi-hole", "Pi-hole"),
        ("jenkins", "Jenkins CI"),
        ("gitlab", "GitLab"),
        ("gitea|forgejo", "Gitea/Forgejo"),
        ("nextcloud", "Nextcloud"),
        ("webmin", "Webmin"),
        ("docker-distribution-api|registry/2\\.0", "Docker registry"),
        ("Server: Docker/", "Docker Engine API"),
        ("minio", "MinIO"),
        ("kubernetes|\\bk3s\\b", "Kubernetes"),
        ("node_exporter|go_gc_duration", "Prometheus node_exporter"),
        ("prometheus", "Prometheus"),
        ("traefik", "Traefik proxy"),
        ("uptime kuma", "Uptime Kuma"),
        ("ollama", "Ollama"),
        ("brother", "Brother printer"),
        ("HP (LaserJet|OfficeJet|ENVY|Color)", "HP printer"),
        ("\\bCUPS\\b", "CUPS print server"),
        ("xfinity|docsis", "cable modem / gateway"),
        ("nginx", "nginx"),
        ("apache", "Apache httpd"),
    ]

    /// MAC prefixes of virtualization platforms (many are missing from public OUI lookups).
    public static let vmOUIs: [String: String] = [
        "00:50:56": "VMware",
        "00:0c:29": "VMware",
        "00:05:69": "VMware",
        "08:00:27": "VirtualBox",
        "52:54:00": "QEMU/KVM",
        "bc:24:11": "Proxmox VE (QEMU/KVM)",
        "00:1c:42": "Parallels",
        "00:15:5d": "Hyper-V",
        "02:42:ac": "Docker container",
        "00:16:3e": "Xen",
    ]

    // MARK: parsing

    /// "00-DD-1F-E2-AA-44", "0:dd:1f:e2:aa:44" or "00dd.1fe2.aa44" -> "00:dd:1f:e2:aa:44".
    public static func normalizeMAC(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if Re.test("^[0-9a-f]{1,2}([:-][0-9a-f]{1,2}){5}$", t) {
            return t.split(whereSeparator: { $0 == ":" || $0 == "-" })
                .map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":")
        }
        let digits = t.filter { !".:-".contains($0) }
        if Re.test("^[0-9a-f]{12}$", digits) {
            let chars = Array(digits)
            return stride(from: 0, to: 12, by: 2).map { String(chars[$0..<$0 + 2]) }.joined(separator: ":")
        }
        return nil
    }

    /// Locally administered bit set: a private/random MAC (phones, tablets, laptops with privacy on).
    public static func isRandomized(_ mac: String) -> Bool {
        (Int(mac.prefix(2), radix: 16) ?? 0) & 0x02 != 0
    }

    public static func vmPlatform(_ mac: String) -> String? { vmOUIs[String(mac.prefix(8))] }

    public static func nameHints(_ names: [String?]) -> [String] {
        var found: [String] = []
        for name in names.compactMap({ $0 }) {
            for (pattern, hint) in nameHintRules where Re.test(pattern, name, ci: true) && !found.contains(hint) {
                found.append(hint)
            }
        }
        return found
    }

    public static func signatures(_ texts: [String?]) -> [String] {
        var found: [String] = []
        for text in texts.compactMap({ $0 }) {
            for (pattern, label) in signatureRules where Re.test(pattern, text, ci: true) && !found.contains(label) {
                found.append(label)
            }
        }
        return found
    }

    public static func osFromTTL(_ ttl: Int?) -> String? {
        guard let ttl, ttl > 0 else { return nil }
        if ttl <= 64 { return "Linux, macOS, BSD or embedded (TTL 64)" }
        if ttl <= 128 { return "Windows (TTL 128)" }
        return "network equipment such as a router or switch (TTL 255)"
    }

    // MARK: local lookups

    static func out(_ argv: [String], timeout: Double = 5) async -> String {
        await Command.run(argv, timeout: timeout).stdout
    }

    /// mac -> ip from the system ARP cache.
    public static func arpTable() async -> [String: String] {
        parseARP(await out(["arp", "-an"]))
    }

    public static func parseARP(_ text: String) -> [String: String] {
        var table: [String: String] = [:]
        for m in Re.all("\\(([\\d.]+)\\) at ([0-9a-f:]+)", text) {
            if let mac = normalizeMAC(m[2]) { table[mac] = m[1] }
        }
        return table
    }

    /// TTL of the reply, or nil if the host didn't answer.
    public static func ping(_ ip: String, timeout: Int = 1) async -> Int? {
        Re.first("ttl=(\\d+)", await out(["ping", "-c", "1", "-t", String(timeout), ip], timeout: Double(timeout) + 2)).flatMap { Int($0[1]) }
    }

    /// Hosts of the default interface's subnet, capped at /24 around our own address.
    public static func localNetwork() async -> (label: String, hosts: [String])? {
        guard let iface = Re.first("interface: (\\S+)", await out(["route", "-n", "get", "default"]))?[1] else { return nil }
        let ip = await out(["ipconfig", "getifaddr", iface]).trimmingCharacters(in: .whitespacesAndNewlines)
        let mask = await out(["ipconfig", "getoption", iface, "subnet_mask"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let addr = IPv4.parse(ip) else { return nil }
        let prefix = max(24, IPv4.prefixLength(mask: mask.isEmpty ? "255.255.255.0" : mask) ?? 24)
        let size = UInt32(1) << UInt32(32 - prefix)
        let base = addr & ~(size - 1)
        let hosts = size <= 2 ? [] : (1..<size - 1).map { IPv4.format(base + $0) }
        return ("\(IPv4.format(base))/\(prefix)", hosts)
    }

    /// Pings every host once so the ARP cache fills up.
    public static func sweep(_ hosts: [String], workers: Int = 64) async {
        await withTaskGroup(of: Void.self) { group in
            var it = hosts.makeIterator(), running = 0
            while running < workers, let h = it.next() {
                group.addTask { _ = await ping(h) }
                running += 1
            }
            for await _ in group {
                if let h = it.next() { group.addTask { _ = await ping(h) } }
            }
        }
    }

    /// DNS first, then mDNS (.local) for bare hostnames.
    public static func resolve(_ name: String) async -> String? {
        let candidates = [name] + (name.contains(".") ? [] : [name + ".local"])
        return await Task.detached {
            for c in candidates {
                var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                     ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(c, nil, &hints, &res) == 0, let r = res else { continue }
                defer { freeaddrinfo(res) }
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(r.pointee.ai_addr, r.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: buf)
                }
            }
            return nil
        }.value
    }

    public static func reverseDNS(_ ip: String) async -> String? {
        let lookup = Task.detached { () -> String? in
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &buf, socklen_t(buf.count), nil, 0, NI_NAMEREQD)
                }
            }
            return rc == 0 ? String(cString: buf) : nil
        }
        return await withTaskGroup(of: String??.self) { group in
            group.addTask { .some(await lookup.value) }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return .none }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    public static func mdnsName(_ ip: String) async -> String? {
        let o = await out(["dig", "+short", "+time=1", "+tries=1", "-x", ip, "@224.0.0.251", "-p", "5353"], timeout: 4)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.isEmpty, !o.hasPrefix(";"), let line = o.split(separator: "\n").first else { return nil }
        return line.hasSuffix(".") ? String(line.dropLast()) : String(line)
    }

    public static func netbiosName(_ ip: String) async -> String? {
        Re.first("Server:\\s*(\\S+)", await out(["smbutil", "status", "-ae", ip], timeout: 4))?[1]
    }

    /// Non-blocking connects in batches, checked with poll(); far cheaper than a thread per port.
    public static func openPorts(_ ip: String, _ ports: [Int]? = nil, timeout: Double = 0.6, batch: Int = 64) async -> [Int] {
        let list = ports ?? Array(Self.ports.keys).sorted()
        return await Task.detached {
            var open: [Int] = []
            for start in stride(from: 0, to: list.count, by: batch) {
                open += scanBatch(ip, Array(list[start..<min(start + batch, list.count)]), timeout: timeout)
            }
            return open.sorted()
        }.value
    }

    static func address(_ ip: String, _ port: Int) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        return inet_pton(AF_INET, ip, &addr.sin_addr) == 1 ? addr : nil
    }

    /// Starts a non-blocking connect; returns the fd (or nil) and whether it connected immediately.
    static func startConnect(_ ip: String, _ port: Int) -> (Int32, Bool)? {
        guard var addr = address(ip, port) else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc == 0 { return (fd, true) }
        if errno == EINPROGRESS { return (fd, false) }
        close(fd)
        return nil
    }

    static func socketError(_ fd: Int32) -> Int32 {
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err
    }

    static func scanBatch(_ ip: String, _ ports: [Int], timeout: Double) -> [Int] {
        var open: [Int] = []
        var pending: [(fd: Int32, port: Int)] = []
        for port in ports {
            guard let (fd, done) = startConnect(ip, port) else { continue }
            if done { open.append(port); close(fd) } else { pending.append((fd, port)) }
        }
        var pfds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
        let deadline = Date().addingTimeInterval(timeout)
        var left = pfds.count
        while left > 0 {
            let ms = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            if ms <= 0 { break }
            let n = poll(&pfds, nfds_t(pfds.count), ms)
            if n <= 0 { break }
            for i in pfds.indices where pfds[i].fd >= 0 && pfds[i].revents != 0 {
                if socketError(pfds[i].fd) == 0 { open.append(pending[i].port) }
                pfds[i].fd = -1
                left -= 1
            }
        }
        for p in pending { close(p.fd) }
        return open
    }

    /// Connects (with timeout) and waits briefly for a greeting. nil = couldn't connect.
    static func greeting(_ ip: String, _ port: Int) -> Data? {
        guard let (fd, done) = startConnect(ip, port) else { return nil }
        defer { close(fd) }
        if !done {
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&p, 1, 2000) == 1, socketError(fd) == 0 else { return nil }
        }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 1500) == 1 else { return Data() }
        var buf = [UInt8](repeating: 0, count: 512)
        let n = recv(fd, &buf, 512, 0)
        return n > 0 ? Data(buf[0..<n]) : Data()
    }

    static func printable(_ data: Data) -> String {
        let s = String(data.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : " " })
        return Re.replace("\\s+", s, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// LAN services use self-signed certificates; accept them for reading titles only.
    final class Insecure: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            if let trust = challenge.protectionSpace.serverTrust { return (.useCredential, URLCredential(trust: trust)) }
            return (.performDefaultHandling, nil)
        }
    }

    static let lanSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.timeoutIntervalForResource = 4
        return URLSession(configuration: c, delegate: Insecure(), delegateQueue: nil)
    }()

    /// (summary, raw text for signature matching) for an HTTP(S) service, or nil if it doesn't speak it.
    static func httpInfo(_ ip: String, _ port: Int, _ scheme: String) async -> (String, String)? {
        guard let url = URL(string: "\(scheme)://\(ip):\(port)/") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh) bibi/\(Bibi.version)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await lanSession.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
        let body = String(decoding: data.prefix(30000), as: UTF8.self)
        var parts = ["\(scheme.uppercased()) \(http.statusCode)"]
        if let server = http.value(forHTTPHeaderField: "Server") { parts.append("Server: \(server)") }
        if let powered = http.value(forHTTPHeaderField: "X-Powered-By") { parts.append("X-Powered-By: \(powered)") }
        if let title = Re.first("<title[^>]*>(.*?)</title>", body, ci: true)?[1].trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            parts.append("title: \(HTML.unescape(title).prefix(80))")
        }
        let headers = http.allHeaderFields.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        return (parts.joined(separator: "; "), headers + "\n" + body)
    }

    /// What answers on a port: (summary, raw text, web scheme or nil).
    /// Many protocols greet first (SSH, FTP, SMTP, MySQL); otherwise try HTTP, then HTTPS.
    public static func grab(_ ip: String, _ port: Int) async -> (summary: String, raw: String, scheme: String?)? {
        guard let hello = await Task.detached(operation: { greeting(ip, port) }).value else { return nil }
        if !hello.isEmpty {
            let text = String(printable(hello).prefix(160))
            return ("greeting: \(text)", text, nil)
        }
        let order = [443, 5001, 8006, 8443, 9090, 9443].contains(port) ? ["https", "http"] : ["http", "https"]
        for scheme in order {
            if let (summary, raw) = await httpInfo(ip, port, scheme) { return (summary, raw, scheme) }
        }
        return nil
    }

    // MARK: internet lookups

    /// Vendor from the OUI. Only the first 3 bytes are sent, never the full MAC.
    public static func macVendor(_ mac: String, fetcher: Fetcher) async -> String? {
        let oui = String(mac.prefix(8))
        guard let data = try? await fetcher.get("https://api.macvendors.com/" + oui, timeout: 5) else { return nil }
        let v = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}
