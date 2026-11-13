"""Test discovery. A test file is any .ll under tests/. Its header directives decide which checks it has.

Directives are comment lines `; @key: value` in the file's leading comment block:

  @opt: <opt args>      IR->IR check `::opt` (repeatable; all must match). With @llc, at most one.
  @analysis: <opt args> analysis-printer check `::analysis` (repeatable; all must match): `opt <args> -disable-output`,
                        stdout and stderr compared
  @analysis-unordered: <opt args>   the same, but lines are compared as sorted multisets: for printers that iterate
                        in pointer order (e.g. print<demanded-bits>; LLVM's own tests use CHECK-DAG for them)
  @llc: <llc args>      enables `::isel-ir` and `::run`
  @driver: <path.c>     C driver linked with the compiled IR for `::run` (function tests)
  @source: <path.c>     C file the IR was generated from (informational, used for UB validation)
  @perf: <tool> <args>  compile-time benchmark for `harness/run perf` (repeatable; tool is opt or llc). Not a check.
  @perf-size: <n>       problem size of a tests/perf/scaling/ file, for fitting how cost grows with n
  @origin / @generated  provenance (informational)

Every file also has `::roundtrip`. A test ID is `<repo-relative path>::<check>`.

Multi-module (LTO) tests: a directory under tests/lto/ that contains a manifest `test.lto` (same `; @key: value` lines)
is one test whose path is the directory. Its modules are .ll files in that directory, which are ordinary test files
too (each has `::roundtrip`, and `::opt` for its pre-link @opt line). Manifest directives:

  @modules: a.ll b.ll   link order (required); file names relative to the directory
  @link: <args>         extra llvm-link arguments (optional)
  @opt: <opt args>      the post-link pipeline, `::opt` (repeatable), e.g. -passes='internalize,lto<O2>' ...
  @llc: <llc args>      enables `::run`
  @source / @generated  provenance (informational)

Checks: `::link` (always), `::opt` (if @opt), `::run` (if @llc). See docs/testing.md and checks.py.
"""

import fnmatch
import re
from dataclasses import dataclass, field
from pathlib import Path

from . import config

DIRECTIVE = re.compile(r"^;\s*@([a-z][a-z-]*):\s*(.*?)\s*$")
CHECKS = ("roundtrip", "link", "opt", "analysis", "isel-ir", "run")
LTO_MANIFEST = "test.lto"


@dataclass
class TestFile:
    path: str  # repo-relative
    opt: list[str] = field(default_factory=list)
    analysis: list[tuple[str, bool]] = field(default_factory=list)  # (opt args, unordered)
    llc: str | None = None
    driver: str | None = None
    source: str | None = None
    perf: list[str] = field(default_factory=list)
    perf_size: int | None = None
    modules: list[str] | None = None  # LTO test (path = directory): repo-relative module paths in link order
    link: str = ""  # LTO test: extra llvm-link arguments

    @property
    def is_lto(self) -> bool:
        return self.modules is not None

    def checks(self) -> list[str]:
        if self.is_lto:
            return ["link"] + (["opt"] if self.opt else []) + (["run"] if self.llc is not None else [])
        out = ["roundtrip"]
        if self.opt:
            out.append("opt")
        if self.analysis:
            out.append("analysis")
        if self.llc is not None:
            out += ["isel-ir", "run"]
        return out

    def ids(self) -> list[str]:
        return [f"{self.path}::{c}" for c in self.checks()]


def parse(path: Path) -> TestFile:
    if path.is_dir() or path.name == LTO_MANIFEST:
        return parse_lto(path if path.is_dir() else path.parent)
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
            elif key in ("analysis", "analysis-unordered"):
                t.analysis.append((val, key == "analysis-unordered"))
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


def parse_lto(d: Path) -> TestFile:
    rel = str(d.relative_to(config.REPO))
    t = TestFile(rel, modules=[])
    for line in (d / LTO_MANIFEST).read_text(encoding="utf-8", errors="replace").splitlines():
        m = DIRECTIVE.match(line.strip())
        if not m:
            continue
        key, val = m.groups()
        if key == "modules":
            t.modules += [f"{rel}/{x}" for x in val.split()]
        elif key == "link":
            t.link = val
        elif key == "opt":
            t.opt.append(val)
        elif key == "llc":
            t.llc = val
        elif key == "source":
            t.source = val
    if len(t.modules) < 1:
        raise ValueError(f"{rel}/{LTO_MANIFEST}: needs a @modules line")
    for mod in t.modules:
        if not (config.REPO / mod).is_file():
            raise ValueError(f"{rel}/{LTO_MANIFEST}: module {mod} does not exist")
    if t.llc is not None and len(t.opt) > 1:
        raise ValueError(f"{rel}: a test with @llc may have at most one @opt")
    return t


def discover() -> list[TestFile]:
    files = [parse(p) for p in sorted(config.TESTS.rglob("*.ll"))]
    lto = [parse_lto(p.parent) for p in sorted(config.TESTS.rglob(LTO_MANIFEST))]
    return files + lto


def split_id(test_id: str) -> tuple[str, str]:
    path, check = test_id.rsplit("::", 1)
    return path, check


def match(test_id: str, globs: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(test_id, g) or fnmatch.fnmatchcase(test_id.split("::")[0], g) for g in globs)
