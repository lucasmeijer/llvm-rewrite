#!/usr/bin/env python3
"""Differential fuzzer for goose's InstCombine on random integer/bitwise IR (and/or/xor/shifts/add/sub/mul,
icmp, zext/sext/trunc, a few intrinsics). Compares `opt -passes=instcombine -S` of LLVM and goose after
llvm-as|llvm-dis. Usage: tools/fuzz_ic.py [count] [seed] [-j N] [--vec]. Mismatches go to /tmp/fuzz_ic/."""
import os, random, subprocess, sys, concurrent.futures as cf

LLVM = '/opt/llvm-23.1.5/bin'
HERE = os.path.dirname(os.path.abspath(__file__))
OURS = os.path.join(HERE, '..', 'bin', 'opt')
OUT = '/tmp/fuzz_ic'
INTR = '--intr' in sys.argv

BIN = ['and', 'or', 'xor', 'and', 'or', 'xor', 'add', 'sub', 'shl', 'lshr', 'ashr', 'mul']
PREDS = ['eq', 'ne', 'ult', 'ugt', 'ule', 'uge', 'slt', 'sgt', 'sle', 'sge']

def consts(w):
    m = (1 << w) - 1
    cs = [0, 1, 2, 3, m, m - 1, 1 << (w - 1), (1 << (w - 1)) - 1, 0xF & m, 0xF0 & m, 7, 8, 16 & m, w - 1, w, 0x55 & m, 0xAA & m, -(1 << (w // 2)) & m]
    return cs

def gen(rng, vec):
    w = rng.choice([8, 8, 32, 16])
    ty = f'<2 x i{w}>' if vec else f'i{w}'
    bty = '<2 x i1>' if vec else 'i1'
    def cst(t, width):
        c = rng.choice(consts(width))
        if c >= 1 << (width - 1): c -= 1 << width
        if vec:
            c2 = c if rng.random() < 0.8 else rng.choice(consts(width))
            if c2 >= 1 << (width - 1): c2 -= 1 << width
            return f'<i{width} {c}, i{width} {c2}>' if c2 != c else f'splat (i{width} {c})'
        return str(c)
    vals = [('%a', ty), ('%b', ty), ('%c', ty)]
    bools = [('%p', bty)]
    lines = []
    n = rng.randint(3, 14)
    k = 0
    def pick(t):
        cands = [v for v in vals if v[1] == t] if t != bty else bools
        if not cands or rng.random() < 0.25:
            return cst(t, 1 if t == bty else w)
        return rng.choice(cands[-4:] if rng.random() < 0.6 else cands)[0]
    for _ in range(n):
        k += 1
        nm = f'%v{k}'
        r = rng.random()
        if r < 0.55:
            op = rng.choice(BIN)
            a, b = pick(ty), pick(ty)
            if a.startswith(('<', 's')) or a.lstrip('-').isdigit():
                a, b = b, a
            fl = ''
            if op == 'or' and rng.random() < 0.1: fl = ' disjoint'
            if op in ('add', 'sub', 'shl', 'mul') and rng.random() < 0.2: fl = rng.choice([' nuw', ' nsw', ' nuw nsw'])
            if op in ('lshr', 'ashr') and rng.random() < 0.1: fl = ' exact'
            lines.append(f'  {nm} = {op}{fl} {ty} {a}, {b}')
            vals.append((nm, ty))
        elif r < 0.7:
            p = rng.choice(PREDS)
            lines.append(f'  {nm} = icmp {p} {ty} {pick(ty)}, {pick(ty)}')
            bools.append((nm, bty))
        elif r < 0.82 and len(bools) > 1:
            op = rng.choice(['and', 'or', 'xor'])
            lines.append(f'  {nm} = {op} {bty} {pick(bty)}, {pick(bty)}')
            bools.append((nm, bty))
        elif r < 0.9:
            ext = rng.choice(['zext', 'sext'])
            lines.append(f'  {nm} = {ext} {bty} {pick(bty)} to {ty}')
            vals.append((nm, ty))
        elif INTR:
            iid = rng.choice(['bswap', 'bitreverse', 'ctpop']) if w >= 16 else rng.choice(['bitreverse', 'ctpop'])
            sfx = f'v2i{w}' if vec else f'i{w}'
            lines.append(f'  {nm} = call {ty} @llvm.{iid}.{sfx}({ty} {pick(ty)})')
            vals.append((nm, ty))
    # combine a few results so most of them are used
    res = [v[0] for v in vals[3:]][-3:]
    last = vals[-1][0] if len(vals) > 3 else '%a'
    for j, v in enumerate(res[:-1]):
        k += 1
        lines.append(f'  %r{k} = xor {ty} {last}, {v}')
        last = f'%r{k}'
    bl = bools[-1][0]
    k += 1
    lines.append(f'  %z{k} = zext {bty} {bl} to {ty}')
    lines.append(f'  %out = add {ty} {last}, %z{k}')
    lines.append(f'  ret {ty} %out')
    return f'define {ty} @f({ty} %a, {ty} %b, {ty} %c, {bty} %p) {{\n' + '\n'.join(lines) + '\n}\n'

def canon(text):
    a = subprocess.run([f'{LLVM}/llvm-as', '-o', '-', '-'], input=text.encode(), capture_output=True)
    if a.returncode: return None
    d = subprocess.run([f'{LLVM}/llvm-dis', '-o', '-', '-'], input=a.stdout, capture_output=True)
    return d.stdout.decode()

def one(args):
    seed, vec = args
    rng = random.Random(seed)
    src = gen(rng, vec)
    fn = f'/tmp/fuzz_ic/in{seed}.ll'
    open(fn, 'w').write(src)
    l = subprocess.run([f'{LLVM}/opt', '-S', '-passes=instcombine', fn], capture_output=True, timeout=60)
    if l.returncode: os.remove(fn); return ('llvm-failed', seed, src, '')
    o = subprocess.run([OURS, '-S', '-passes=instcombine', fn], capture_output=True, timeout=60)
    if o.returncode: os.remove(fn); return ('failed', seed, src, o.stderr.decode()[:300])
    os.remove(fn)
    if canon(l.stdout.decode()) != canon(o.stdout.decode()):
        return ('differs', seed, src, '')
    return ('ok', seed, src, '')

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    count = int(args[0]) if args else 500
    seed0 = int(args[1]) if len(args) > 1 else 1
    vec = '--vec' in sys.argv
    j = 16
    if '-j' in sys.argv: j = int(sys.argv[sys.argv.index('-j') + 1])
    os.makedirs(OUT, exist_ok=True)
    stats = {}
    fails = {}
    with cf.ThreadPoolExecutor(j) as ex:
        for st, seed, src, err in ex.map(one, [(seed0 + i, vec) for i in range(count)]):
            stats[st] = stats.get(st, 0) + 1
            if st == 'differs':
                open(f'{OUT}/d{seed}.ll', 'w').write(src)
            if st == 'failed':
                key = err.strip().splitlines()[0] if err.strip() else '?'
                fails[key] = fails.get(key, 0) + 1
                if fails[key] == 1: open(f'{OUT}/f{seed}.ll', 'w').write(src)
    print(stats)
    for k, v in sorted(fails.items(), key=lambda x: -x[1])[:15]: print(f'{v:5d} {k}')

if __name__ == '__main__':
    main()
