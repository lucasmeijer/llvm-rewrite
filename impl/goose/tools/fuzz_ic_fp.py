#!/usr/bin/env python3
"""Differential fuzzer for goose's InstCombine on random floating-point IR: fneg/fadd/fsub/fmul/fdiv/frem with
random fast-math flags and special constants, selects and fcmps of them, sometimes a nofpclass return.
Compares `opt -passes=instcombine -S` of LLVM and goose after llvm-as|llvm-dis; inputs where goose stops loudly
are counted, not compared. Usage: tools/fuzz_ic_fp.py [count] [seed] [-j N] [--vec]. Mismatches go to
/tmp/fuzz_ic_fp/."""
import os, random, subprocess, sys, concurrent.futures as cf

LLVM = '/opt/llvm-23.1.5/bin'
HERE = os.path.dirname(os.path.abspath(__file__))
OURS = os.path.join(HERE, '..', 'bin', 'opt')
OUT = '/tmp/fuzz_ic_fp'
VEC = '--vec' in sys.argv

BIN = ['fadd', 'fsub', 'fmul', 'fdiv', 'fadd', 'fsub', 'fmul', 'frem']
FLAGS = ['reassoc', 'nnan', 'ninf', 'nsz', 'arcp', 'contract', 'afn']
CONSTS = ['0.0', '-0.0', '1.0', '-1.0', '2.0', '0.5', '3.0', '-2.0', '4.0', '0x7FF0000000000000', '0xFFF0000000000000',
          '0x7FF8000000000000', '1.0e+300', '1.0e-310', '0x3FB999999999999A', '1.000000e+01']
FCMP = ['oeq', 'one', 'olt', 'ogt', 'ole', 'oge', 'ord', 'uno', 'ueq', 'une', 'ult', 'ugt']
RETCLS = ['nan', 'inf', 'zero', 'sub', 'norm', 'nan inf', 'nzero', 'pinf ninf', 'nan zero']

def gen(rng):
    fty = rng.choice(['double', 'double', 'float'])
    ty = f'<2 x {fty}>' if VEC else fty
    bty = '<2 x i1>' if VEC else 'i1'
    def cst():
        c = rng.choice(CONSTS)
        if fty == 'float' and c.startswith('0x'):
            c = rng.choice(['0x7FF0000000000000', '0xFFF0000000000000', '0x7FF8000000000000', '1.0', '2.0'])
        if fty == 'float' and c in ('1.0e+300', '1.0e-310'): c = '1.0e+30'
        if VEC:
            return f'splat ({fty} {c})'
        return c
    def fmf():
        if rng.random() < 0.3: return ''
        if rng.random() < 0.25: return ' fast'
        fs = [f for f in FLAGS if rng.random() < 0.45]
        return (' ' + ' '.join(fs)) if fs else ''
    vals = ['%a', '%b', '%c']
    lines = []
    k = 0
    def pick():
        if rng.random() < 0.25: return cst()
        return rng.choice(vals[-4:] if rng.random() < 0.6 else vals)
    n = rng.randint(2, 9)
    for _ in range(n):
        k += 1
        nm = f'%v{k}'
        r = rng.random()
        if r < 0.62:
            op = rng.choice(BIN)
            a, b = pick(), pick()
            if not a.startswith('%') and not b.startswith('%'): a = '%a'
            lines.append(f'  {nm} = {op}{fmf()} {ty} {a}, {b}')
        elif r < 0.75:
            lines.append(f'  {nm} = fneg{fmf()} {ty} {rng.choice(vals)}')
        elif r < 0.87:
            c = f'%c{k}'
            lines.append(f'  {c} = fcmp{fmf()} {rng.choice(FCMP)} {ty} {pick()}, {pick()}')
            lines.append(f'  {nm} = select{fmf()} {bty} {c}, {ty} {pick()}, {ty} {pick()}')
        else:
            lines.append(f'  {nm} = select{fmf()} {bty} %p, {ty} {pick()}, {ty} {pick()}')
        vals.append(nm)
    ret = vals[-1]
    rattr = ''
    if rng.random() < 0.3: rattr = f'nofpclass({rng.choice(RETCLS)}) '
    body = '\n'.join(lines)
    return f'define {rattr}{ty} @f({ty} %a, {ty} %b, {ty} %c, {bty} %p) {{\n{body}\n  ret {ty} {ret}\n}}\n'

def run(args):
    i, seed = args
    rng = random.Random(seed * 1000003 + i)
    src = gen(rng)
    os.makedirs(OUT, exist_ok=True)
    path = f'{OUT}/in{i}.ll'
    with open(path, 'w') as f: f.write(src)
    def opt(binp):
        p = subprocess.run([binp, '-passes=instcombine', '-S', path], capture_output=True, timeout=30)
        return p.returncode, p.stdout, p.stderr
    rc1, o1, e1 = opt(os.path.join(LLVM, 'opt'))
    if rc1 != 0: return 'llvm-failed', i, src
    rc2, o2, e2 = opt(OURS)
    if rc2 != 0: return 'loud', i, e2.decode(errors='replace').strip().split('\n')[0]
    def canon(o):
        a = subprocess.run([os.path.join(LLVM, 'llvm-as'), '-o', '-'], input=o, capture_output=True)
        if a.returncode != 0: return None
        return subprocess.run([os.path.join(LLVM, 'llvm-dis'), '-o', '-'], input=a.stdout, capture_output=True).stdout
    c1, c2 = canon(o1), canon(o2)
    if c2 is None: return 'bad-ir', i, src
    if c1 != c2:
        os.makedirs(OUT, exist_ok=True)
        with open(f'{OUT}/{i}.ll', 'w') as f: f.write(src)
        with open(f'{OUT}/{i}.expected', 'wb') as f: f.write(c1)
        with open(f'{OUT}/{i}.actual', 'wb') as f: f.write(c2)
        return 'differs', i, src
    return 'same', i, ''

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    jobs = 16
    if '-j' in args:
        j = args.index('-j'); jobs = int(args[j + 1]); del args[j:j + 2]
    count = int(args[0]) if args else 500
    seed = int(args[1]) if len(args) > 1 else 1
    stats = {}
    louds = {}
    with cf.ThreadPoolExecutor(jobs) as ex:
        for st, i, info in ex.map(run, [(i, seed) for i in range(count)]):
            stats[st] = stats.get(st, 0) + 1
            if st == 'loud': louds[info] = louds.get(info, 0) + 1
            if st in ('differs', 'bad-ir'): print(st, i)
    print(stats)
    for m, c in sorted(louds.items(), key=lambda x: -x[1])[:12]: print(f'{c:6d}  {m}')

main()
