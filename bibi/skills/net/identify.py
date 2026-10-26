"""bibi net.identify: figure out what a device on the network is, from a MAC, IP or name."""

from __future__ import annotations

import argparse
import subprocess
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

from bibi.actions import Action
from bibi.llm import LLMError
from bibi.registry import Context, Skill, SkillResult, skill
from bibi.skills.net import probe

SCHEMA = {
    "title": "Identification",
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "device_type": {"type": "string", "description": "e.g. printer, phone, NAS, Linux server VM, router, IP camera"},
        "operating_system": {"type": "string", "description": "e.g. Ubuntu Linux, Windows, iOS, embedded firmware, or unknown"},
        "vendor": {"type": "string"},
        "model_guess": {"type": "string", "description": "specific model if the evidence shows it, else 'unknown'"},
        "confidence": {"type": "integer", "description": "0-100"},
        "reasoning": {"type": "string", "description": "two sentences citing the evidence"},
        "next_steps": {"type": "array", "items": {"type": "string"}, "description": "up to 3 ways to confirm"},
    },
    "x-order": ["device_type", "operating_system", "vendor", "model_guess", "confidence", "reasoning", "next_steps"],
    "required": ["device_type", "operating_system", "vendor", "model_guess", "confidence", "reasoning", "next_steps"],
}

INSTRUCTIONS = """You identify devices on a home or office network from technical evidence.
The "Detected" line comes from reliable rules (service banners, web pages, MAC prefixes): treat it as fact and
build on it. Then weigh service greetings and web titles, hostname hints, the MAC vendor, open ports and the TTL.
A VM platform MAC means a virtual machine; an SSH greeting usually names the Linux distribution.
Ports 9100/631 mean a printer unless a banner says otherwise; 62078 an iPhone/iPad; 8008/8009 Google Cast;
7000 AirPlay; 554 a camera. A randomized MAC usually means a phone, tablet or laptop with MAC privacy enabled.
If evidence is thin, say so and keep confidence low. Never invent model numbers."""


@dataclass
class Evidence:
    query: str
    mac: str | None = None
    ip: str | None = None
    names: dict[str, str] = field(default_factory=dict)
    vendor: str | None = None
    vm: str | None = None
    randomized: bool = False
    ttl: int | None = None
    ports: list[int] = field(default_factory=list)
    services: dict[int, str] = field(default_factory=dict)  # port -> banner summary
    web: dict[int, str] = field(default_factory=dict)  # port -> scheme, for ports that serve a web page
    detected: list[str] = field(default_factory=list)  # rule-based findings
    search: list[str] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)

    def hints(self) -> list[str]:
        return probe.name_hints(*self.names.values())

    def render(self) -> str:
        lines = [f"Looked up: {self.query}"]
        lines.append(f"MAC: {self.mac or 'unknown'}" + (" (randomized/private address)" if self.randomized else ""))
        lines.append(f"IP: {self.ip or 'unknown'}")
        lines.append(f"MAC vendor: {self.vendor or 'unknown'}" + (f" (virtualization: {self.vm})" if self.vm else ""))
        if os_hint := probe.os_from_ttl(self.ttl):
            lines.append(f"Ping TTL: {self.ttl}, typical of {os_hint}")
        for source, name in self.names.items():
            lines.append(f"Name ({source}): {name}")
        if self.ports:
            lines.append("Open ports: " + ", ".join(f"{p} ({probe.PORTS.get(p, 'unknown service')})" for p in self.ports[:25]))
        elif self.ip:
            lines.append("Open ports: none found")
        for port, banner in list(self.services.items())[:15]:
            lines.append(f"Port {port}: {banner}")
        if self.detected:
            lines.append("Detected: " + ", ".join(self.detected))
        if hints := self.hints():
            lines.append("Hints: " + ", ".join(hints))
        for s in self.search:
            lines.append(f"Web result: {s}")
        return "\n".join(lines)


@skill("net.identify", aliases=["net-identify"], uses_web=True,
       help="Identify a network device from a MAC address, IP address or hostname")
class NetIdentify(Skill):
    def add_arguments(self, p: argparse.ArgumentParser) -> None:
        p.add_argument("target", help="MAC (00:dd:1f:e2:aa:44), IP (10.0.0.42) or hostname (printer.local)")
        p.add_argument("--offline", action="store_true", help="no internet lookups (vendor, web search)")
        p.add_argument("--no-sweep", action="store_true", help="don't ping the local subnet to find an unknown MAC")
        p.add_argument("--deep", action="store_true", help="scan TCP ports 1-10000 instead of ~75 common ones (slower)")

    def run(self, args: argparse.Namespace, ctx: Context) -> SkillResult:
        ui, ev = ctx.ui, Evidence(args.target)
        self._locate(ev, args, ui)
        if ev.ip:
            self._probe_host(ev, ui, args.deep)
        if ev.mac:
            ev.vm = probe.vm_platform(ev.mac)
            ev.randomized = probe.is_randomized(ev.mac) and not ev.vm
            if ev.vm:
                ev.detected.insert(0, f"virtual machine ({ev.vm})")
            if not ev.randomized and not ev.vm and not args.offline:
                ui.progress("Looking up MAC vendor...")
                ev.vendor = probe.mac_vendor(ev.mac)
        if not args.offline and ev.vendor:
            # Search with the vendor + generic findings only; never the user's own hostnames or addresses.
            terms = [ev.vendor or "", *ev.detected[:3], *ev.hints()[:1]]
            query = " ".join(t for t in terms if t) + " network device"
            ui.progress(f"Searching the web: {query}")
            ev.search = probe.web_search(query)

        if not ev.ip and not ev.vendor:
            # Nothing but the query itself: a model guess would be pure invention.
            return SkillResult(summary=f"Could not reach or look up {args.target}; nothing to identify it from.",
                               notes=ev.problems)

        report = ev.render()
        ui.heading("Evidence")
        ui.info(report)
        ui.progress("Asking fm to identify the device...")
        try:
            r = ctx.llm.respond(report, INSTRUCTIONS, SCHEMA)
        except LLMError as e:
            return SkillResult(summary=f"fm could not produce an identification: {e}", notes=ev.problems)

        model = r.get("model_guess", "unknown")
        lines = [
            "",
            f"Likely: {r.get('device_type', '?')} by {r.get('vendor', '?')}"
            + (f" ({model})" if model and model.lower() != "unknown" else ""),
            f"OS: {r.get('operating_system', '?')}",
            f"Confidence: {r.get('confidence', '?')}%",
            f"Why: {r.get('reasoning', '')}",
        ]
        if steps := r.get("next_steps"):
            lines.append("To confirm: " + "; ".join(steps[:3]))
        return SkillResult(summary="\n".join(lines), actions=self._actions(ev), notes=ev.problems)

    def _locate(self, ev: Evidence, args: argparse.Namespace, ui) -> None:
        target = args.target.strip()
        if mac := probe.normalize_mac(target):
            ev.mac = mac
            table = probe.arp_table()
            if not table:
                ev.problems.append("the ARP table came back empty: allow your terminal app under System Settings > "
                                   "Privacy & Security > Local Network")
            ev.ip = table.get(mac)
            if not ev.ip and not args.no_sweep and (net := probe.local_network()):
                ui.progress(f"MAC not in ARP cache; pinging {net} to find it...")
                probe.sweep(net)
                ev.ip = probe.arp_table().get(mac)
            if not ev.ip:
                ev.problems.append("device not found on the local network (offline, asleep, or another subnet)")
            return
        if probe.is_ip(target):
            ev.ip = target
        else:
            ev.names["queried name"] = target
            ev.ip = probe.resolve(target)
            if not ev.ip:
                ev.problems.append(f"could not resolve {target}")
                return
        ui.progress(f"Pinging {ev.ip}...")
        ev.ttl = probe.ping(ev.ip)
        ev.mac = next((m for m, ip in probe.arp_table().items() if ip == ev.ip), None)
        if not ev.ttl and not ev.mac:
            ev.problems.append(f"{ev.ip} did not answer ping (it may still block ICMP)")

    def _probe_host(self, ev: Evidence, ui, deep: bool) -> None:
        if ev.ttl is None:
            ev.ttl = probe.ping(ev.ip)
        ui.progress(f"Looking up names for {ev.ip}...")
        for source, fn in (("reverse DNS", probe.reverse_dns), ("mDNS", probe.mdns_name), ("NetBIOS", probe.netbios_name)):
            if (name := fn(ev.ip)) and name not in ev.names.values():
                ev.names[source] = name
        ports = sorted(set(probe.PORTS) | set(range(1, 10001))) if deep else None
        ui.progress(f"Scanning {'10,000' if deep else len(probe.PORTS)} TCP ports on {ev.ip}...")
        ev.ports = probe.open_ports(ev.ip, ports, timeout=0.4 if deep else 0.6, workers=256 if deep else 64)
        ui.progress(f"Reading what answers on {len(ev.ports)} open port(s)...")
        with ThreadPoolExecutor(max_workers=16) as pool:
            grabs = list(pool.map(lambda p: probe.grab(ev.ip, p), ev.ports))
        raw_texts = []
        for port, g in zip(ev.ports, grabs):
            if g:
                ev.services[port], raw, scheme = g
                raw_texts.append(raw)
                if scheme:
                    ev.web[port] = scheme
        ev.detected += [d for d in probe.signatures(*raw_texts) if d not in ev.detected]

    def _actions(self, ev: Evidence) -> list[Action]:
        actions = []
        web_ports = list(ev.web)
        if 80 in web_ports and 443 in web_ports:
            web_ports.remove(80)  # same interface; prefer https
        for port in web_ports:
            scheme = ev.web[port]
            default = (scheme == "http" and port == 80) or (scheme == "https" and port == 443)
            url = f"{scheme}://{ev.ip}" + ("" if default else f":{port}")
            actions.append(Action(f"Open web interface {url}", "open", url, 0, 10, 10, ev.services.get(port, "web page"),
                                  f"open {url}", lambda u=url: (subprocess.run(["open", u]), f"opened {u}")[1]))
        return actions
