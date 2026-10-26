import BibiCore
@testable import BibiSkills
import Testing

@Suite struct NetProbeTests {
    @Test func normalizeMAC() {
        for text in ["00:DD:1F:E2:AA:44", "0:dd:1f:e2:aa:44", "00-dd-1f-e2-aa-44", "00dd.1fe2.aa44", "00dd1fe2aa44"] {
            #expect(Probe.normalizeMAC(text) == "00:dd:1f:e2:aa:44", "\(text)")
        }
        #expect(Probe.normalizeMAC("10.0.0.1") == nil)
        #expect(Probe.normalizeMAC("printer.local") == nil)
    }

    @Test func randomizedAndHints() {
        #expect(Probe.isRandomized("8a:2b:c8:1a:82:24"))
        #expect(!Probe.isRandomized("00:08:9b:e8:4e:14"))
        #expect(Probe.nameHints(["BRN008077.local"]) == ["Brother printer"])
        #expect(Probe.nameHints(["Michels-iPhone.local"]).contains("iPhone"))
    }

    @Test func linuxVMSignatures() {
        let ssh = "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5"
        let cockpit = "Content-Security-Policy: connect-src 'self'\n<html><head><title>Loading...</title>"
            + "<link href=\"cockpit/static/login.css\"><script src=\"cockpit/static/login.js\"></script>"
        let docker = "Server: Docker/27.3.1 (linux)\nApi-Version: 1.47\n{\"message\":\"page not found\"}"
        let found = Probe.signatures([ssh, cockpit, docker])
        #expect(found.contains("Ubuntu Linux"))
        #expect(found.contains("Cockpit web console (Linux server admin)"))
        #expect(found.contains("Docker Engine API"))
        #expect(Probe.vmPlatform("bc:24:11:d6:8e:c4") == "Proxmox VE (QEMU/KVM)")
        #expect(Probe.osFromTTL(64)!.contains("Linux"))
        #expect(Probe.osFromTTL(128)!.contains("Windows"))
    }

    @Test func arpParsing() {
        let text = "? (10.0.0.1) at 0:dd:1f:e2:aa:44 on en0 ifscope [ethernet]\n? (10.0.0.9) at (incomplete) on en0"
        #expect(Probe.parseARP(text) == ["00:dd:1f:e2:aa:44": "10.0.0.1"])
    }

    @Test func ipv4() {
        #expect(IPv4.isIP("10.0.0.42"))
        #expect(!IPv4.isIP("10.0.0.256"))
        #expect(!IPv4.isIP("printer.local"))
        #expect(IPv4.prefixLength(mask: "255.255.255.0") == 24)
        #expect(IPv4.isPrivate("192.168.1.4"))
        #expect(!IPv4.isPrivate("8.8.8.8"))
    }
}
