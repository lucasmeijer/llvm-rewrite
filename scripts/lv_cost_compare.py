#!/usr/bin/env python3
"""Compare LoopVectorize's cost-model decisions of an implementation with LLVM's, loop by loop.
(Shared copy of impl/jai/tools/lv_cost_compare.py; works for any implementation whose opt prints the lines below
when JAI_LV_DEBUG=1 / GOOSE_LV_DEBUG=1 / LV_DEBUG=1 is set.)

LLVM side: the assertions build of opt 23.1.5 with -debug-only=loop-vectorize (NOTES.md "LoopVectorize").
our side: OURS_OPT with JAI_LV_DEBUG=1 GOOSE_LV_DEBUG=1 LV_DEBUG=1, which prints the same decision lines to stderr:
  LV: Scalar loop costs: N.        (expectedCost(VF=1) in computeBestVF)
  Cost for VF V: C                 (LoopVectorizationPlanner::cost; LLVM appends "(Estimated cost per lane: ..)")
  LV: Selecting VF: V.
  LV: Loop cost is N / LV: IC is N (selectInterleaveCount, small-loop path)
and the per-recipe / per-instruction lines ("Cost of C for VF V: ...", "LV: Found an estimated cost of C ...") whose
costs (not texts) are compared to point at the first differing recipe.

Our run stops at its first loud failure, so its decision sequence must be a prefix of LLVM's.

usage: lv_cost_compare.py [-v] FILE...      (each file's "; @opt:" lines give the flags; one run per line)
       lv_cost_compare.py [-v] -l LIST      (LIST: a sweep results.tsv (status, file, flags) or one path per line)
env: LLVM_DEBUG_OPT (default /persistent/llvm-rewrite/llvm-23.1.5-assert/bin/opt), OURS_OPT (or JAI_OPT; required),
     e.g. OURS_OPT=impl/goose/bin/opt scripts/lv_cost_compare.py -l .harness-out/sweep/goose/loop-vectorize/results.tsv
"""
import os, re, shlex, subprocess, sys
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
LL = os.environ.get("LLVM_DEBUG_OPT", "/persistent/llvm-rewrite/llvm-23.1.5-assert/bin/opt")
OURS = os.environ.get("OURS_OPT") or os.environ.get("JAI_OPT")
if not OURS:
    sys.exit("lv_cost_compare.py: set OURS_OPT to the opt to compare (e.g. impl/goose/bin/opt)")

DECISION = re.compile(r"^(LV: Scalar loop costs: .*|Cost for VF [^:]*: \S+|LV: Selecting VF: .*|LV: Loop cost is .*|LV: IC is .*)")
DETAIL = re.compile(r"^(Cost of (\S+) for VF ([^:]*):|LV: Found an estimated cost of (\S+) for VF (\S+) )")

def parse(err):
    dec, det = [], []
    for l in err.splitlines():
        m = DECISION.match(l)
        if m:
            dec.append(m.group(1))
            continue
        m = DETAIL.match(l)
        if m:
            det.append((m.group(2) or m.group(4), m.group(3) or m.group(5), l))
    return dec, det

def run(job):
    f, flags = job
    flags = [x for x in flags if x != "-S"]
    env = dict(os.environ, JAI_LV_DEBUG="1", GOOSE_LV_DEBUG="1", LV_DEBUG="1")
    try:
        a = subprocess.run([LL, "-debug-only=loop-vectorize", "-disable-output", f] + flags,
                           capture_output=True, text=True, timeout=300)
        b = subprocess.run([OURS, "-S", "-o", "/dev/null", f] + flags, capture_output=True, text=True, timeout=300, env=env)
    except subprocess.TimeoutExpired:
        return (f, flags, "timeout", "")
    da, ta = parse(a.stderr)
    db, tb = parse(b.stderr)
    for i, x in enumerate(db):
        if i >= len(da):
            return (f, flags, "extra", "ours #%d: %s (llvm has %d)" % (i, x, len(da)))
        if da[i] != x:
            detail = ""
            for j in range(min(len(ta), len(tb))):
                if ta[j][:2] != tb[j][:2]:
                    detail = "\n    first differing cost line #%d\n      llvm: %s\n      ours: %s" % (j, ta[j][2], tb[j][2])
                    break
            return (f, flags, "mismatch", "#%d llvm: %s | ours: %s%s" % (i, da[i], x, detail))
    loud = b.returncode != 0
    return (f, flags, "ok-prefix" if loud and len(db) < len(da) else "ok", "")

def jobs_for_file(f):
    out = []
    for l in open(f, errors="replace"):
        if l.startswith("; @opt:"):
            out.append((f, shlex.split(l[len("; @opt:"):])))
    return out or [(f, ["-passes=loop-vectorize"])]

if __name__ == "__main__":
    args = sys.argv[1:]
    verbose = "-v" in args
    args = [a for a in args if a != "-v"]
    jobs = []
    if args[:1] == ["-l"]:
        for l in open(args[1]):
            parts = l.rstrip("\n").split("\t")
            if len(parts) >= 3:
                jobs.append((parts[1], shlex.split(parts[2])))
            elif parts[0].strip():
                jobs.extend(jobs_for_file(parts[0].strip()))
    else:
        for f in args:
            jobs.extend(jobs_for_file(f))
    with Pool(max(1, (os.cpu_count() or 2) - 2)) as p:
        res = p.map(run, jobs, chunksize=1)
    bad = [r for r in res if r[2] not in ("ok", "ok-prefix")]
    for r in bad:
        print(r[2], r[0], " ".join(r[1]))
        print("   ", r[3])
    if verbose:
        for r in res:
            if r[2] in ("ok", "ok-prefix"):
                print(r[2], r[0], " ".join(r[1]))
    print("total", len(res), "bad", len(bad), file=sys.stderr)
