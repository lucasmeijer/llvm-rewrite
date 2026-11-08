#!/usr/bin/env python3
"""Generates src/gen_intrinsics.jai: intrinsic names and the attributes Intrinsic::getAttributes gives them.

LLVM computes these with TableGen from llvm/include/llvm/IR/Intrinsics*.td. We have no TableGen, so:
  * intrinsic names come from the `def int_*` records of Intrinsics.td and IntrinsicsX86.td
    (int_foo_bar -> llvm.foo.bar), used for Intrinsic::lookupIntrinsicID-style longest-prefix lookup;
  * the attributes come from running the oracle (LLVM 23.1.5 opt) on one declaration per intrinsic, taken from
    every `declare ... @llvm.*` line in tests/. The attributes LLVM attaches depend only on the intrinsic ID for
    everything we have seen (checked: all overloads in the corpus agree; the script warns otherwise).
Intrinsics that appear in no test have a name but no attribute entry; the implementation then fails loudly.

Run: python3 impl/jai/gen/gen_intrinsics.py > impl/jai/src/gen_intrinsics.jai
"""
import os, re, subprocess, sys, tempfile, glob

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
TD = '/opt/llvm-project-23.1.5/llvm/include/llvm/IR/'
OPT = '/opt/llvm-23.1.5/bin/opt'

names = set()
for f in ['Intrinsics.td', 'IntrinsicsX86.td']:
    src = open(TD + f).read()
    for m in re.finditer(r'^\s*def\s+int_([A-Za-z0-9_]+)\s*:', src, re.M):
        # the record body runs to the next ';' at bracket depth 0; an explicit "llvm.*" string names it
        i, depth = m.end(), 0
        while i < len(src):
            c = src[i]
            if c in '<([{': depth += 1
            elif c in '>)]}': depth -= 1
            elif c == ';' and depth <= 0: break
            i += 1
        body = src[m.end():i]
        explicit = re.search(r'"(llvm\.[A-Za-z0-9_.]+)"', body)
        names.add(explicit.group(1) if explicit else 'llvm.' + m.group(1).replace('_', '.'))

def lookup(name):
    # longest intrinsic name that equals `name` or is a prefix followed by '.'
    best = None
    for n in names:
        if name == n or name.startswith(n + '.'):
            if best is None or len(n) > len(best):
                best = n
    return best

decls = {}
for path in glob.glob(os.path.join(ROOT, 'tests', '**', '*.ll'), recursive=True):
    try:
        text = open(path, errors='replace').read()
    except OSError:
        continue
    for line in text.splitlines():
        m = re.match(r'^declare .*@(llvm\.[A-Za-z0-9_.]+)\(', line)
        if not m:
            continue
        base = lookup(m.group(1))
        if base is None:
            continue
        decls.setdefault(base, [])
        if len(decls[base]) < 4 and line not in decls[base]:
            decls[base].append(line)

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

def oracle(line):
    # strip attribute group refs (#N) so the declaration stands alone
    clean = re.sub(r'\s#\d+', '', line)
    with tempfile.NamedTemporaryFile('w', suffix='.ll', delete=False) as f:
        f.write(clean + '\n')
        path = f.name
    try:
        r = subprocess.run([OPT, '-S', path, '-o', '-'], capture_output=True, text=True)
    finally:
        os.unlink(path)
    if r.returncode != 0:
        return None
    ds = [l for l in r.stdout.splitlines() if l.startswith('declare ')]
    if not ds:
        return None
    decl = ds[0]
    groups = dict(re.findall(r'^attributes #(\d+) = \{ (.*) \}$', r.stdout, re.M))
    m = re.match(r'^declare (.*?)@[^(]*\((.*)\)( #(\d+))?$', decl)
    head, params, gid = m.group(1), m.group(2), m.group(4)
    fn = groups.get(gid, '') if gid else ''
    # return attributes: everything in head except the return type (last depth-0 word)
    words = split_ret(head.strip())
    ret = ' '.join(words[:-1])
    plist = [param_attrs(p) for p in split_params(params) if p != '...']
    return fn, ret, plist

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

entries = []
for base in sorted(decls):
    results = [oracle(l) for l in decls[base]]
    results = [r for r in results if r is not None]
    if not results:
        continue
    if any(r != results[0] for r in results[1:]):
        sys.stderr.write('warning: %s: overloads disagree: %r\n' % (base, results))
    entries.append((base, results[0]))

print('// GENERATED by impl/jai/gen/gen_intrinsics.py (see the script for how). Do not edit.')
print('Intrinsic_Attrs :: struct { name: string; fn: string; ret: string; params: [] string; }')
print('INTRINSIC_NAMES :: string.[')
for n in sorted(names):
    print('    %s,' % jstr(n))
print('];')
print('INTRINSIC_ATTRS :: Intrinsic_Attrs.[')
for base, (fn, ret, plist) in entries:
    print('    .{%s, %s, %s, .[%s]},' % (jstr(base), jstr(fn), jstr(ret), ', '.join(jstr(p) for p in plist)))
print('];')
