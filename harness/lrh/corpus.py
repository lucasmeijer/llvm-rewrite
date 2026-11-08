"""Test discovery. A test file is any .ll under tests/. Its header directives decide which checks it has.

Directives are comment lines `; @key: value` in the file's leading comment block:

  @opt: <opt args>      IR->IR check `::opt` (repeatable; all must match). With @llc, at most one.
  @llc: <llc args>      enables `::isel-ir` and `::run`
  @driver: <path.c>     C driver linked with the compiled IR for `::run` (function tests)
  @source: <path.c>     C file the IR was generated from (informational, used for UB validation)
  @perf: <tool> <args>  compile-time benchmark for `harness/run perf` (repeatable; tool is opt or llc). Not a check.
  @perf-size: <n>       problem size of a tests/perf/scaling/ file, for fitting how cost grows with n
  @origin / @generated  provenance (informational)

Every file also has `::roundtrip`. A test ID is `<repo-relative path>::<check>`.
"""

import fnmatch
import re
from dataclasses import dataclass, field
from pathlib import Path

from . import config

DIRECTIVE = re.compile(r"^;\s*@([a-z][a-z-]*):\s*(.*?)\s*$")
CHECKS = ("roundtrip", "opt", "isel-ir", "run")


@dataclass
class TestFile:
    path: str  # repo-relative
    opt: list[str] = field(default_factory=list)
    llc: str | None = None
    driver: str | None = None
    source: str | None = None
    perf: list[str] = field(default_factory=list)
    perf_size: int | None = None

    def checks(self) -> list[str]:
        out = ["roundtrip"]
        if self.opt:
            out.append("opt")
        if self.llc is not None:
            out += ["isel-ir", "run"]
        return out

    def ids(self) -> list[str]:
        return [f"{self.path}::{c}" for c in self.checks()]


def parse(path: Path) -> TestFile:
    rel = str(path.relative_to(config.REPO))
    t = TestFile(rel)
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            s = line.strip()
            if s and not s.startswith(";"):
                break
            m = DIRECTIVE.match(s)
            if not m:
                continue
            key, val = m.groups()
            if key == "opt":
                t.opt.append(val)
            elif key == "llc":
                t.llc = val
            elif key == "driver":
                t.driver = val
            elif key == "source":
                t.source = val
            elif key == "perf":
                t.perf.append(val)
            elif key == "perf-size":
                t.perf_size = int(val)
    if t.llc is not None and len(t.opt) > 1:
        raise ValueError(f"{rel}: a test with @llc may have at most one @opt")
    return t


def discover() -> list[TestFile]:
    return [parse(p) for p in sorted(config.TESTS.rglob("*.ll"))]


def split_id(test_id: str) -> tuple[str, str]:
    path, check = test_id.rsplit("::", 1)
    return path, check


def match(test_id: str, globs: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(test_id, g) or fnmatch.fnmatchcase(test_id.split("::")[0], g) for g in globs)
