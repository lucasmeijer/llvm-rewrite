"""Subprocess helpers and the content-addressed oracle cache."""

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from . import config


@dataclass
class Res:
    rc: int  # negative = killed by signal; 124 = timeout
    out: bytes
    err: bytes
    timed_out: bool = False

    @property
    def ok(self) -> bool:
        return self.rc == 0 and not self.timed_out

    def err_tail(self, n: int = 2000) -> str:
        return self.err.decode(errors="replace")[-n:]


def run(cmd: list[str], *, cwd=None, stdin: bytes | None = None, timeout: float = config.TOOL_TIMEOUT) -> Res:
    try:
        p = subprocess.run(
            cmd,
            cwd=cwd,
            input=stdin if stdin is not None else b"",
            capture_output=True,
            timeout=timeout,
        )
        return Res(p.returncode, p.stdout, p.stderr)
    except subprocess.TimeoutExpired as e:
        return Res(124, e.stdout or b"", (e.stderr or b"") + f"\n[harness] timed out after {timeout}s".encode(), True)
    except OSError as e:
        return Res(127, b"", f"[harness] could not execute {cmd[0]}: {e}".encode())


def sha(*parts) -> str:
    h = hashlib.sha256()
    for p in parts:
        if isinstance(p, str):
            p = p.encode()
        elif not isinstance(p, bytes):
            p = json.dumps(p, sort_keys=True).encode()
        h.update(len(p).to_bytes(8, "little"))
        h.update(p)
    return h.hexdigest()


def cached(key_parts: list, compute) -> dict:
    """Memoize compute() -> dict of JSON-serialisable values, keyed by LLVM version + key_parts.

    Entries are written atomically (temp file + rename), so concurrent workspaces can share the cache.
    """
    key = sha(config.LLVM_VERSION, *key_parts)
    d = config.cache_dir() / key[:2]
    f = d / f"{key}.json"
    if f.exists():
        return json.loads(f.read_text())
    val = compute()
    d.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    with os.fdopen(fd, "w") as fh:
        json.dump(val, fh)
    os.replace(tmp, f)
    return val


class Workdir:
    """A temporary directory for one check; removed afterwards."""

    def __enter__(self) -> Path:
        self.path = Path(tempfile.mkdtemp(prefix="lrh-"))
        return self.path

    def __exit__(self, *exc):
        shutil.rmtree(self.path, ignore_errors=True)
