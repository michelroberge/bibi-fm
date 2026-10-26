"""Evidence gathering for network devices: local lookups first, internet lookups only when allowed."""

from __future__ import annotations

import html
import ipaddress
import re
import socket
import ssl
import subprocess
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

PORTS: dict[int, str] = {
    21: "FTP", 22: "SSH", 23: "Telnet (often old embedded devices)", 53: "DNS (router, Pi-hole)",
    80: "HTTP web interface", 443: "HTTPS web interface", 445: "SMB file sharing (PC, NAS)",
    548: "AFP (Mac, NAS)", 554: "RTSP video stream (IP camera, NVR)", 631: "IPP printing (printer)",
    1400: "Sonos speaker", 1883: "MQTT (IoT hub)", 3389: "Remote Desktop (Windows)",
    5000: "Synology DSM, UPnP or AirPlay", 5900: "VNC / Screen Sharing", 7000: "AirPlay (Apple TV, HomePod, AirPlay speaker)",
    8008: "Google Cast (Chromecast, Google/Nest speaker)", 8009: "Google Cast (Chromecast, Google/Nest speaker)",
    8080: "alternate HTTP", 8123: "Home Assistant", 8443: "alternate HTTPS", 9100: "raw printing / JetDirect (printer)",
    32400: "Plex Media Server", 49152: "UPnP device", 62078: "Apple iPhone/iPad sync service",
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
]

UA = "Mozilla/5.0 (Macintosh) bibi/0.1"


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


def name_hints(*names: str | None) -> list[str]:
    found = []
    for name in filter(None, names):
        for pattern, hint in NAME_HINTS:
            if re.search(pattern, name, re.I) and hint not in found:
                found.append(hint)
    return found


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


def ping(ip: str, timeout_s: int = 1) -> bool:
    try:
        return subprocess.run(["ping", "-c", "1", "-t", str(timeout_s), ip], capture_output=True, timeout=timeout_s + 2).returncode == 0
    except subprocess.TimeoutExpired:
        return False


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
    try:
        return socket.getaddrinfo(name, None, socket.AF_INET)[0][4][0]
    except OSError:
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


def open_ports(ip: str, timeout: float = 0.6) -> list[int]:
    def check(port: int) -> int | None:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            return port if s.connect_ex((ip, port)) == 0 else None

    with ThreadPoolExecutor(max_workers=32) as pool:
        return sorted(p for p in pool.map(check, PORTS) if p)


def http_banner(ip: str, port: int) -> str | None:
    """'Server: lighttpd; title: Brother HL-L2350DW' for a web interface, if any."""
    scheme = "https" if port in (443, 8443) else "http"
    ctx = ssl._create_unverified_context()  # LAN devices use self-signed certificates
    req = urllib.request.Request(f"{scheme}://{ip}:{port}/", headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=3, context=ctx) as resp:
            server, body = resp.headers.get("Server"), resp.read(20000).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        server, body = e.headers.get("Server"), ""
    except Exception:
        return None
    title = re.search(r"<title[^>]*>(.*?)</title>", body, re.I | re.S)
    parts = [f"Server: {server}"] if server else []
    if title and title[1].strip():
        parts.append(f"title: {html.unescape(title[1].strip())[:80]}")
    return "; ".join(parts) or "web page with no title"


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
