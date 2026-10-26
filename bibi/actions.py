"""Generic recommended actions, the selection grammar, and the executor."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Callable

if TYPE_CHECKING:
    from bibi.ui import UI


@dataclass
class Action:
    title: str
    kind: str
    target: str
    bytes: int
    safety: int  # 0-10, 10 = no risk
    confidence: int  # 0-10
    reason: str
    command: str  # human-readable description of what execute() does
    execute: Callable[[], str] = field(repr=False, compare=False, default=lambda: "nothing to do")
    weight: float = 1.0  # < 1 for actions that don't directly reclaim value (e.g. "review")

    @property
    def score(self) -> float:
        return self.bytes / 1e9 * (self.safety / 10) * (self.confidence / 10) * self.weight


def parse_selection(text: str, count: int) -> list[int]:
    """Parse '1,2,5', '1-3', 'all' or 'none' into 0-based indices."""
    text = text.strip().lower()
    if text in ("", "none", "n", "no", "q"):
        return []
    if text in ("all", "a"):
        return list(range(count))
    picked: list[int] = []
    for part in text.replace(" ", ",").split(","):
        if not part:
            continue
        lo, sep, hi = part.partition("-")
        try:
            nums = range(int(lo), int(hi) + 1) if sep else [int(lo)]
        except ValueError:
            raise ValueError(f"not a number: {part!r}") from None
        for n in nums:
            if not 1 <= n <= count:
                raise ValueError(f"{n} is out of range 1-{count}")
            if n - 1 not in picked:
                picked.append(n - 1)
    return picked


def run_actions(actions: list[Action], ui: UI, dry_run: bool = False) -> None:
    for action in actions:
        if dry_run:
            ui.info(f"[dry-run] {action.title}: {action.command}")
            continue
        ui.info(f"Running: {action.title}")
        try:
            ui.ok(f"  {action.execute()}")
        except Exception as e:  # keep going with the remaining actions
            ui.error(f"  failed: {e}")
