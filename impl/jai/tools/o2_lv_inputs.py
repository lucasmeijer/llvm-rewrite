#!/usr/bin/env python3
"""Collect the IR that LLVM's -O2 pipeline feeds to loop-vectorize, for every function of the given files.

For each input file runs LLVM's `opt -O2 -print-before=loop-vectorize -print-module-scope` and writes every dumped
module (one per function reaching LoopVectorize) to OUT/<file stem>.<n>.ll, deduplicated by content. The results can
then be swept: `./harness/run sweep --impl jai --passes loop-vectorize 'OUT/*'` does not select files outside tests/,
so use `tools/o2_lv_inputs.py --compare` which runs both opts itself.

Usage: o2_lv_inputs.py OUT FILE...            collect
       o2_lv_inputs.py --compare OUT [OPT]    run LLVM's and our opt -passes=loop-vectorize on OUT/*.ll, report
"""
import hashlib, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

LLVM = "/opt/llvm-23.1.5/bin"


def collect(out, files):
    os.makedirs(out, exist_ok=True)
    seen = set()

    def one(f):
        p = subprocess.run([f"{LLVM}/opt", "-O2", "-print-before=loop-vectorize", "-print-module-scope",
                            "-disable-output", f], capture_output=True, text=True, timeout=600)
        dumps, cur = [], None
        for line in p.stderr.splitlines(keepends=True):
            if line.startswith("; *** IR Dump Before"):
                if cur is not None: dumps.append("".join(cur))
                cur = []
            elif cur is not None:
                cur.append(line)
        if cur: dumps.append("".join(cur))
        return f, dumps

    n = 0
    with ThreadPoolExecutor(16) as ex:
        for f, dumps in ex.map(one, files):
            stem = f.replace("/", "_").removesuffix(".ll")
            for i, d in enumerate(dumps):
                h = hashlib.sha1(d.encode()).hexdigest()
                if h in seen: continue
                seen.add(h)
                with open(f"{out}/{stem}.{i}.ll", "w") as fh: fh.write(d)
                n += 1
    print(f"{n} modules in {out}")


def compare(out, ours):
    files = sorted(os.path.join(out, f) for f in os.listdir(out) if f.endswith(".ll"))

    def canon(text):
        p = subprocess.run(f"{LLVM}/llvm-as | {LLVM}/llvm-dis", shell=True, input=text, capture_output=True, text=True)
        return p.stdout if p.returncode == 0 else None

    def one(f):
        a = subprocess.run([f"{LLVM}/opt", "-passes=loop-vectorize", "-S", f], capture_output=True, text=True)
        try:
            b = subprocess.run([ours, "-passes=loop-vectorize", "-S", f], capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            return f, "failed", "timeout"
        if b.returncode != 0:
            err = next((l for l in b.stderr.splitlines() if "error" in l), b.stderr.strip().splitlines()[-1:] or ["?"])
            return f, "failed", err if isinstance(err, str) else err[0]
        ca, cb = canon(a.stdout), canon(b.stdout)
        if cb is None: return f, "bad-ir", ""
        return f, ("identical" if ca == cb else "differs"), ""

    res = {}
    with ThreadPoolExecutor(16) as ex:
        for f, st, err in ex.map(one, files):
            res.setdefault(st, []).append((f, err))
    for st, l in sorted(res.items()):
        print(f"{st}: {len(l)}")
    groups = {}
    for f, err in res.get("failed", []): groups.setdefault(err, []).append(f)
    for err, l in sorted(groups.items(), key=lambda x: -len(x[1])):
        print(f"  {len(l):4}  {err}\n        e.g. {l[0]}")
    for f, _ in res.get("differs", []) + res.get("bad-ir", []): print("  DIFF", f)


if __name__ == "__main__":
    if sys.argv[1] == "--compare":
        compare(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.dirname(__file__), "../bin/opt"))
    else:
        collect(sys.argv[1], sys.argv[2:])
