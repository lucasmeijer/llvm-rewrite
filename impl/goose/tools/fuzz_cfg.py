#!/usr/bin/env python3
"""Random-CFG differential test of the CFG analyses against LLVM's opt.

Generates functions with random control flow (branches, switches, self loops, unreachable regions, PHIs) and
compares `opt -passes=<p> -disable-output` stderr between LLVM and impl/goose/bin/opt for pipelines that print
dominator trees, post-dominator trees, loops and cycles, before and after transforms that update the trees
incrementally (break-crit-edges, adce). Usage: tools/fuzz_cfg.py [count] [seed]. Failing inputs are kept in
/tmp/fuzz_cfg/.
"""
import os, random, subprocess, sys

LLVM_OPT = "/opt/llvm-23.1.5/bin/opt"
OUR_OPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "opt")
PIPES = [
    "print<domtree>",
    "print<postdomtree>",
    "print<loops>",
    "print<cycles>",
    "print<loops>,print<domtree>",
    "require<domtree>,break-crit-edges,print<domtree>",
    "require<domtree>,require<loops>,break-crit-edges,print<loops>,print<domtree>",
    "require<domtree>,require<cycles>,break-crit-edges,print<cycles>",
    "require<domtree>,adce,print<domtree>",
    "adce,print<postdomtree>",
    "require<domtree>,adce,print<domtree>,print<postdomtree>,print<loops>",
    "adce,break-crit-edges,print<postdomtree>,print<domtree>",
    "loop-simplify,print<loops>,print<domtree>",
    "require<loops>,break-crit-edges,print<loops>",
]
# Pipelines whose IR output (-S) is compared, after canonicalizing ours through LLVM's opt -S.
IR_PIPES = ["loop-simplify", "lcssa", "loop-simplify,lcssa", "break-crit-edges", "adce"]


def gen(rng):
    n = rng.randint(2, 11)
    names = ["b%d" % i for i in range(n)]
    nargs = 4
    terms = []
    for i in range(n):
        r = rng.random()
        if r < 0.15:
            terms.append(("ret",))
        elif r < 0.2:
            terms.append(("unreachable",))
        elif r < 0.45:
            terms.append(("br", rng.randrange(1, n)))
        elif r < 0.85:
            terms.append(("condbr", rng.randrange(nargs), rng.randrange(1, n), rng.randrange(1, n)))
        else:
            k = rng.randint(1, 4)
            terms.append(("switch", rng.randrange(1, n), [rng.randrange(1, n) for _ in range(k)]))
    succs = []
    for t in terms:
        if t[0] == "br":
            succs.append([t[1]])
        elif t[0] == "condbr":
            succs.append([t[2], t[3]])
        elif t[0] == "switch":
            succs.append([t[1]] + t[2])
        else:
            succs.append([])
    preds = [[] for _ in range(n)]
    for i, ss in enumerate(succs):
        for s in ss:
            preds[s].append(i)
    # dominators (iterative), to place uses of %v<i> only where its block dominates
    reach = {0}
    stack = [0]
    while stack:
        x = stack.pop()
        for y in succs[x]:
            if y not in reach:
                reach.add(y)
                stack.append(y)
    dom = {i: set(reach) for i in reach}
    dom[0] = {0}
    changed = True
    while changed:
        changed = False
        for i in reach:
            if i == 0:
                continue
            ps = [p for p in preds[i] if p in reach]
            nd = set.intersection(*[dom[p] for p in ps]) | {i} if ps else {i}
            if nd != dom[i]:
                dom[i] = nd
                changed = True
    uses_in = [[] for _ in range(n)]
    for i in reach:
        if rng.random() < 0.5:
            cands = [j for j in reach if i in dom[j]]
            for _ in range(rng.randint(1, 3)):
                uses_in[rng.choice(cands)].append(i)
    out = ["declare void @g(i32)", ""]
    args = ", ".join("i1 %%c%d" % k for k in range(nargs))
    out.append("define void @f(%s, i32 %%x) {" % args)
    for i in range(n):
        out.append("%s:" % names[i])
        if i > 0 and preds[i] and rng.random() < 0.4:
            inc = ", ".join("[ %d, %%%s ]" % (p * 3 + i, names[p]) for p in preds[i])
            out.append("  %%p%d = phi i32 %s" % (i, inc))
            if rng.random() < 0.5:
                out.append("  call void @g(i32 %%p%d)" % i)
        elif rng.random() < 0.3:
            out.append("  call void @g(i32 %d)" % i)
        if i > 0 and rng.random() < 0.03:
            # a use of some PHI defined elsewhere (dropped by the LLVM validity check when it doesn't dominate)
            out.append("  call void @g(i32 %%p%d)" % rng.randrange(1, n))
        if any(i in uses_in[j] for j in range(n)):
            out.append("  %%v%d = add i32 %%x, %d" % (i, i))
        for d in uses_in[i]:
            out.append("  call void @g(i32 %%v%d)" % d)
        t = terms[i]
        if t[0] == "ret":
            out.append("  ret void")
        elif t[0] == "unreachable":
            out.append("  unreachable")
        elif t[0] == "br":
            out.append("  br label %%%s" % names[t[1]])
        elif t[0] == "condbr":
            out.append("  br i1 %%c%d, label %%%s, label %%%s" % (t[1], names[t[2]], names[t[3]]))
        else:
            cases = " ".join("i32 %d, label %%%s" % (k, names[d]) for k, d in enumerate(t[2]))
            out.append("  switch i32 %%x, label %%%s [ %s ]" % (names[t[1]], cases))
    out.append("}")
    return "\n".join(out) + "\n"


def run(opt, pipe, path):
    p = subprocess.run([opt, "-passes=" + pipe, "-disable-output", path], capture_output=True, text=True, timeout=20)
    return p.returncode, p.stdout + p.stderr


def run_ir(opt, pipe, path):
    p = subprocess.run([opt, "-passes=" + pipe, "-S", path], capture_output=True, text=True, timeout=20)
    if p.returncode != 0:
        return p.returncode, p.stderr
    q = subprocess.run([LLVM_OPT, "-S", "-"], input=p.stdout, capture_output=True, text=True, timeout=20)
    return q.returncode, q.stdout + q.stderr


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    rng = random.Random(seed)
    os.makedirs("/tmp/fuzz_cfg", exist_ok=True)
    stats = {"same": 0, "diff": 0, "unsupported": 0, "invalid": 0}
    for it in range(count):
        src = gen(rng)
        path = "/tmp/fuzz_cfg/cur.ll"
        with open(path, "w") as f:
            f.write(src)
        for pipe in PIPES:
            lc, lo = run(LLVM_OPT, pipe, path)
            if lc != 0:
                stats["invalid"] += 1
                continue
            oc, oo = run(OUR_OPT, pipe, path)
            if oc != 0 and "not ported" in oo:
                stats["unsupported"] += 1
                continue
            if oc == lc and oo == lo:
                stats["same"] += 1
                continue
            stats["diff"] += 1
            keep = "/tmp/fuzz_cfg/fail_%d_%d.ll" % (seed, it)
            with open(keep, "w") as f:
                f.write("; @analysis: -passes='%s'\n" % pipe + src)
            print("DIFF %s  %s" % (keep, pipe))
            break
        for pipe in IR_PIPES:
            lc, lo = run_ir(LLVM_OPT, pipe, path)
            if lc != 0:
                stats["invalid"] += 1
                continue
            oc, oo = run_ir(OUR_OPT, pipe, path)
            if oc != 0 and "not ported" in oo:
                stats["unsupported"] += 1
                continue
            if oc == lc and oo == lo:
                stats["same"] += 1
                continue
            stats["diff"] += 1
            keep = "/tmp/fuzz_cfg/fail_ir_%d_%d.ll" % (seed, it)
            with open(keep, "w") as f:
                f.write("; @opt: -passes=%s\n" % pipe + src)
            print("DIFF %s  %s" % (keep, pipe))
            break
    print(stats)


if __name__ == "__main__":
    main()
