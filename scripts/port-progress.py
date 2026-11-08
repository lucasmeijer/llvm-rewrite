#!/usr/bin/env python3
"""Approximate porting progress: share of LLVM middle-end code lines each implementation has ported.

Denominator: non-blank, non-comment lines of the LLVM .cpp files in scope (see SCOPES).
Numerator: lines of the LLVM files an implementation ports. A file counts as ported when it is named in the header
comment (first HEADER_LINES lines) of a source file under impl/<lang>/src/, which AGENTS.md asks every port to do.
That over-counts files that are only partly ported, so impl/<lang>/port-progress.txt may override per file:
    lib/Analysis/ValueTracking.cpp 0.6      # fraction of that file actually ported
Lines starting with '#' are comments. A fraction of 0 marks a file as mentioned but not ported.

Usage: scripts/port-progress.py [--impl goose,jai] [--files]
"""
import argparse
import re
import sys
from pathlib import Path

LLVM = Path("/opt/llvm-project-23.1.5/llvm")
REPO = Path(__file__).resolve().parent.parent
HEADER_LINES = 40

# (label, directories or files under llvm/lib). "passes" is the headline number.
SCOPES = {
    "passes": [
        "Transforms/Scalar", "Transforms/IPO", "Transforms/InstCombine", "Transforms/Utils",
        "Transforms/Vectorize", "Transforms/AggressiveInstCombine", "Transforms/Coroutines", "Analysis",
        "Target/X86/X86TargetTransformInfo.cpp", "Target/X86/X86InstCombineIntrinsic.cpp",
    ],
    "ir-core": ["IR", "AsmParser", "Support/APInt.cpp", "Support/APFloat.cpp", "Support/KnownBits.cpp"],
}

REF = re.compile(r"(?:llvm/)?lib/([A-Za-z0-9_/]+\.cpp)")


def code_lines(path):
    n = 0
    in_block = False
    for line in path.read_text(errors="replace").splitlines():
        s = line.strip()
        if in_block:
            if "*/" in s:
                in_block = False
            continue
        if not s or s.startswith("//"):
            continue
        if s.startswith("/*"):
            in_block = "*/" not in s
            continue
        n += 1
    return n


def scope_files(entries):
    files = {}
    for e in entries:
        p = LLVM / "lib" / e
        for f in ([p] if p.is_file() else sorted(p.rglob("*.cpp"))):
            files[str(f.relative_to(LLVM / "lib"))] = code_lines(f)
    return files


def ported(lang):
    src = REPO / "impl" / lang / "src"
    got = {}
    for f in sorted(src.rglob("*")) if src.is_dir() else []:
        if not f.is_file():
            continue
        try:
            head = "\n".join(f.read_text(errors="replace").splitlines()[:HEADER_LINES])
        except OSError:
            continue
        for m in REF.finditer(head):
            got[m.group(1)] = 1.0
    manifest = REPO / "impl" / lang / "port-progress.txt"
    if manifest.exists():
        for line in manifest.read_text().splitlines():
            line = line.split("#", 1)[0].split()
            if len(line) == 2:
                got[re.sub(r"^(llvm/)?lib/", "", line[0])] = float(line[1])
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--impl", default="goose,jai")
    ap.add_argument("--files", action="store_true", help="list the ported files per scope")
    a = ap.parse_args()
    langs = a.impl.split(",")
    scopes = {k: scope_files(v) for k, v in SCOPES.items()}
    print(f"{'scope':10} {'LLVM lines':>10}  " + "  ".join(f"{l:>16}" for l in langs))
    for name, files in scopes.items():
        total = sum(files.values())
        cells = []
        for l in langs:
            p = ported(l)
            done = sum(n * p.get(f, 0.0) for f, n in files.items())
            cells.append(f"{done:>7.0f} {100 * done / total:5.1f}%  ")
        print(f"{name:10} {total:>10}  " + "  ".join(f"{c:>16}" for c in cells))
    if a.files:
        for l in langs:
            p = ported(l)
            for name, files in scopes.items():
                print(f"\n{l} / {name}:")
                for f, n in sorted(files.items(), key=lambda x: -x[1]):
                    if p.get(f, 0) > 0:
                        print(f"  {n:6d}  x{p[f]:.2f}  {f}")


if __name__ == "__main__":
    sys.exit(main())
