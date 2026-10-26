"""Evidence gathering for network devices: local lookups first, internet lookups only when allowed."""

from __future__ import annotations

import html
import ipaddress
import re
import socket
import ssl
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

PORTS: dict[int, str] = {
    21: "FTP", 22: "SSH", 23: "Telnet (often old embedded devices)", 25: "SMTP mail", 53: "DNS (router, Pi-hole)",
    80: "HTTP", 110: "POP3 mail", 111: "rpcbind (Linux/Unix, NFS)", 139: "NetBIOS (Windows/Samba)",
    143: "IMAP mail", 443: "HTTPS", 445: "SMB file sharing (Windows, Samba, NAS)", 548: "AFP (Mac, NAS)",
    554: "RTSP video stream (IP camera, NVR)", 631: "IPP printing (printer, CUPS)", 873: "rsync (NAS, Linux)",
    1400: "Sonos speaker", 1880: "Node-RED", 1883: "MQTT (IoT hub)", 2049: "NFS file sharing",
    2375: "Docker Engine API (unencrypted)", 2376: "Docker Engine API (TLS)", 3000: "web app (Grafana, dev server)",
    3001: "web app (Uptime Kuma)", 3306: "MySQL/MariaDB", 3389: "Remote Desktop (Windows)", 4000: "web app",
    5000: "web app (Synology DSM, Docker registry, Flask, AirPlay)", 5001: "Synology DSM (HTTPS)",
    5432: "PostgreSQL", 5601: "Kibana", 5900: "VNC / Screen Sharing", 5985: "WinRM (Windows)", 6379: "Redis",
    6443: "Kubernetes API", 7000: "AirPlay (Apple TV, HomePod, AirPlay speaker)", 7474: "Neo4j",
    8000: "web app", 8006: "Proxmox VE web UI", 8008: "Google Cast or web app", 8009: "Google Cast",
    8080: "web app / proxy", 8081: "web app", 8086: "InfluxDB", 8088: "web app", 8096: "Jellyfin/Emby",
    8123: "Home Assistant", 8200: "Vault", 8443: "HTTPS (alternate)", 8888: "web app (Jupyter)",
    9000: "web app (Portainer, MinIO, SonarQube)", 9090: "Cockpit or Prometheus", 9091: "Transmission",
    9093: "Alertmanager", 9100: "printer (JetDirect) or Prometheus node_exporter", 9200: "Elasticsearch",
    9443: "Portainer (HTTPS)", 10000: "Webmin", 10250: "Kubernetes kubelet", 11434: "Ollama",
    27017: "MongoDB", 32400: "Plex Media Server", 49152: "UPnP device", 62078: "Apple iPhone/iPad sync service",
}

NAME_HINTS: list[tuple[str, str]] = [
    (r"^BRN|^BRW", "Brother printer"), (r"^NPI|^HP[0-9A-F]{6}", "HP printer"), (r"EPSON", "Epson printer"),
    (r"Canon", "Canon printer"), (r"iPhone", "iPhone"), (r"iPad", "iPad"), (r"MacBook|iMac|Mac-?mini|Mac-?Studio", "Mac"),
    (r"Apple-?TV", "Apple TV"), (r"HomePod", "HomePod"), (r"Galaxy|SM-[A-Z]\d", "Samsung phone/tablet"),
    (r"android", "Android device"), (r"^ESP[_-]|esp32|esp8266", "ESP8266/ESP32 IoT module"),
    (r"raspberrypi", "Raspberry Pi"), (r"^DESKTOP-|^LAPTOP-|^WIN-", "Windows PC"), (r"Chromecast", "Chromecast"),
    (r"Roku", "Roku"), (r"Sonos", "Sonos speaker"), (r"tapo|kasa|^TL-|tplink", "TP-Link device"),
    (r"shelly", "Shelly smart relay"), (r"DiskStation|synology", "Synology NAS"), (r"unifi|^U[67]", "Ubiquiti UniFi device"),
    (r"^ring-|Ring", "Ring doorbell/camera"), (r"nest|google-home", "Google Nest device"), (r"Echo|amazon", "Amazon Echo/Fire device"),
    (r"PS[45]|PlayStation", "PlayStation"), (r"XBOX", "Xbox"), (r"Nintendo|Switch", "Nintendo Switch"),
    (r"docker", "Docker host"), (r"ci-?cd|jenkins|runner|gitlab|build", "CI/CD build server"),
    (r"k8s|kube|k3s", "Kubernetes node"), (r"proxmox|^pve", "Proxmox hypervisor"), (r"\bvm\b|-vm\d*$|^vm-", "virtual machine"),
    (r"ubuntu", "Ubuntu Linux"), (r"debian", "Debian Linux"), (r"\bnas\b|-nas", "NAS"),
]

# Rule-based product/OS signatures, matched against service banners, HTTP headers and page bodies.
SIGNATURES: list[tuple[str, str]] = [
    (r"cockpit", "Cockpit web console (Linux server admin)"),
    (r"ubuntu", "Ubuntu Linux"), (r"debian|deb\d+u\d", "Debian Linux"), (r"raspbian", "Raspberry Pi OS"),
    (r"\.el[789]|red ?hat|centos|rocky linux|almalinux|fedora", "Red Hat family Linux"),
    (r"alpine", "Alpine Linux"), (r"freebsd", "FreeBSD"), (r"OpenSSH_for_Windows|Microsoft-IIS|Microsoft-HTTPAPI", "Windows"),
    (r"openwrt|luci", "OpenWrt router"), (r"portainer", "Portainer (Docker management)"), (r"grafana", "Grafana"),
    (r"proxmox|pve-api", "Proxmox VE hypervisor"), (r"synology|diskstation", "Synology NAS"), (r"\bqnap\b|\bQTS\b", "QNAP NAS"),
    (r"truenas|freenas", "TrueNAS"), (r"unifi|ubiquiti", "Ubiquiti UniFi"), (r"home assistant", "Home Assistant"),
    (r"jellyfin", "Jellyfin"), (r"\bplex\b", "Plex"), (r"pi-hole", "Pi-hole"), (r"jenkins", "Jenkins CI"),
    (r"gitlab", "GitLab"), (r"gitea|forgejo", "Gitea/Forgejo"), (r"nextcloud", "Nextcloud"), (r"webmin", "Webmin"),
    (r"docker-distribution-api|registry/2\.0", "Docker registry"), (r"Server: Docker/", "Docker Engine API"),
    (r"minio", "MinIO"), (r"kubernetes|\bk3s\b", "Kubernetes"), (r"node_exporter|go_gc_duration", "Prometheus node_exporter"),
    (r"prometheus", "Prometheus"), (r"traefik", "Traefik proxy"), (r"uptime kuma", "Uptime Kuma"), (r"ollama", "Ollama"),
    (r"brother", "Brother printer"), (r"HP (LaserJet|OfficeJet|ENVY|Color)", "HP printer"), (r"\bCUPS\b", "CUPS print server"),
    (r"xfinity|docsis", "cable modem / gateway"), (r"nginx", "nginx"), (r"apache", "Apache httpd"),
]

# MAC prefixes of virtualization platforms (many are missing from public OUI lookups).
VM_OUIS = {
    "00:50:56": "VMware", "00:0c:29": "VMware", "00:05:69": "VMware", "08:00:27": "VirtualBox",
    "52:54:00": "QEMU/KVM", "bc:24:11": "Proxmox VE (QEMU/KVM)", "00:1c:42": "Parallels", "00:15:5d": "Hyper-V",
    "02:42:ac": "Docker container", "00:16:3e": "Xen",
}

UA = "Mozilla/5.0 (Macintosh) bibi/0.1"
_TLS = ssl._create_unverified_context()  # LAN services use self-signed certificates


# --- parsing --------------------------------------------------------------


def normalize_mac(text: str) -> str | None:
    """'00-DD-1F-E2-AA-44', '0:dd:1f:e2:aa:44' or '00dd.1fe2.aa44' -> '00:dd:1f:e2:aa:44'."""
    t = text.strip().lower()
    if re.fullmatch(r"[0-9a-f]{1,2}([:-][0-9a-f]{1,2}){5}", t):
        return ":".join(p.zfill(2) for p in re.split(r"[:-]", t))
    digits = re.sub(r"[.:-]", "", t)
    if re.fullmatch(r"[0-9a-f]{12}", digits):
        return ":".join(digits[i : i + 2] for i in range(0, 12, 2))
    return None


def is_ip(text: str) -> bool:
    try:
        ipaddress.ip_address(text)
        return True
    except ValueError:
        return False


def is_randomized(mac: str) -> bool:
    """Locally administered bit set: a private/random MAC (phones, tablets, laptops with privacy on)."""
    return bool(int(mac[:2], 16) & 0x02)


def vm_platform(mac: str) -> str | None:
    return VM_OUIS.get(mac[:8])


def name_hints(*names: str | None) -> list[str]:
    found = []
    for name in filter(None, names):
        for pattern, hint in NAME_HINTS:
            if re.search(pattern, name, re.I) and hint not in found:
                found.append(hint)
    return found


def signatures(*texts: str | None) -> list[str]:
    found = []
    for text in filter(None, texts):
        for pattern, label in SIGNATURES:
            if re.search(pattern, text, re.I) and label not in found:
                found.append(label)
    return found


def os_from_ttl(ttl: int | None) -> str | None:
    if not ttl:
        return None
    if ttl <= 64:
        return "Linux, macOS, BSD or embedded (TTL 64)"
    if ttl <= 128:
        return "Windows (TTL 128)"
    return "network equipment such as a router or switch (TTL 255)"


# --- local lookups --------------------------------------------------------


def _out(cmd: list[str], timeout: float = 5) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (subprocess.TimeoutExpired, OSError):
        return ""


def arp_table() -> dict[str, str]:
    """mac -> ip from the system ARP cache."""
    table = {}
    for m in re.finditer(r"\(([\d.]+)\) at ([0-9a-f:]+)", _out(["arp", "-an"])):
        if mac := normalize_mac(m[2]):
            table[mac] = m[1]
    return table


def ping(ip: str, timeout_s: int = 1) -> int | None:
    """TTL of the reply, or None if the host didn't answer."""
    m = re.search(r"ttl=(\d+)", _out(["ping", "-c", "1", "-t", str(timeout_s), ip], timeout=timeout_s + 2))
    return int(m[1]) if m else None


def local_network() -> ipaddress.IPv4Network | None:
    """The default interface's subnet, capped at /24 around our own address."""
    iface = re.search(r"interface: (\S+)", _out(["route", "-n", "get", "default"]))
    if not iface:
        return None
    ip = _out(["ipconfig", "getifaddr", iface[1]]).strip()
    mask = _out(["ipconfig", "getoption", iface[1], "subnet_mask"]).strip() or "255.255.255.0"
    if not ip:
        return None
    net = ipaddress.ip_network(f"{ip}/{mask}", strict=False)
    return net if net.prefixlen >= 24 else ipaddress.ip_network(f"{ip}/24", strict=False)


def sweep(net: ipaddress.IPv4Network, workers: int = 64) -> None:
    """Ping every host once so the ARP cache fills up."""
    with ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(lambda h: ping(str(h)), net.hosts()))


def resolve(name: str) -> str | None:
    """DNS first, then mDNS (.local) for bare hostnames."""
    candidates = [name] + ([f"{name}.local"] if "." not in name else [])
    for candidate in candidates:
        try:
            return socket.getaddrinfo(candidate, None, socket.AF_INET)[0][4][0]
        except OSError:
            continue
    return None


def reverse_dns(ip: str) -> str | None:
    with ThreadPoolExecutor(1) as pool:
        try:
            return pool.submit(socket.gethostbyaddr, ip).result(timeout=3)[0]
        except Exception:
            return None


def mdns_name(ip: str) -> str | None:
    out = _out(["dig", "+short", "+time=1", "+tries=1", "-x", ip, "@224.0.0.251", "-p", "5353"], timeout=4).strip()
    return out.splitlines()[0].rstrip(".") if out and not out.startswith(";") else None


def netbios_name(ip: str) -> str | None:
    m = re.search(r"Server:\s*(\S+)", _out(["smbutil", "status", "-ae", ip], timeout=4))
    return m[1] if m else None


def open_ports(ip: str, ports: list[int] | None = None, timeout: float = 0.6, workers: int = 64) -> list[int]:
    def check(port: int) -> int | None:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            return port if s.connect_ex((ip, port)) == 0 else None

    with ThreadPoolExecutor(max_workers=workers) as pool:
        return sorted(p for p in pool.map(check, ports or list(PORTS)) if p)


def _printable(data: bytes) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^\x20-\x7e]", " ", data.decode("latin-1"))).strip()


def http_info(ip: str, port: int, scheme: str) -> tuple[str, str] | None:
    """(summary, raw text for signature matching) for an HTTP(S) service, or None if it doesn't speak it."""
    req = urllib.request.Request(f"{scheme}://{ip}:{port}/", headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=3, context=_TLS) as resp:
            status, headers, body = resp.status, resp.headers, resp.read(30000).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        status, headers = e.code, e.headers
        try:
            body = e.read(30000).decode("utf-8", "replace")
        except Exception:
            body = ""
    except Exception:
        return None
    title = re.search(r"<title[^>]*>(.*?)</title>", body, re.I | re.S)
    parts = [f"{scheme.upper()} {status}"]
    if server := headers.get("Server"):
        parts.append(f"Server: {server}")
    if powered := headers.get("X-Powered-By"):
        parts.append(f"X-Powered-By: {powered}")
    if title and title[1].strip():
        parts.append(f"title: {html.unescape(title[1].strip())[:80]}")
    raw = "\n".join(f"{k}: {v}" for k, v in headers.items()) + "\n" + body
    return "; ".join(parts), raw


def grab(ip: str, port: int) -> tuple[str, str, str | None] | None:
    """Identify what answers on a port: (summary, raw text, web scheme or None).

    Many protocols greet first (SSH, FTP, SMTP, MySQL); otherwise try HTTP, then HTTPS.
    """
    try:
        with socket.create_connection((ip, port), timeout=2) as s:
            s.settimeout(1.5)
            try:
                greeting = s.recv(512)
            except OSError:
                greeting = b""
    except OSError:
        return None
    if greeting:
        text = _printable(greeting)[:160]
        return f"greeting: {text}", text, None
    for scheme in (("https", "http") if port in (443, 5001, 8006, 8443, 9090, 9443) else ("http", "https")):
        if info := http_info(ip, port, scheme):
            return info[0], info[1], scheme
    return None


# --- internet lookups -----------------------------------------------------


def mac_vendor(mac: str) -> str | None:
    """Look up the vendor from the OUI. Only the first 3 bytes are sent, never the full MAC."""
    oui = mac[:8]
    req = urllib.request.Request(f"https://api.macvendors.com/{urllib.parse.quote(oui)}", headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.read(200).decode().strip() or None
    except Exception:
        return None


def web_search(query: str, limit: int = 3) -> list[str]:
    """Top result snippets from DuckDuckGo's HTML endpoint (no API key; best effort)."""
    data = urllib.parse.urlencode({"q": query}).encode()
    req = urllib.request.Request("https://html.duckduckgo.com/html/", data=data, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            page = resp.read(300000).decode("utf-8", "replace")
    except Exception:
        return []
    titles = re.findall(r'class="result__a"[^>]*>(.*?)</a>', page, re.S)
    snippets = re.findall(r'class="result__snippet"[^>]*>(.*?)</a>', page, re.S)
    clean = lambda s: re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", s))).strip()
    return [f"{clean(t)}: {clean(s)[:200]}" for t, s in list(zip(titles, snippets))[:limit]]
