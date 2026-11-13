#!/usr/bin/env python3
"""Generates src/gen_intrinsics.jai: intrinsic names and the attributes Intrinsic::getAttributes gives them.

LLVM computes these with TableGen from llvm/include/llvm/IR/Intrinsics*.td. We have no TableGen, so:
  * intrinsic names come from gen_iit.py's evaluation of Intrinsics.td and IntrinsicsX86.td, used for
    Intrinsic::lookupIntrinsicID-style longest-prefix lookup;
  * the attributes come from running the oracle (LLVM 23.1.5 opt -S) on every test file in tests/ that mentions
    an intrinsic, and reading the intrinsic declarations it prints (including ones the parser created for
    undeclared calls). The attributes LLVM attaches depend only on the intrinsic ID for
    everything we have seen (checked: all overloads in the corpus agree; the script warns otherwise).
Intrinsics that appear in no test have a name but no attribute entry; the implementation then fails loudly.

Run: python3 impl/jai/gen/gen_intrinsics.py > impl/jai/src/gen_intrinsics.jai
"""
import os, re, subprocess, sys, tempfile, glob

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
TD = '/opt/llvm-project-23.1.5/llvm/include/llvm/IR/'
OPT = '/opt/llvm-23.1.5/bin/opt'

# intrinsic names and overloadedness from the TableGen evaluator in gen_iit.py (the IntrinsicNameTable)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_iit
_rows, _x86 = gen_iit.intrinsic_rows()
names = set(r[0] for r in _rows)
overloaded = set(r[0] for r in _rows if r[2])

def lookup(name):
    # longest intrinsic name that equals `name` or is a prefix followed by '.'
    best = None
    for n in names:
        if name == n or (n in overloaded and name.startswith(n + '.')):
            if best is None or len(n) > len(best):
                best = n
    return best

files = []
for path in glob.glob(os.path.join(ROOT, 'tests', '**', '*.ll'), recursive=True):
    try:
        if '@llvm.' in open(path, errors='replace').read():
            files.append(path)
    except OSError:
        pass

def run_file(path):
    r = subprocess.run([OPT, '-S', path, '-o', '-'], capture_output=True, text=True, cwd=ROOT)
    return r.stdout if r.returncode == 0 else ''

from concurrent.futures import ThreadPoolExecutor
with ThreadPoolExecutor(max_workers=os.cpu_count() or 8) as ex:
    outputs = list(ex.map(run_file, sorted(files)))

# Intrinsics that passes create but that no test input mentions (LoopVectorize's masked div/rem): declared in a
# scratch module so their attributes are read the same way.
EXTRA_DECLS = '''
declare <4 x i32> @llvm.masked.udiv.v4i32(<4 x i32>, <4 x i32>, <4 x i1>)
declare <4 x i32> @llvm.masked.sdiv.v4i32(<4 x i32>, <4 x i32>, <4 x i1>)
declare <4 x i32> @llvm.masked.urem.v4i32(<4 x i32>, <4 x i32>, <4 x i1>)
declare <4 x i32> @llvm.masked.srem.v4i32(<4 x i32>, <4 x i32>, <4 x i1>)
declare <4 x i1> @llvm.loop.dependence.war.mask.v4i1.i64(i64, i64, i64)
declare <vscale x 4 x i32> @llvm.vector.splice.right.nxv4i32(<vscale x 4 x i32>, <vscale x 4 x i32>, i32)
declare <vscale x 4 x i32> @llvm.vector.splice.left.nxv4i32(<vscale x 4 x i32>, <vscale x 4 x i32>, i32)
declare <vscale x 4 x i32> @llvm.vector.interleave2.nxv4i32(<vscale x 2 x i32>, <vscale x 2 x i32>)
declare { <vscale x 2 x i32>, <vscale x 2 x i32> } @llvm.vector.deinterleave2.nxv4i32(<vscale x 4 x i32>)
'''
with tempfile.NamedTemporaryFile('w', suffix='.ll', delete=False) as _t:
    _t.write(EXTRA_DECLS)
outputs.append(run_file(_t.name))
os.unlink(_t.name)

def split_params(s):
    out, depth, cur = [], 0, ''
    for c in s:
        if c in '([{<':
            depth += 1
        elif c in ')]}>':
            depth -= 1
        if c == ',' and depth == 0:
            out.append(cur.strip()); cur = ''
        else:
            cur += c
    if cur.strip():
        out.append(cur.strip())
    return out

def param_attrs(p):
    # "<type> [attrs]": the type is the first depth-0 word (plus "addrspace(N)" after ptr)
    depth, i = 0, 0
    while i < len(p):
        c = p[i]
        if c in '([{<': depth += 1
        elif c in ')]}>': depth -= 1
        if c == ' ' and depth == 0:
            break
        i += 1
    rest = p[i:].strip()
    if rest.startswith('addrspace('):
        rest = rest[rest.index(')') + 1:].strip()
    return rest

def parse_output(text):
    groups = dict(re.findall(r'^attributes #(\d+) = \{ (.*) \}$', text, re.M))
    res = []
    for decl in text.splitlines():
        m = re.match(r'^declare (.*?)@(llvm\.[A-Za-z0-9_.]+)\((.*?)\)(?: addrspace\(\d+\))?(?: #(\d+))?$', decl)
        if not m:
            continue
        head, name, params, gid = m.group(1), m.group(2), m.group(3), m.group(4)
        fn = groups.get(gid, '') if gid else ''
        words = split_ret(head.strip())
        skip = {'extern_weak', 'dso_local', 'dso_preemptable', 'hidden', 'protected', 'dllimport', 'external'}
        words = [w for w in words[:-1] if w not in skip and not re.match(r'^(cc\d+|[a-z_0-9]+cc|ccc)$', w)]
        # range(iN ...) on the return value follows the return type width: '@' is substituted at run time
        ret = re.sub(r'range\(i\d+ ', 'range(i@ ', ' '.join(words))
        plist = [param_attrs(p) for p in split_params(params) if p != '...']
        res.append((name, (fn, ret, plist)))
    return res

def split_ret(s):
    out, depth, cur = [], 0, ''
    for c in s:
        if c in '([{<': depth += 1
        elif c in ')]}>': depth -= 1
        if c == ' ' and depth == 0:
            if cur: out.append(cur)
            cur = ''
        else:
            cur += c
    if cur: out.append(cur)
    merged = []
    for w in out:
        if w.startswith('addrspace(') and merged:
            merged[-1] += ' ' + w
        else:
            merged.append(w)
    return merged

def jstr(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

found = {}
for text in outputs:
    for name, attrs in parse_output(text):
        base = lookup(name)
        if base is None:
            continue
        found.setdefault(base, [])
        if attrs not in found[base]:
            found[base].append(attrs)
entries = []
for base in sorted(found):
    results = found[base]
    if len(results) > 1:
        sys.stderr.write('warning: %s: overloads disagree, using the first: %r\n' % (base, results))
    entries.append((base, results[0]))

print('// GENERATED by impl/jai/gen/gen_intrinsics.py (see the script for how). Do not edit.')
print('Intrinsic_Attrs :: struct { name: string; fn: string; ret: string; params: [] string; }')
print('INTRINSIC_NAMES :: string.[')
for n in sorted(names):
    print('    %s,' % jstr(n))
print('];')
print('INTRINSIC_OVERLOADED :: string.[')
for n in sorted(overloaded):
    print('    %s,' % jstr(n))
print('];')
print('INTRINSIC_ATTRS :: Intrinsic_Attrs.[')
for base, (fn, ret, plist) in entries:
    print('    .{%s, %s, %s, .[%s]},' % (jstr(base), jstr(fn), jstr(ret), ', '.join(jstr(p) for p in plist)))
print('];')
