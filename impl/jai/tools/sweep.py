#!/usr/bin/env python3
"""Sweep one pipeline over every file that round-trips (impl/jai/passing.txt) and compare with LLVM's opt.

Usage: impl/jai/tools/sweep.py '<pipeline>' [--analysis] [--filter SUBSTR] [--show N] [extra opt args...]
IR mode (default): canonicalized `-S` output (llvm-as | llvm-dis) must be identical. --analysis: stderr of a
`-disable-output` run must be identical. Reports OK / DIFF / JAI-FAIL (our opt failed, first error line counted)
/ LLVM-FAIL. Run from the repository root.
"""
import collections, os, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

LLVM = "/opt/llvm-23.1.5/bin"
OURS = "impl/jai/bin/opt"


def canon(text, d, tag):
    p = os.path.join(d, tag + ".ll")
    with open(p, "w") as f:
        f.write(text)
    a = subprocess.run([LLVM + "/llvm-as", p, "-o", "-"], capture_output=True)
    if a.returncode:
        return None
    return subprocess.run([LLVM + "/llvm-dis", "-", "-o", "-"], input=a.stdout, capture_output=True).stdout


def one(args):
    path, pipe, analysis, extra = args
    with tempfile.TemporaryDirectory() as d:
        if analysis:
            cmd = ["-passes=" + pipe] + extra + ["-disable-output", path]
        else:
            cmd = ["-passes=" + pipe] + extra + ["-S", path]
        try:
            l = subprocess.run([LLVM + "/opt"] + cmd, capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            return path, "LLVM-FAIL", "timeout"
        if l.returncode:
            return path, "LLVM-FAIL", ""
        try:
            o = subprocess.run([OURS] + cmd, capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            return path, "JAI-FAIL", "timeout"
        if o.returncode:
            msg = (o.stderr.strip().splitlines() or ["?"])[0]
            return path, "JAI-FAIL", msg
        if analysis:
            return path, ("OK" if o.stderr == l.stderr else "DIFF"), ""
        a, b = canon(l.stdout, d, "l"), canon(o.stdout, d, "o")
        if b is None:
            return path, "DIFF", "our output does not assemble"
        return path, ("OK" if a == b else "DIFF"), ""


def main():
    argv = sys.argv[1:]
    pipe = argv.pop(0)
    analysis = False
    filt = ""
    show = 20
    extra = []
    while argv:
        a = argv.pop(0)
        if a == "--analysis":
            analysis = True
        elif a == "--filter":
            filt = argv.pop(0)
        elif a == "--show":
            show = int(argv.pop(0))
        else:
            extra.append(a)
    files = sorted({l.split("::")[0] for l in open("impl/jai/passing.txt") if l.strip().endswith("::roundtrip")})
    files = [f for f in files if filt in f]
    res = collections.Counter()
    fails = collections.Counter()
    diffs = []
    failed = []
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
        for path, st, msg in ex.map(one, [(f, pipe, analysis, extra) for f in files]):
            res[st] += 1
            if st == "JAI-FAIL":
                fails[msg[:140]] += 1
                failed.append((path, msg[:140]))
            if st == "DIFF":
                diffs.append(path)
    print(dict(res))
    for d in diffs[:show]:
        print("DIFF", d)
    for m, c in fails.most_common(show):
        print("%5d  %s" % (c, m))
    if os.environ.get("SWEEP_FAILS"):
        for p, m in failed:
            print("FAIL", p, m)


if __name__ == "__main__":
    main()
