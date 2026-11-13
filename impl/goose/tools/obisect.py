#!/usr/bin/env python3
"""Bisect any opt arguments (e.g. `-O2 -enable-loopinterchange=0`) between LLVM and goose on one file.

    impl/goose/tools/obisect.py FILE -- OPT-ARGS...

Like `harness/run bisect` but for arguments that are not a test's @opt line (sweeps). Runs both opts with
-opt-bisect-limit=N, canonicalizes through llvm-as | llvm-dis, binary-searches the first N where they differ and
prints that pass (LLVM's BISECT line) plus the paths of the two inputs/outputs around it in /tmp/obisect/.
"""
import os, subprocess, sys

LLVM = "/opt/llvm-23.1.5/bin"
HERE = os.path.dirname(os.path.abspath(__file__))
GOOSE = os.path.join(HERE, "..", "bin", "opt")
OUT = "/tmp/obisect"


def run(tool, f, args, n):
    p = subprocess.run([tool] + args + [f"-opt-bisect-limit={n}", "-S", f, "-o", "-"], capture_output=True, text=True)
    if p.returncode != 0:
        return None, p.stderr
    c = subprocess.run(f"{LLVM}/llvm-as | {LLVM}/llvm-dis", shell=True, input=p.stdout, capture_output=True, text=True)
    return c.stdout, p.stderr


def main():
    a = sys.argv[1:]
    if "--" not in a:
        sys.exit(__doc__)
    i = a.index("--")
    f, args = a[0], a[i + 1:]
    os.makedirs(OUT, exist_ok=True)
    full, err = run(f"{LLVM}/opt", f, args, -1)
    passes = [l for l in err.splitlines() if l.startswith("BISECT:")]
    total = len(passes)
    lo, hi = 0, total  # outputs agree at lo; find smallest n that differs
    l_hi, _ = run(f"{LLVM}/opt", f, args, hi)
    g_hi, gerr = run(GOOSE, f, args, hi)
    if l_hi == g_hi:
        print(f"identical with all {total} passes")
        return
    while hi - lo > 1:
        mid = (lo + hi) // 2
        l, _ = run(f"{LLVM}/opt", f, args, mid)
        g, _ = run(GOOSE, f, args, mid)
        if l == g:
            lo = mid
        else:
            hi = mid
    print(f"first difference at pass {hi} of {total}: {passes[hi - 1]}")
    for n, tag in ((lo, "before"), (hi, "after")):
        l, _ = run(f"{LLVM}/opt", f, args, n)
        g, ge = run(GOOSE, f, args, n)
        open(f"{OUT}/llvm.{tag}.ll", "w").write(l or "")
        open(f"{OUT}/goose.{tag}.ll", "w").write(g if g is not None else ge)
    print(f"{OUT}/llvm.before.ll (input of the pass), {OUT}/llvm.after.ll vs {OUT}/goose.after.ll")


main()
