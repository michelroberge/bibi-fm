"""The only actions storage.optimize can take, plus the safety rules around them.

The model never writes commands: it picks an action_type and this module decides
whether that is allowed for the path and builds the concrete operation.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import time
from functools import cache
from pathlib import Path

from bibi.actions import Action
from bibi.skills.storage.optimize.scan import Node

ACTION_TYPES = ["trash", "empty_cache_dir", "tool_cleanup", "empty_trash", "review", "none"]

HOME = Path.home()
TRASH = HOME / ".Trash"

# Known patterns: (predicate on path, hint for the model, regenerable?, tool key)
_PATTERNS: list[tuple] = [
    (lambda p: p == TRASH, "the user's Trash; emptying it frees space permanently", False, None),
    (lambda p: p.parts[-3:] == ("go", "pkg", "mod"), "Go module cache, re-downloaded on demand", True, "go"),
    (lambda p: p.parent.name == "avd" and p.suffix == ".avd", "Android emulator image; recreatable in Android Studio", False, None),
    (lambda p: p.parts[-2:] == ("Android", "sdk"), "Android SDK; remove unused system images via Android Studio's SDK Manager", False, None),
    (lambda p: "DerivedData" in p.parts, "Xcode build artifacts, rebuilt automatically", True, None),
    (lambda p: "CoreSimulator" in p.parts, "iOS simulator data; stale devices removable via simctl", False, "simctl"),
    (lambda p: "Homebrew" in p.parts and "Caches" in p.parts, "Homebrew download cache", True, "brew"),
    (lambda p: p.name in ("Docker.raw", "com.docker.docker"), "Docker disk image; prune unused images/containers", False, "docker"),
    (lambda p: "_cacache" in p.parts or p == HOME / ".npm", "npm cache", True, "npm"),
    (lambda p: p.name == "pip" and ("Caches" in p.parts or ".cache" in p.parts), "pip download cache", True, "pip"),
    (lambda p: p.name == "node_modules", "npm dependencies, reinstallable with npm install", True, None),
    (lambda p: p.name in (".venv", "venv"), "Python virtualenv, recreatable", True, None),
    (lambda p: p.name == ".gradle" or p.name == "caches" and ".gradle" in p.parts, "Gradle caches", True, None),
    (lambda p: "MobileSync" in p.parts, "iPhone/iPad backups; manage in Finder, do not delete blindly", False, None),
    (lambda p: "Caches" in p.parts or p.name == ".cache", "application cache, regenerated automatically", True, None),
    (lambda p: "Logs" in p.parts, "log files", True, None),
    (lambda p: p.suffix.lower() in (".dmg", ".pkg", ".iso", ".xip"), "installer image; usually removable after install", False, None),
    (lambda p: p.suffix.lower() in (".zip", ".tar", ".gz", ".tgz", ".rar", ".7z"), "archive file", False, None),
    (lambda p: p == HOME / "Downloads", "user downloads; often old installers and archives", False, None),
    (lambda p: p == HOME / "Library", "app data, caches, containers; mixed content", False, None),
]

TOOLS: dict[str, list[str]] = {
    "brew": ["brew", "cleanup", "-s", "--prune=all"],
    "docker": ["docker", "system", "prune", "-f"],
    "simctl": ["xcrun", "simctl", "delete", "unavailable"],
    "npm": ["npm", "cache", "clean", "--force"],
    "pip": ["pip3", "cache", "purge"],
    "go": ["go", "clean", "-modcache"],
}

# How to check a tool really works. `xcrun` exists with the Command Line Tools alone, but simctl needs Xcode.
_TOOL_CHECKS: dict[str, list[str]] = {
    "simctl": ["xcrun", "--find", "simctl"],
    "go": ["go", "env", "GOMODCACHE"],
}

# Trashing something no rule knows to be regenerable is never rated fully safe, whatever the model says.
UNKNOWN_TRASH_MAX_SAFETY = 6

# Paths that may only ever be reviewed, never modified.
_PROTECTED_EXACT = {
    Path("/"), HOME, HOME / "Library", HOME / "Documents", HOME / "Desktop", HOME / "Pictures",
    HOME / "Movies", HOME / "Music", HOME / "Downloads", HOME / "Applications",
    HOME / "Library/Application Support", HOME / "Library/Containers", HOME / "Library/Group Containers",
}
_PROTECTED_PREFIX = [
    Path("/System"), Path("/usr"), Path("/bin"), Path("/sbin"), Path("/private"), Path("/Library"),
    Path("/Applications"), Path("/opt"), Path("/Volumes"),
    HOME / "Library/Mobile Documents", HOME / "Library/Mail", HOME / "Library/Messages",
    HOME / "Library/Keychains", HOME / "Library/CloudStorage", HOME / "Library/Application Support/MobileSync",
    HOME / ".ssh", HOME / ".gnupg",
]


def _match(path: Path):
    for pred, hint, regen, tool in _PATTERNS:
        try:
            if pred(path):
                return hint, regen, tool
        except Exception:
            continue
    return None, False, None


def hint_for(path: Path) -> str | None:
    return _match(path)[0]


def is_regenerable(path: Path) -> bool:
    return _match(path)[1]


@cache
def tool_available(key: str) -> bool:
    if not shutil.which(TOOLS[key][0]):
        return False
    check = _TOOL_CHECKS.get(key)
    if not check:
        return True
    try:
        return subprocess.run(check, capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def tool_for(path: Path) -> list[str] | None:
    key = _match(path)[2]
    return TOOLS[key] if key and tool_available(key) else None


def missing_tool_note(path: Path) -> str | None:
    key = _match(path)[2]
    if key == "simctl" and not tool_available(key):
        return "Xcode isn't installed, so simctl can't prune it; if you no longer use iOS simulators, trash this folder."
    return None


def is_protected(path: Path) -> bool:
    if path in _PROTECTED_EXACT or any(part.endswith(".app") for part in path.parts):
        return True
    if path.is_relative_to(HOME / "Library/Caches") or path.is_relative_to(HOME / "Library/Logs"):
        return False
    return any(path == p or path.is_relative_to(p) for p in _PROTECTED_PREFIX)


def _is_git_repo(path: Path) -> bool:
    return (path / ".git").exists()


def short(path: Path) -> str:
    try:
        return "~/" + str(path.relative_to(HOME)) if path != HOME else "~"
    except ValueError:
        return str(path)


# --- execution primitives -------------------------------------------------


def _move_to_trash(path: Path) -> str:
    TRASH.mkdir(exist_ok=True)
    dest = TRASH / path.name
    if dest.exists():
        dest = TRASH / f"{path.stem} {time.strftime('%H.%M.%S')}{path.suffix}"
    shutil.move(str(path), str(dest))
    return f"moved to Trash ({short(dest)}); empty the Trash to reclaim the space"


def _delete_contents(path: Path) -> str:
    failed = 0
    for entry in path.iterdir():
        try:
            if entry.is_dir() and not entry.is_symlink():
                shutil.rmtree(entry)
            else:
                entry.unlink()
        except OSError:
            failed += 1
    return f"emptied {short(path)}" + (f" ({failed} item(s) could not be removed)" if failed else "")


def _run(argv: list[str]) -> str:
    proc = subprocess.run(argv, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip()[:300] or f"exit {proc.returncode}")
    return f"ran {' '.join(argv)}"


def _reveal(path: Path) -> str:
    subprocess.run(["open", "-R", str(path)], check=False)
    return f"revealed {short(path)} in Finder"


# --- building actions -----------------------------------------------------


def build_action(node: Node, verdict: dict, root: Path) -> Action | None:
    """Turn a model verdict into a safe Action, downgrading or rejecting when rules say so."""
    path = node.path
    if path == root or not path.is_relative_to(root):
        return None
    kind = verdict.get("action_type", "none")
    if verdict.get("verdict") == "skip" or kind == "none":
        return None
    safety = max(0, min(10, int(verdict.get("safety", 5))))
    confidence = max(0, min(10, int(verdict.get("confidence", 5))))
    reason = str(verdict.get("reason", "")).strip() or "suggested by model"

    if kind == "tool_cleanup" and not tool_for(path):
        kind = "empty_cache_dir" if is_regenerable(path) else "review"
        if note := missing_tool_note(path):
            reason = note
    if kind == "empty_trash" and path != TRASH:
        kind = "review"
    if kind == "trash" and node.is_dir and is_regenerable(path):
        kind = "empty_cache_dir"
    if kind == "empty_cache_dir" and (not node.is_dir or not is_regenerable(path)):
        kind = "trash"
    if kind in ("trash", "empty_cache_dir") and (is_protected(path) or (node.is_dir and _is_git_repo(path))):
        kind = "review"
    if kind == "trash" and path.is_relative_to(HOME / "Library") and not is_regenerable(path):
        kind = "review"
    if kind == "trash" and path == TRASH:
        kind = "empty_trash"
    if kind == "trash" and not is_regenerable(path):
        safety = min(safety, UNKNOWN_TRASH_MAX_SAFETY)

    s = short(path)
    if kind == "trash":
        return Action(f"Move {s} to Trash", kind, str(path), node.size, safety, confidence, reason,
                      f"mv {s} ~/.Trash/", lambda: _move_to_trash(path))
    if kind == "empty_cache_dir":
        return Action(f"Clear {s}", kind, str(path), node.size, safety, confidence, reason,
                      f"rm -rf {s}/*", lambda: _delete_contents(path))
    if kind == "empty_trash":
        return Action("Empty the Trash", kind, str(path), node.size, safety, confidence, reason,
                      "rm -rf ~/.Trash/*", lambda: _delete_contents(TRASH))
    if kind == "tool_cleanup":
        argv = tool_for(path)
        assert argv
        return Action(f"Run {argv[0]} cleanup ({s})", kind, str(path), node.size, safety, confidence, reason,
                      " ".join(argv), lambda: _run(argv))
    return Action(f"Review {s}", "review", str(path), node.size, min(safety, 10), confidence, reason,
                  f"open -R {s}   (manual review in Finder)", lambda: _reveal(path), weight=0.4)


def consolidated_action(node: Node, actions: list[Action], safety: int, reason: str) -> Action | None:
    """One 'clear parent' action replacing several actions inside a regenerable parent."""
    if not node.is_dir or not is_regenerable(node.path) or is_protected(node.path):
        return None
    confidence = round(sum(a.confidence for a in actions) / len(actions))
    s = short(node.path)
    return Action(f"Clear {s}", "empty_cache_dir", str(node.path), node.size, safety, confidence, reason,
                  f"rm -rf {s}/*", lambda: _delete_contents(node.path))
