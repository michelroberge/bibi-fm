"""Terminal UI. The only module that reads stdin or writes to the terminal."""

from __future__ import annotations

import itertools
import os
import sys
import threading
import time

from bibi.actions import Action


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit in ("B", "KB") else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


class UI:
    def __init__(self, verbose: bool = False):
        self.verbose = verbose
        self.color = sys.stdout.isatty() and "NO_COLOR" not in os.environ
        self._lock = threading.Lock()
        self._progress_shown = False
        self._msg: str | None = None  # current progress message; the spinner thread animates it
        self._started = 0.0
        self._spinner: threading.Thread | None = None

    def _c(self, code: str, s: str) -> str:
        return f"\033[{code}m{s}\033[0m" if self.color else s

    def _clear_progress(self) -> None:
        if self._progress_shown:
            sys.stderr.write("\r\033[K")
            sys.stderr.flush()
            self._progress_shown = False

    def _spin(self) -> None:
        for frame in itertools.cycle("|/-\\"):
            with self._lock:
                if self._msg is not None:
                    width = os.get_terminal_size(sys.stderr.fileno()).columns - 1
                    line = f"{frame} {self._msg}  ({time.monotonic() - self._started:.0f}s)"
                    sys.stderr.write("\r\033[K" + line[:width])
                    sys.stderr.flush()
                    self._progress_shown = True
            time.sleep(0.1)

    def progress(self, msg: str) -> None:
        """Show msg next to a spinner until the next info/ok/error/heading line. Cheap to call often."""
        if not sys.stderr.isatty():
            return
        with self._lock:
            if self._msg is None:
                self._started = time.monotonic()
            self._msg = msg
            if self._spinner is None:
                self._spinner = threading.Thread(target=self._spin, daemon=True)
                self._spinner.start()

    def _print(self, s: str, end_progress: bool = True) -> None:
        with self._lock:
            if end_progress:
                self._msg = None
            self._clear_progress()
            print(s, flush=True)

    def info(self, s: str) -> None:
        self._print(s)

    def debug(self, s: str) -> None:
        if self.verbose:
            self._print(self._c("2", s), end_progress=False)

    def ok(self, s: str) -> None:
        self._print(self._c("32", s))

    def error(self, s: str) -> None:
        self._print(self._c("31", s))

    def heading(self, s: str) -> None:
        self._print("\n" + self._c("1", s))

    def actions(self, actions: list[Action]) -> None:
        for i, a in enumerate(actions, 1):
            self._print(f"{self._c('1', f'{i:>2}.')} {self._c('1', a.title)}")
            size = f"{human(a.bytes)}  ·  " if a.bytes else ""
            self._print(f"    {size}safety {a.safety}/10  ·  confidence {a.confidence}/10")
            self._print(f"    why: {a.reason}")
            self._print(self._c("2", f"    cmd: {a.command}"))

    def ask(self, prompt: str) -> str:
        with self._lock:
            self._msg = None
            self._clear_progress()
        try:
            return input(self._c("36", prompt))
        except EOFError:
            return ""
