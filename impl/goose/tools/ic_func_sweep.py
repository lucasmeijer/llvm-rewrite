#!/usr/bin/env python3
"""Per-function InstCombine sweep: split every test file into single-function modules (llvm-extract) and
compare `opt -passes=instcombine -S` of LLVM and goose on each. A file whose other functions stop goose loudly
still gets its supported functions compared. Usage: tools/ic_func_sweep.py [globs...] [-j N] [--passes P]
(default: tests/imported/llvm/Transforms/InstCombine/*.ll). Mismatches are written to /tmp/ic_func_sweep/."""
import os, re, sys, glob, subprocess, collections, concurrent.futures as cf

LLVM = '/opt/llvm-23.1.5/bin'
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
OURS = os.path.join(HERE, '..', 'bin', 'opt')
OUT = '/tmp/ic_func_sweep'

def canon(text):
    a = subprocess.run([f'{LLVM}/llvm-as', '-o', '-', '-'], input=text.encode(), capture_output=True)
    if a.returncode: return None
    return subprocess.run([f'{LLVM}/llvm-dis', '-o', '-', '-'], input=a.stdout, capture_output=True).stdout.decode()

def funcs(path):
    names = []
    for line in open(path, errors='replace'):
        m = re.match(r'define\b[^@]*@("[^"]+"|[-\w.$]+)\s*\(', line)
        if m: names.append(m.group(1).strip('"'))
    return names

def one(job):
    path, fn, idx, passes = job
    base = os.path.join(OUT, os.path.basename(path) + f'.{idx}.ll')
    e = subprocess.run([f'{LLVM}/llvm-extract', '-S', f'--func={fn}', path, '-o', base], capture_output=True)
    if e.returncode: return ('extract-failed', path, fn, '')
    try:
        l = subprocess.run([f'{LLVM}/opt', '-S', f'-passes={passes}', base], capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        os.remove(base); return ('llvm-failed', path, fn, '')
    if l.returncode: os.remove(base); return ('llvm-failed', path, fn, '')
    try:
        o = subprocess.run([OURS, '-S', f'-passes={passes}', base], capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        return ('failed', path, fn, 'timeout')
    if o.returncode:
        os.remove(base)
        err = o.stderr.decode().strip().splitlines()
        return ('failed', path, fn, err[0][:200] if err else '?')
    a = canon(l.stdout.decode()); b = canon(o.stdout.decode())
    if b is None: return ('bad-ir', path, fn, '')
    if a != b:
        open(base + '.expected', 'w').write(a or ''); open(base + '.actual', 'w').write(b)
        return ('differs', path, fn, '')
    os.remove(base)
    return ('identical', path, fn, '')

def main():
    argv = sys.argv[1:]
    j = 16; passes = 'instcombine'
    if '-j' in argv: k = argv.index('-j'); j = int(argv[k + 1]); del argv[k:k + 2]
    if '--passes' in argv: k = argv.index('--passes'); passes = argv[k + 1]; del argv[k:k + 2]
    globs = argv or ['tests/imported/llvm/Transforms/InstCombine/*.ll']
    files = sorted(set(f for g in globs for f in glob.glob(os.path.join(ROOT, g))))
    os.makedirs(OUT, exist_ok=True)
    jobs = [(f, fn, i, passes) for f in files for i, fn in enumerate(funcs(f))]
    stats = collections.Counter(); errs = collections.Counter(); diffs = []
    with cf.ThreadPoolExecutor(j) as ex:
        for st, path, fn, err in ex.map(one, jobs):
            stats[st] += 1
            if st == 'failed': errs[err] += 1
            if st in ('differs', 'bad-ir'): diffs.append((st, os.path.relpath(path, ROOT), fn))
    print(dict(stats))
    for st, p, fn in diffs: print(f'{st:8s} {p} @{fn}')
    print('top loud failures:')
    for e, c in errs.most_common(25): print(f'{c:6d} {e}')

if __name__ == '__main__':
    main()
