#!/usr/bin/env python3
"""Compare the SLP vectorizer's cost decisions of impl/jai with LLVM's, tree by tree.

LLVM side: an assertions build of opt 23.1.5 with -debug-only=SLP (built from the release sources; see NOTES.md
"SLPVectorizer", "Debugging"). jai side: a build with DEBUG_SLP :: true in slp_driver.jai (copy bin/opt to a
separate path, e.g. /tmp/opt_dbg, then switch DEBUG_SLP back off), which prints the same "SLP: Found cost = ..."
lines (one per getTreeCost decision: store chains, lists, reductions) to stdout.

The jai run stops at its first loud failure (e.g. vectorizeTree not ported yet), so its sequence must be a prefix of
LLVM's. Prints every file whose sequence is not.

usage: slp_cost_compare.py LIST [extra opt flags...]
  LIST: one .ll path per line, or a sweep results.tsv (status, file, flags) to use each file's own flags.
env: LLVM_DEBUG_OPT (default /persistent/llvm-rewrite/llvm-23.1.5-assert/bin/opt), JAI_DEBUG_OPT (default /tmp/opt_dbg)
"""
import os, shlex, subprocess, sys
from multiprocessing import Pool

LL = os.environ.get("LLVM_DEBUG_OPT", "/persistent/llvm-rewrite/llvm-23.1.5-assert/bin/opt")
OURS = os.environ.get("JAI_DEBUG_OPT", "/tmp/opt_dbg")

def found(out):
    return [l for l in out.splitlines() if l.startswith("SLP: Found cost")]

def run(job):
    f, extra = job
    try:
        a = subprocess.run([LL, "-passes=slp-vectorizer", "-debug-only=SLP", "-disable-output", f] + extra,
                           capture_output=True, text=True, timeout=120)
        b = subprocess.run([OURS, "-passes=slp-vectorizer", "-S", "-o", "/dev/null", f] + extra,
                           capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return (f, "timeout", "")
    la, lb = found(a.stderr), found(b.stdout)
    for i, x in enumerate(lb):
        if i >= len(la):
            return (f, "extra", "ours #%d: %s (llvm has %d)" % (i, x, len(la)))
        if la[i] != x:
            return (f, "mismatch", "#%d llvm: %s | ours: %s" % (i, la[i], x))
    return (f, "ok", "")

if __name__ == "__main__":
    jobs = []
    for l in open(sys.argv[1]):
        parts = l.rstrip("\n").split("\t")
        if len(parts) >= 3:
            jobs.append((parts[1], shlex.split(parts[2]) + sys.argv[2:]))
        elif parts[0].strip():
            jobs.append((parts[0].strip(), sys.argv[2:]))
    with Pool(max(1, (os.cpu_count() or 2) - 2)) as p:
        res = p.map(run, jobs, chunksize=4)
    bad = [r for r in res if r[1] != "ok"]
    for r in bad:
        print(r[1], r[0], r[2])
    print("total", len(res), "bad", len(bad), file=sys.stderr)
