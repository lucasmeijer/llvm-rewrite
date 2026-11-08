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

TOOL_TIMEOUT = 120  # seconds, for opt/llc/clang invocations
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
