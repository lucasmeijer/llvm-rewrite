#!/usr/bin/env python3
"""Summarize why InstCombine ::opt tests fail for goose: the first 'not ported' / error line of each failing test.
Usage: tools/ic_failures.py [glob of test names]   (run ./harness/run check first; reads .harness-out)"""
import os, sys, collections, glob
root = os.path.join(os.path.dirname(__file__), '..', '..', '..')
base = os.path.join(root, '.harness-out/goose/tests/imported/llvm/Transforms/InstCombine')
pats = sys.argv[1:] or ['*']
reasons = collections.Counter()
per = collections.defaultdict(list)
for p in pats:
    for d in sorted(glob.glob(os.path.join(base, p, 'opt'))):
        name = os.path.basename(os.path.dirname(d))
        msg = ''
        for f in ('stderr.txt', 'message.txt'):
            fp = os.path.join(d, f)
            if os.path.exists(fp):
                for line in open(fp, errors='replace'):
                    if 'not ported' in line or 'error' in line.lower() or 'fatal' in line.lower():
                        msg = line.strip()[:160]; break
            if msg: break
        if not msg: msg = 'output differs'
        reasons[msg] += 1
        per[msg].append(name)
for m, c in reasons.most_common():
    print(f'{c:4d}  {m}')
    if '-v' in os.environ.get('ICF', ''):
        print('        ' + ' '.join(per[m]))
