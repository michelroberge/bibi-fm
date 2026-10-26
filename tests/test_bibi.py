import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from bibi.actions import parse_selection
from bibi.registry import Context, discover
from bibi.skills.storage.optimize import catalog, parse_size
from bibi.skills.storage.optimize.analyze import Config, analyze
from bibi.skills.storage.optimize.scan import scan
from bibi.ui import UI

MB = 1 << 20


class FakeLLM:
    """Answers by folder name; records every prompt it was given."""

    def __init__(self, rules, combine=False):
        self.rules, self.combine, self.prompts = rules, combine, []

    def respond(self, prompt, instructions, schema):
        self.prompts.append(prompt)
        if schema["title"] == "Consolidate":
            return {"combine": self.combine, "safety": 9, "reason": "all caches"}
        item = prompt.splitlines()[0].removeprefix("Item: ")
        for name, verdict in self.rules.items():
            if item.endswith("/" + name):
                return verdict
        return {"verdict": "skip", "action_type": "none", "safety": 5, "confidence": 5, "reason": "default"}


def act(kind, safety=8, conf=8):
    return {"verdict": "act", "action_type": kind, "safety": safety, "confidence": conf, "reason": "test"}


DESCEND = {"verdict": "descend", "action_type": "none", "safety": 5, "confidence": 5, "reason": "mixed"}


def write(path: Path, mb: int):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(os.urandom(mb * MB))


class SelectionTests(unittest.TestCase):
    def test_grammar(self):
        self.assertEqual(parse_selection("1,2,5", 5), [0, 1, 4])
        self.assertEqual(parse_selection("1-3", 5), [0, 1, 2])
        self.assertEqual(parse_selection("2 2 1", 5), [1, 0])
        self.assertEqual(parse_selection("all", 3), [0, 1, 2])
        self.assertEqual(parse_selection("none", 3), [])
        self.assertEqual(parse_selection("", 3), [])

    def test_invalid(self):
        with self.assertRaises(ValueError):
            parse_selection("6", 5)
        with self.assertRaises(ValueError):
            parse_selection("x", 5)

    def test_parse_size(self):
        self.assertEqual(parse_size("500M"), 500 * MB)
        self.assertEqual(parse_size("2G"), 2 << 30)


class CatalogTests(unittest.TestCase):
    def node(self, path, is_dir=True):
        from bibi.skills.storage.optimize.scan import Node
        return Node(Path(path), 10 * MB, is_dir)

    def test_protected_paths_only_reviewed(self):
        home = Path.home()
        for p in (home / "Documents", home / "Library/Mail/V10", Path("/System/Library")):
            a = catalog.build_action(self.node(p), act("trash", 10, 10), Path("/"))
            self.assertEqual(a.kind, "review", p)

    def test_cache_dir_allowed(self):
        p = Path.home() / "Library/Caches/com.example"
        a = catalog.build_action(self.node(p), act("empty_cache_dir"), Path.home())
        self.assertEqual(a.kind, "empty_cache_dir")

    def test_non_cache_library_trash_downgraded(self):
        p = Path.home() / "Library/Application Support/SomeApp"
        a = catalog.build_action(self.node(p), act("trash"), Path.home())
        self.assertEqual(a.kind, "review")

    def test_outside_root_rejected(self):
        self.assertIsNone(catalog.build_action(self.node("/elsewhere/x"), act("trash"), Path.home()))

    def test_app_bundles_only_reviewed(self):
        p = Path.home() / "Visual Studio Code.app/Contents/Frameworks"
        self.assertEqual(catalog.build_action(self.node(p), act("empty_cache_dir"), Path.home()).kind, "review")

    def test_unknown_trash_safety_capped(self):
        a = catalog.build_action(self.node(Path.home() / "old-stuff"), act("trash", 10, 10), Path.home())
        self.assertEqual(a.safety, catalog.UNKNOWN_TRASH_MAX_SAFETY)

    def test_skills_registered(self):
        skills = discover()
        self.assertIn("storage.optimize", skills)
        self.assertIn("net.identify", skills)


class NetProbeTests(unittest.TestCase):
    def test_normalize_mac(self):
        from bibi.skills.net.probe import normalize_mac
        for text in ("00:DD:1F:E2:AA:44", "0:dd:1f:e2:aa:44", "00-dd-1f-e2-aa-44", "00dd.1fe2.aa44", "00dd1fe2aa44"):
            self.assertEqual(normalize_mac(text), "00:dd:1f:e2:aa:44", text)
        self.assertIsNone(normalize_mac("10.0.0.1"))
        self.assertIsNone(normalize_mac("printer.local"))

    def test_randomized_and_hints(self):
        from bibi.skills.net.probe import is_randomized, name_hints
        self.assertTrue(is_randomized("8a:2b:c8:1a:82:24"))
        self.assertFalse(is_randomized("00:08:9b:e8:4e:14"))
        self.assertEqual(name_hints("BRN008077.local"), ["Brother printer"])
        self.assertIn("iPhone", name_hints("Michels-iPhone.local"))

    def test_linux_vm_signatures(self):
        from bibi.skills.net.probe import os_from_ttl, signatures, vm_platform
        ssh = "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5"
        cockpit = 'Content-Security-Policy: connect-src \'self\'\n<html><head><title>Loading...</title>' \
                  '<link href="cockpit/static/login.css"><script src="cockpit/static/login.js"></script>'
        docker = "Server: Docker/27.3.1 (linux)\nApi-Version: 1.47\n{\"message\":\"page not found\"}"
        found = signatures(ssh, cockpit, docker)
        self.assertIn("Ubuntu Linux", found)
        self.assertIn("Cockpit web console (Linux server admin)", found)
        self.assertIn("Docker Engine API", found)
        self.assertEqual(vm_platform("bc:24:11:d6:8e:c4"), "Proxmox VE (QEMU/KVM)")
        self.assertIn("Linux", os_from_ttl(64))
        self.assertIn("Windows", os_from_ttl(128))


class AnalyzeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        write(self.tmp / "Caches/a/blob", 3)
        write(self.tmp / "Caches/b/blob", 3)
        write(self.tmp / "Caches/c/blob", 3)
        write(self.tmp / "work/big.dmg", 4)
        write(self.tmp / "work/notes/n.txt", 2)
        write(self.tmp / "photos/p.raw", 5)
        # temp dirs live under /private on macOS, which is protected; lift that for tests
        patcher = mock.patch.object(catalog, "_PROTECTED_PREFIX", [])
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_analysis(self, llm, depth=2, top=5):
        ctx = Context(llm=llm, ui=UI())
        tree = scan(self.tmp, depth=depth + 1)
        cfg = Config(root=self.tmp, depth=depth, min_size=1 * MB, keep=2 * top, jobs=2)
        return analyze(tree, depth - 1, ctx, cfg)[:top]

    def test_recursion_and_ranking(self):
        llm = FakeLLM({
            "Caches": DESCEND, "a": act("empty_cache_dir"), "b": act("empty_cache_dir"), "c": act("empty_cache_dir"),
            "work": DESCEND, "big.dmg": act("trash", 9, 9), "photos": act("review"),
        })
        actions = self.run_analysis(llm)
        targets = [Path(a.target).relative_to(self.tmp).as_posix() for a in actions]
        self.assertIn("work/big.dmg", targets)
        self.assertIn("Caches/a", targets)
        self.assertEqual(targets[0], "work/big.dmg")  # 4MB at 9/9 beats 3MB at 8/8
        self.assertEqual(actions[-1].kind, "review")  # reviews are down-weighted
        self.assertTrue(any("work/big.dmg" in p for p in llm.prompts))

    def test_consolidation_on_the_way_up(self):
        with mock.patch.object(catalog, "is_regenerable", lambda p: p.name in ("Caches", "a", "b", "c")):
            llm = FakeLLM({"Caches": DESCEND, "a": act("empty_cache_dir"), "b": act("empty_cache_dir"),
                           "c": act("empty_cache_dir")}, combine=True)
            actions = self.run_analysis(llm)
        self.assertEqual([Path(a.target).name for a in actions], ["Caches"])
        self.assertGreaterEqual(actions[0].bytes, 9 * MB)

    def test_top_n_and_execution(self):
        llm = FakeLLM({"work": DESCEND, "big.dmg": act("trash"), "Caches": act("empty_cache_dir")})
        with mock.patch.object(catalog, "is_regenerable", lambda p: p.name == "Caches"):
            actions = self.run_analysis(llm, top=1)
        self.assertEqual(len(actions), 1)
        self.assertEqual(Path(actions[0].target).name, "Caches")
        actions[0].execute()
        self.assertEqual(list((self.tmp / "Caches").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
