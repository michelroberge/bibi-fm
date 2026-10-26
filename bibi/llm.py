"""Thin client over the `fm` CLI (Apple on-device Foundation Model).

Every call is independent and stateless; callers keep prompts small because the
on-device model has a ~4k token context.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Protocol


class LLMError(RuntimeError):
    pass


class LLM(Protocol):
    def respond(self, prompt: str, instructions: str, schema: dict) -> dict: ...


class FMClient:
    def __init__(self, binary: str = "fm", timeout: float = 90, retries: int = 1, greedy: bool = True):
        self.binary, self.timeout, self.retries, self.greedy = binary, timeout, retries, greedy
        self._schema_dir = Path(tempfile.gettempdir()) / "bibi-schemas"

    def _schema_file(self, schema: dict) -> Path:
        text = json.dumps(schema, sort_keys=True)
        path = self._schema_dir / f"{hashlib.sha1(text.encode()).hexdigest()[:16]}.json"
        if not path.exists():
            self._schema_dir.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        return path

    def respond(self, prompt: str, instructions: str, schema: dict) -> dict:
        cmd = [self.binary, "respond", "--no-stream", "--schema", str(self._schema_file(schema)), "-i", instructions]
        if self.greedy:
            cmd.append("--greedy")
        cmd.append(prompt)
        env = {**os.environ, "NO_COLOR": "1"}
        last = "no attempt"
        for _ in range(self.retries + 1):
            try:
                proc = subprocess.run(cmd, capture_output=True, text=True, timeout=self.timeout, env=env)
            except subprocess.TimeoutExpired:
                last = f"timed out after {self.timeout}s"
                continue
            if proc.returncode != 0:
                last = (proc.stderr or proc.stdout).strip()[:300]
                continue
            out = proc.stdout
            start, end = out.find("{"), out.rfind("}")
            if start == -1 or end == -1:
                last = f"no JSON in output: {out[:200]!r}"
                continue
            try:
                return json.loads(out[start : end + 1])
            except json.JSONDecodeError as e:
                last = f"bad JSON: {e}"
        raise LLMError(f"fm failed: {last}")
