"""Fixed paths and the pinned LLVM version. The workspace image provides all of these."""

import os
from pathlib import Path

LLVM_VERSION = "23.1.5"
LLVM_ROOT = Path(f"/opt/llvm-{LLVM_VERSION}")
LLVM_BIN = LLVM_ROOT / "bin"
LLVM_SRC = Path(f"/opt/llvm-project-{LLVM_VERSION}")
TEST_SUITE_SRC = Path(f"/opt/llvm-test-suite-{LLVM_VERSION}")

REPO = Path(__file__).resolve().parents[2]
TESTS = REPO / "tests"
IMPLS = REPO / "impl"
OUT = REPO / ".harness-out"
ROADMAP = REPO / "docs" / "roadmap.md"

PERSISTENT_CACHE = Path("/persistent/llvm-rewrite/oracle-cache")
LOCAL_CACHE = REPO / ".cache" / "oracle"

TRIPLE = "x86_64-unknown-linux-gnu"
ISEL_PASS = "x86-isel"

TOOL_TIMEOUT = 120  # wall seconds, for LLVM's own tools and clang (the oracle side)
# Our implementations' tools are limited by CPU time (user+sys), which load hardly changes, with a wall-clock backstop
# of TOOL_WALL_FACTOR x that for tools that hang without computing. See proc.run_limited and docs/testing.md.
# 240: jai's unoptimized check build needs ~115 CPU s for tests/perf/scaling/calls/n8000.ll -O2, and CPU time still
# grows somewhat on a loaded machine (shared cores and caches).
TOOL_CPU_LIMIT = float(os.environ.get("LRH_CPU_LIMIT", 240))
TOOL_WALL_FACTOR = 4
# Machine-wide job slots shared by every harness process (proc.job_slot; LRH_MAX_JOBS sets how many, default nproc).
# /tmp, not /persistent: the limit is per machine, and /persistent is shared between workspaces on other machines.
JOBS_DIR = Path(os.environ.get("LRH_JOBS_DIR", "/tmp/lrh-jobs"))
RUN_TIMEOUT = 10  # seconds, for running a compiled test program

# The impl named "llvm" is LLVM itself; used to self-test the harness and corpus.
REFERENCE_IMPL = "llvm"


def cache_dir() -> Path:
    if PERSISTENT_CACHE.parent.parent.is_dir() and os.access(PERSISTENT_CACHE.parent.parent, os.W_OK):
        return PERSISTENT_CACHE
    return LOCAL_CACHE


def llvm(tool: str) -> str:
    return str(LLVM_BIN / tool)


def impl_bin(impl: str, tool: str) -> str:
    if impl == REFERENCE_IMPL:
        return llvm(tool)
    return str(IMPLS / impl / "bin" / tool)


def impls() -> list[str]:
    return sorted(p.name for p in IMPLS.iterdir() if p.is_dir())
