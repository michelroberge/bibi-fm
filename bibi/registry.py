"""Skill registry: skills declare themselves with @skill and are auto-discovered.

Skill names are namespaced with dots ("storage.optimize", "net.identify"); the
namespace is the package under bibi/skills/ the skill lives in."""

from __future__ import annotations

import argparse
import importlib
import pkgutil
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from bibi.actions import Action
    from bibi.llm import LLM
    from bibi.ui import UI


@dataclass
class Context:
    """Everything a skill may use. Front ends (CLI today, web/chat later) build one of these."""

    llm: LLM
    ui: UI
    dry_run: bool = False
    verbose: bool = False


@dataclass
class SkillResult:
    summary: str
    actions: list[Action] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


class Skill:
    name: str = ""
    help: str = ""
    aliases: list[str] = []
    uses_web: bool = False  # True if the skill sends data to internet services

    def add_arguments(self, parser: argparse.ArgumentParser) -> None:
        """Declare skill-specific arguments."""

    def run(self, args: argparse.Namespace, ctx: Context) -> SkillResult:
        raise NotImplementedError


_SKILLS: dict[str, Skill] = {}


def skill(name: str, help: str = "", aliases: list[str] | None = None, uses_web: bool = False):
    """Class decorator registering a Skill under a dotted command name."""

    def register(cls: type[Skill]) -> type[Skill]:
        inst = cls()
        inst.name, inst.help, inst.aliases, inst.uses_web = name, help, aliases or [], uses_web
        _SKILLS[name] = inst
        return cls

    return register


def discover() -> dict[str, Skill]:
    import bibi.skills as pkg

    for mod in pkgutil.walk_packages(pkg.__path__, pkg.__name__ + "."):
        importlib.import_module(mod.name)
    return dict(sorted(_SKILLS.items()))
