#!/usr/bin/env python3
"""Compare the -debug-only=SLP traces of impl/goose's opt with LLVM's (an assertions build of opt 23.1.5).

Both print the same lines (goose's opt accepts -debug-only=SLP and prints the LLVM_DEBUG lines of the ported parts
of SLPVectorizer.cpp on stderr). LLVM prints more kinds of lines than the port, so both traces are filtered to the
line kinds in KINDS (a line starting with "SLP:" opens a block; the following lines without that prefix, e.g. a
TreeEntry dump, belong to it). goose's opt stops at its first loud failure, so its filtered trace must be a prefix
of LLVM's. Prints every file where it is not, with the first differing line.

usage: slp_debug_compare.py LIST [extra opt flags...]
  LIST: one .ll path per line, or a sweep results.tsv (status, file, flags) to use each file's own flags.
env: LLVM_DEBUG_OPT (default /persistent/llvm-rewrite/llvm-23.1.5-assert/bin/opt),
     GOOSE_OPT (default impl/goose/bin/opt next to this script)
"""
import os, shlex, subprocess, sys
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
LL = os.environ.get("LLVM_DEBUG_OPT", "/persistent/llvm-rewrite/llvm-23.1.5-assert/bin/opt")
OURS = os.environ.get("GOOSE_OPT", os.path.join(HERE, "..", "bin", "opt"))

KINDS = [
    "SLP: Analyzing blocks in", "SLP: Found stores for", "SLP: Analyzing a store chain of length",
    "SLP: Trying to vectorize starting at nodes", "SLP: Analyzing ", "SLP: Trying to vectorize a list of length",
    "SLP: Vectorization infeasible", "SLP: added a new TreeEntry", "SLP: split alternate node",
    "SLP: \tChecking bundle", "SLP: Perfect diamond merge", "SLP: Gathering", "SLP: Gather ",
    "SLP: Try split and if failed", "SLP: We are able to schedule", "SLP: We are not able to schedule",
    "SLP: Shuffle for reused scalars", "SLP: Scalar used twice", "SLP: struct type in bundle",
    "SLP: Need to swizzle", "SLP: Non-consecutive store", "SLP: Non-vectorizable call", "SLP: mismatched",
    "SLP: ShuffleVector are not", "SLP: not-vectorizable GEP", "SLP: Reusing or shuffling",
    "SLP: The instructions are in tree", "SLP: The instruction (", "SLP: bundle in ", "SLP: Sibling loops",
    "SLP: Check whether the tree", "SLP: rejecting tree with buildvector",
    "SLP:  bundle:", "SLP:  initialize schedule region", "SLP:  extend schedule region", "SLP:  exceeded schedule",
    "SLP: try schedule bundle", "SLP:       update deps of", "SLP:     gets ready on update", "SLP:   schedule ",
    "SLP:   check for readiness", "SLP:    gets ready:", "SLP:  reset schedule because",
    "SLP:    initially in ready list",
    "SLP: Calculating cost for tree", "SLP: Adding cost", "SLP: Current total cost", "SLP: Calculated costs for Tree",
    "SLP: Calculated GEPs cost for Tree", "SLP: Costs:", "SLP:     ReuseShuffleCost", "SLP:     VectorCost",
    "SLP:     ScalarCost", "SLP: Skipping cost for combined", "SLP: perfect diamond match",
    "SLP: diamond match for alternate", "SLP: alternate extension", "SLP: Need to extract", "SLP: Checking user:",
    "SLP: \tInternal user will be removed", "SLP: Inst count check", "SLP: Rejecting tree:", "SLP: Found cost",
    "SLP: Decided to vectorize", "SLP: Vectorizing list at cost", "SLP: rejecting tree with buildvector struct",
]
# blocks whose order LLVM takes from a pointer-keyed DenseMap: skipped in both traces
SKIP_AFTER = "SLP: Recalculate costs after tree trimming."

def keep(line):
    return any(line.startswith(k) for k in KINDS)

def filt(text):
    out = []
    inblock = False
    skipping = False
    for l in text.splitlines():
        if l.startswith(SKIP_AFTER):
            skipping = True
            inblock = False
            continue
        if skipping:
            if l.startswith("SLP: Adding cost") or l.startswith("SLP: Current total cost"):
                continue
            skipping = False
        if l.startswith("SLP:"):
            inblock = keep(l)
            if inblock:
                out.append(l)
        elif l.startswith("error: ") or l.startswith("opt: ") or l.startswith("LLVM ERROR"):
            inblock = False
        elif inblock:
            out.append(l)
    return out

def run(job):
    f, extra = job
    try:
        a = subprocess.run([LL, "-passes=slp-vectorizer", "-debug-only=SLP", "-disable-output", f] + extra,
                           capture_output=True, text=True, timeout=300)
        b = subprocess.run([OURS, "-passes=slp-vectorizer", "-debug-only=SLP", "-S", "-o", "/dev/null", f] + extra,
                           capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return (f, "timeout", "", 0)
    la, lb = filt(a.stderr), filt(b.stderr)
    for i, x in enumerate(lb):
        if i >= len(la):
            return (f, "extra", "ours #%d: %s (llvm has %d)" % (i, x, len(la)), len(lb))
        if la[i] != x:
            return (f, "mismatch", "#%d\n  llvm: %s\n  ours: %s" % (i, la[i], x), len(lb))
    if b.returncode == 0 and len(lb) != len(la):
        return (f, "short", "ours %d lines, llvm %d (and ours exited 0)" % (len(lb), len(la)), len(lb))
    return (f, "ok", "", len(lb))

if __name__ == "__main__":
    jobs = []
    for l in open(sys.argv[1]):
        parts = l.rstrip("\n").split("\t")
        if len(parts) >= 3:
            jobs.append((parts[1], shlex.split(parts[2]) + sys.argv[2:]))
        elif parts[0].strip():
            jobs.append((parts[0].strip(), sys.argv[2:]))
    with Pool(max(1, (os.cpu_count() or 2) - 2)) as p:
        res = p.map(run, jobs, chunksize=2)
    bad = [r for r in res if r[1] != "ok"]
    for r in bad:
        print(r[1], r[0], r[2])
    print("total", len(res), "bad", len(bad), "compared lines", sum(r[3] for r in res), file=sys.stderr)
