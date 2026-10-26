"""bibi storage.optimize: find the best ways to reclaim disk space."""

from __future__ import annotations

import argparse
import re
import time
from pathlib import Path

from bibi.registry import Context, Skill, SkillResult, skill
from bibi.skills.storage.optimize.analyze import Config, analyze
from bibi.skills.storage.optimize.catalog import short
from bibi.skills.storage.optimize.scan import disk_usage, scan
from bibi.ui import human


def parse_size(text: str) -> int:
    m = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([KMGT]?)B?\s*", text, re.I)
    if not m:
        raise argparse.ArgumentTypeError(f"invalid size: {text!r} (try 500M or 2G)")
    return int(float(m[1]) * 1024 ** "_KMGT".index(m[2].upper() or "_"))


@skill("storage.optimize", aliases=["optimize-storage"], help="Analyze disk usage and recommend (and run) the top cleanup actions")
class OptimizeStorage(Skill):
    def add_arguments(self, p: argparse.ArgumentParser) -> None:
        p.add_argument("path", nargs="?", default="~", help="folder to analyze (default: your home folder)")
        p.add_argument("-n", "--top", type=int, default=5, help="number of actions to recommend (default 5)")
        p.add_argument("--depth", type=int, default=3, help="how many levels fm may descend (default 3)")
        p.add_argument("--min-size", type=parse_size, default=parse_size("200M"),
                       help="ignore items smaller than this (default 200M)")
        p.add_argument("--jobs", type=int, default=2, help="parallel fm calls (default 2)")

    def run(self, args: argparse.Namespace, ctx: Context) -> SkillResult:
        root = Path(args.path).expanduser().resolve()
        if not root.is_dir():
            raise SystemExit(f"bibi: not a directory: {args.path}")
        self._free_before, total = disk_usage(root)
        ctx.ui.info(f"Disk: {human(self._free_before)} free of {human(total)}")

        t = time.monotonic()
        ctx.ui.progress(f"Scanning {short(root)} (this can take a minute)...")
        tree = scan(root, depth=args.depth + 1,
                    progress=lambda i, p: ctx.ui.progress(f"Scanning {short(root)}: {i + 1:,} folders  {short(Path(p))[-50:]}"))
        ctx.ui.info(f"Scanned {short(root)}: {human(tree.size)} in {time.monotonic() - t:.0f}s")

        t = time.monotonic()
        cfg = Config(root=root, depth=args.depth, min_size=args.min_size, keep=max(2 * args.top, 6), jobs=args.jobs)
        actions = analyze(tree, args.depth - 1, ctx, cfg)[: args.top]
        reclaim = sum(a.bytes for a in actions if a.kind != "review")
        return SkillResult(
            summary=f"Analyzed with fm in {time.monotonic() - t:.0f}s. Up to {human(reclaim)} reclaimable from the top {len(actions)}.",
            actions=actions,
            notes=[] if root != Path.home() else
                  ["folders macOS protects (Desktop/Documents/Downloads, Mail...) are only measured if your terminal has Full Disk Access"],
        )

    def after_run(self, ctx: Context) -> None:
        free, _ = disk_usage(Path.home())
        ctx.ui.ok(f"Free space: {human(self._free_before)} -> {human(free)} ({human(free - self._free_before)} reclaimed)")
