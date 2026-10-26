"""Disk scanning: one `du` pass builds an in-memory size tree."""

from __future__ import annotations

import os
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable


@dataclass
class Node:
    path: Path
    size: int  # bytes on disk
    is_dir: bool = False
    mtime: float = 0.0
    children: list[Node] = field(default_factory=list)

    @property
    def age_days(self) -> int:
        return int((time.time() - self.mtime) / 86400) if self.mtime else -1


def disk_usage(path: str | Path = "/") -> tuple[int, int]:
    """(free, total) bytes for the volume holding path."""
    u = shutil.disk_usage(path)
    return u.free, u.total


def scan(root: Path, depth: int, min_keep: int = 1 << 20, progress: Callable[[int, str], None] | None = None) -> Node:
    """Run `du -d depth` once (directories), add large files found in those directories,
    and return the root Node with children sorted by size.

    Entries smaller than min_keep are dropped to keep the tree small. Unreadable
    directories (permissions / TCC) are silently skipped by du, so sizes are a lower bound.
    """
    root = Path(os.path.abspath(os.path.expanduser(root)))
    sizes: dict[str, int] = {}
    with subprocess.Popen(
        ["du", "-k", "-d", str(depth), str(root)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        errors="surrogateescape",
    ) as proc:
        assert proc.stdout is not None
        for i, line in enumerate(proc.stdout):
            size_s, _, p = line.rstrip("\n").partition("\t")
            try:
                size = int(size_s) * 1024
            except ValueError:
                continue
            if size >= min_keep or p == str(root):
                sizes[p] = size
            if progress:
                progress(i, p)

    nodes: dict[str, Node] = {}
    for p, size in sizes.items():
        try:
            mtime = os.lstat(p).st_mtime
        except OSError:
            mtime = 0.0
        nodes[p] = Node(Path(p), size, True, mtime)
    # macOS du can't combine -a with -d, so pick up large files with a shallow listing.
    for p in list(nodes):
        try:
            with os.scandir(p) as it:
                entries = list(it)
        except OSError:
            continue
        for e in entries:
            try:
                if e.is_file(follow_symlinks=False):
                    st = e.stat(follow_symlinks=False)
                    if st.st_blocks * 512 >= min_keep:
                        nodes[e.path] = Node(Path(e.path), st.st_blocks * 512, False, st.st_mtime)
            except OSError:
                continue
    root_key = str(root)
    if root_key not in nodes:
        nodes[root_key] = Node(root, 0, True, 0.0)
    for p, node in nodes.items():
        if p != root_key:
            parent = nodes.get(os.path.dirname(p))
            if parent is not None:
                parent.children.append(node)
    for node in nodes.values():
        node.children.sort(key=lambda n: n.size, reverse=True)
    return nodes[root_key]
