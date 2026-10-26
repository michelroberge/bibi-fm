"""Recursive analysis: assess each child independently with fm, descend where useful,
then merge and optimize candidate actions on the way back up."""

from __future__ import annotations

import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

from bibi.actions import Action
from bibi.llm import LLMError
from bibi.registry import Context
from bibi.skills.storage.optimize import catalog
from bibi.skills.storage.optimize.catalog import short
from bibi.skills.storage.optimize.scan import Node
from bibi.ui import human

VERDICT_SCHEMA = {
    "title": "Verdict",
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "verdict": {"type": "string", "enum": ["act", "descend", "skip"],
                    "description": "act = recommend an action on this item; descend = look inside; skip = leave alone"},
        "action_type": {"type": "string", "enum": catalog.ACTION_TYPES},
        "safety": {"type": "integer", "description": "0 = risky data loss, 10 = no risk at all"},
        "confidence": {"type": "integer", "description": "0-10 how sure you are"},
        "reason": {"type": "string", "description": "one short sentence"},
    },
    "x-order": ["verdict", "action_type", "safety", "confidence", "reason"],
    "required": ["verdict", "action_type", "safety", "confidence", "reason"],
}

VERDICT_INSTRUCTIONS = """You are a careful macOS disk-space advisor. You get ONE file or folder with its size and largest contents.
Decide:
- verdict "act": a specific cleanup is appropriate for this whole item.
- verdict "descend": the item is large but mixed (e.g. ~/Library, ~/Documents, project folders); look inside instead. Only when "Can look inside" is yes.
- verdict "skip": leave it alone (small gain, or personal data with no clear cleanup).
action_type (use "none" unless verdict is "act"):
- empty_cache_dir: caches, logs, build artifacts that apps regenerate.
- trash: a file or folder the user very likely no longer needs (old installers, archives, stale downloads).
- tool_cleanup: a tool owns this data and has its own cleanup (Homebrew, Docker, npm, pip, iOS simulators).
- empty_trash: only for the Trash itself.
- review: large personal data (photos, videos, backups, documents) the user should look at themselves.
Never suggest deleting documents, photos, source code, or app data outright; use review.
Safety is 10 only when nothing of value can be lost."""

CONSOLIDATE_SCHEMA = {
    "title": "Consolidate",
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "combine": {"type": "boolean", "description": "true to replace the items with one action on the parent folder"},
        "safety": {"type": "integer", "description": "0-10 safety of clearing the whole parent folder"},
        "reason": {"type": "string", "description": "one short sentence"},
    },
    "x-order": ["combine", "safety", "reason"],
    "required": ["combine", "safety", "reason"],
}

CONSOLIDATE_INSTRUCTIONS = """You optimize a list of disk cleanup recommendations that all live inside one parent folder.
Say combine=true only if clearing the entire parent folder is as safe as the individual items and simpler for the user."""


@dataclass
class Config:
    root: Path
    depth: int
    min_size: int
    keep: int  # candidates kept per level while bubbling up
    jobs: int


def _describe(node: Node, can_descend: bool) -> str:
    kind = "folder" if node.is_dir else "file"
    age = f", modified {node.age_days} days ago" if node.age_days >= 0 else ""
    lines = [f"Item: {short(node.path)}", f"Type: {kind}, {human(node.size)}{age}"]
    if hint := catalog.hint_for(node.path):
        lines.append(f"Known as: {hint}")
    if node.is_dir:
        lines.append(f"Can look inside: {'yes' if can_descend and node.children else 'no'}")
        if node.children:
            lines.append("Largest contents:")
            for c in node.children[:10]:
                lines.append(f"- {c.path.name}{'/' if c.is_dir else ''} {human(c.size)}")
    return "\n".join(lines)


def assess(node: Node, can_descend: bool, ctx: Context) -> dict | None:
    prompt = _describe(node, can_descend)
    t = time.monotonic()
    try:
        v = ctx.llm.respond(prompt, VERDICT_INSTRUCTIONS, VERDICT_SCHEMA)
    except LLMError as e:
        ctx.ui.debug(f"  ! {short(node.path)}: {e}")
        return None
    ctx.ui.debug(f"  {short(node.path):<50} {human(node.size):>9}  {v.get('verdict')}/{v.get('action_type')}"
                 f" s={v.get('safety')} c={v.get('confidence')} ({time.monotonic() - t:.1f}s) {v.get('reason')}")
    return v


def analyze(node: Node, depth_left: int, ctx: Context, cfg: Config) -> list[Action]:
    """Assess node's children independently, recurse into 'descend' ones, return the best candidates."""
    kids = [c for c in node.children if c.size >= cfg.min_size]
    if not kids:
        return []
    ctx.ui.progress(f"Analyzing {short(node.path)} ({len(kids)} items)...")
    with ThreadPoolExecutor(max_workers=cfg.jobs) as pool:
        verdicts = list(pool.map(lambda c: assess(c, depth_left > 0, ctx), kids))

    candidates: list[Action] = []
    for kid, v in zip(kids, verdicts):
        if v is None:
            continue
        if v.get("verdict") == "descend":
            if depth_left > 0 and kid.is_dir and kid.children:
                candidates += analyze(kid, depth_left - 1, ctx, cfg)
                continue
            v = {**v, "verdict": "act", "action_type": "review"}
        if action := catalog.build_action(kid, v, cfg.root):
            candidates.append(action)
    return bubble_up(node, candidates, ctx, cfg)


def _covers(parent: Action, child: Action) -> bool:
    return parent.target != child.target and Path(child.target).is_relative_to(Path(parent.target))


def bubble_up(node: Node, candidates: list[Action], ctx: Context, cfg: Config) -> list[Action]:
    """Merge duplicates, drop overlaps, optionally consolidate with fm, keep the top `keep`."""
    # 1. Same command (e.g. two Homebrew dirs -> one `brew cleanup`): merge sizes.
    merged: dict[str, Action] = {}
    for a in candidates:
        key = a.command if a.kind == "tool_cleanup" else a.target
        if key in merged:
            m = merged[key]
            m.bytes += a.bytes if a.kind == "tool_cleanup" else 0
            m.safety = min(m.safety, a.safety)
        else:
            merged[key] = a
    actions = list(merged.values())

    # 2. Overlaps: an action on a folder and on something inside it double-count; keep the better.
    actions.sort(key=lambda a: a.score, reverse=True)
    kept: list[Action] = []
    for a in actions:
        if not any(_covers(k, a) or _covers(a, k) for k in kept):
            kept.append(a)

    # 3. Several clear/trash actions inside a regenerable folder -> ask fm whether to clear the folder.
    inside = [a for a in kept if a.kind in ("empty_cache_dir", "trash") and Path(a.target).parent == node.path]
    if len(inside) >= 3 and catalog.is_regenerable(node.path) and not catalog.is_protected(node.path):
        items = "\n".join(f"- {short(Path(a.target))} {human(a.bytes)} ({a.kind}, safety {a.safety})" for a in inside)
        prompt = f"Parent folder: {short(node.path)} ({human(node.size)})\nKnown as: {catalog.hint_for(node.path)}\nItems:\n{items}"
        try:
            res = ctx.llm.respond(prompt, CONSOLIDATE_INSTRUCTIONS, CONSOLIDATE_SCHEMA)
        except LLMError as e:
            res = None
            ctx.ui.debug(f"  ! consolidate {short(node.path)}: {e}")
        if res and res.get("combine"):
            safety = min(int(res.get("safety", 5)), min(a.safety for a in inside))
            if combined := catalog.consolidated_action(node, inside, safety, str(res.get("reason", ""))):
                ctx.ui.debug(f"  ⇡ consolidated {len(inside)} items into {combined.title}")
                kept = [a for a in kept if a not in inside] + [combined]

    kept.sort(key=lambda a: a.score, reverse=True)
    return kept[: cfg.keep]
