"""Command line front end: `bibi <command> [arguments]`."""

from __future__ import annotations

import argparse
import sys

from bibi import __version__
from bibi.actions import parse_selection, run_actions
from bibi.llm import FMClient
from bibi.registry import Context, discover
from bibi.ui import UI


def build_parser(skills) -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("-v", "--verbose", action="store_true", help="show model verdicts and debug output")
    common.add_argument("--dry-run", action="store_true", help="show what would run without changing anything")
    common.add_argument("--select", metavar="CHOICE", help="answer the action prompt up front: '1,2,5', 'all' or 'none'")

    parser = argparse.ArgumentParser(prog="bibi", description="Local agent powered by Apple Foundation Models (fm).")
    parser.add_argument("--version", action="version", version=f"bibi {__version__}")
    sub = parser.add_subparsers(dest="command", metavar="command")
    sub.add_parser("list", help="list available commands")
    for name, s in skills.items():
        p = sub.add_parser(name, aliases=s.aliases, help=s.help, description=s.help, parents=[common])
        s.add_arguments(p)
    return parser


def print_list(skills, namespace: str | None = None) -> int:
    print("Commands:")
    current = None
    for name, s in skills.items():
        ns = name.split(".")[0]
        if namespace and ns != namespace:
            continue
        if ns != current:
            print(f"\n  {ns}")
            current = ns
        web = "  [web]" if s.uses_web else ""
        print(f"    {name:<22} {s.help}{web}")
    print("\nRun 'bibi <command> --help' for details. [web] = may contact internet services.")
    return 0


def main(argv: list[str] | None = None) -> int:
    skills = discover()
    argv = sys.argv[1:] if argv is None else argv
    # `bibi storage` (a namespace, not a command) lists that namespace's skills.
    if argv and not argv[0].startswith("-") and argv[0] not in skills and any(
        n.startswith(argv[0] + ".") for n in skills
    ):
        return print_list(skills, argv[0])
    parser = build_parser(skills)
    args = parser.parse_args(argv)

    if args.command in (None, "list"):
        return print_list(skills)
    aliases = {a: n for n, s in skills.items() for a in s.aliases}
    args.command = aliases.get(args.command, args.command)

    ui = UI(verbose=args.verbose)
    ctx = Context(llm=FMClient(), ui=ui, dry_run=args.dry_run, verbose=args.verbose)
    try:
        result = skills[args.command].run(args, ctx)
    except KeyboardInterrupt:
        ui.error("\nInterrupted.")
        return 130

    ui.info(result.summary)
    for note in result.notes:
        ui.info(f"note: {note}")
    if not result.actions:
        ui.info("No actions recommended.")
        return 0

    ui.heading(f"Top {len(result.actions)} recommended actions")
    ui.actions(result.actions)

    choice = args.select
    while True:
        if choice is None:
            if not sys.stdin.isatty():
                ui.info("Not interactive and no --select given; nothing run.")
                return 0
            choice = ui.ask("\nRun which? (e.g. 1,2,5 / all / none): ")
        try:
            picked = parse_selection(choice, len(result.actions))
            break
        except ValueError as e:
            ui.error(str(e))
            if args.select is not None:
                return 2
            choice = None

    if not picked:
        ui.info("Nothing run.")
        return 0
    chosen = [result.actions[i] for i in picked]
    run_actions(chosen, ui, dry_run=args.dry_run)
    after = getattr(skills[args.command], "after_run", None)
    if after and not args.dry_run:
        after(ctx)
    return 0
