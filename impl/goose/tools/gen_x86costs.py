#!/usr/bin/env python3
"""Generate src/gen_x86costs.goose from LLVM 23.1.5's X86 target sources:

* every static cost table (CostKindTblEntry / TypeConversionCostKindTblEntry) of the X86TTIImpl functions the Goose
  TTI uses (X86TargetTransformInfo.cpp), as flat arrays indexed by table id;
* the X86 subtarget features of X86.td with their transitive implications, and the feature/tuning lists of the CPUs
  we support;
* the list of fixed-length vector MVTs (ValueTypes.td), needed by type legalization.

MVT encoding (shared with tti_x86.goose): element code | (number of elements << 8), 0 elements for a scalar.
Usage: tools/gen_x86costs.py [out]   (default src/gen_x86costs.goose)
"""
import re, sys
LLVM = '/opt/llvm-project-23.1.5/llvm'
TTI = LLVM + '/lib/Target/X86/X86TargetTransformInfo.cpp'
TD = LLVM + '/lib/Target/X86/X86.td'
VT = LLVM + '/include/llvm/CodeGen/ValueTypes.td'

ELT = {'i1': 1, 'i2': 2, 'i4': 3, 'i8': 4, 'i16': 5, 'i32': 6, 'i64': 7, 'i128': 8, 'f16': 9, 'bf16': 10,
       'f32': 11, 'f64': 12, 'f80': 13, 'f128': 14, 'i256': 15, 'i512': 16, 'Other': 17}


def mvt(name):
    if name in ELT: return ELT[name]
    m = re.fullmatch(r'v(\d+)(\w+)', name)
    assert m and m.group(2) in ELT, name
    return ELT[m.group(2)] | (int(m.group(1)) << 8)


FUNCS = {'getArithmeticInstrCost': 'A', 'getCastInstrCost': 'C', 'getCmpSelInstrCost': 'S',
         'getIntrinsicInstrCost': 'I', 'getVectorInstrCost': 'V', 'getShuffleCost': 'H', 'getMemoryOpCost': 'M'}
text = open(TTI).read()
starts = [(m.start(), m.group(1)) for m in
          re.finditer(r'\n(?:InstructionCost|bool|unsigned)\s*\n?X86TTIImpl::(\w+)\(', text)]
starts.append((len(text), None))
tables = []  # (const name, [(isd, dst, src, costs)])
isds = []
for i in range(len(starts) - 1):
    pos, name = starts[i]
    if name not in FUNCS: continue
    body = text[pos:starts[i + 1][0]]
    for tm in re.finditer(
            r'static const (CostKindTblEntry|TypeConversionCostKindTblEntry) (\w+)\[\]\s*(?:=)?\s*\{(.*?)\n\s*\};',
            body, re.S):
        kind, tname, content = tm.groups()
        ents = []
        for em in re.finditer(
                r'\{\s*((?:X86)?ISD::\w+)\s*,\s*MVT::(\w+)\s*,\s*(?:MVT::(\w+)\s*,\s*)?\{([^}]*)\}\s*\}', content):
            isd, dst, src, costs = em.groups()
            isd = isd.replace('X86ISD::', 'X86_').replace('ISD::', '')
            if isd not in isds: isds.append(isd)
            cs = [c.strip() for c in costs.split(',') if c.strip()]
            cs = [int(c) for c in cs] + [-1] * (4 - len(cs))
            ents.append((isd, mvt(dst), mvt(src) if src else 0, cs))
        tables.append((f'XCT_{FUNCS[name]}_{tname}', ents))

# ISD opcodes the Goose code names that no table mentions
for isd in ['FREM', 'TRUNCATE', 'ZERO_EXTEND', 'SIGN_EXTEND', 'FP_TO_UINT', 'FP_TO_SINT', 'UINT_TO_FP', 'SINT_TO_FP',
            'FP_ROUND', 'FP_EXTEND', 'BITCAST', 'ADDRSPACECAST', 'SETCC', 'SELECT', 'VSELECT', 'EXTRACT_VECTOR_ELT',
            'INSERT_VECTOR_ELT', 'CTTZ_ZERO_POISON', 'CTLZ_ZERO_POISON', 'ABS', 'BITREVERSE', 'BSWAP', 'CTLZ', 'CTPOP',
            'CTTZ', 'FSHL', 'ROTL', 'ROTR', 'X86_VROTLI', 'FMAXNUM', 'FMINNUM', 'SADDSAT', 'SMAX', 'SMIN', 'SSUBSAT',
            'UADDSAT', 'UMAX', 'UMIN', 'USUBSAT', 'FSQRT', 'SADDO', 'UADDO', 'SMULO', 'UMULO']:
    if isd not in isds: isds.append(isd)

# ---- subtarget features
td = open(TD).read()
feats = []  # (defname, string name, [implied defnames])
for m in re.finditer(r'\ndef (\w+)\s*:\s*SubtargetFeature<\s*"([^"]+)"\s*,(.*?)>\s*;', td, re.S):
    dname, sname, rest = m.groups()
    im = re.search(r'\[([^\]]*)\]\s*$', rest.strip(), re.S)
    impl = [x.strip() for x in im.group(1).split(',') if x.strip()] if im else []
    feats.append((dname, sname, impl))
idx = {d: i for i, (d, _, _) in enumerate(feats)}
assert len(feats) <= 256, len(feats)
WORDS = 4


def closure(i, seen=None):
    seen = set() if seen is None else seen
    for d in feats[i][2]:
        j = idx[d]
        if j not in seen:
            seen.add(j); closure(j, seen)
    return seen


def bits(s):
    w = [0] * WORDS
    for j in s: w[j // 64] |= 1 << (j % 64)
    return w


pf = re.search(r'def ProcessorFeatures \{(.*?)\n\}', td, re.S).group(1)
lists = {}
for m in re.finditer(r'list<SubtargetFeature> (\w+) =\s*(.*?);', pf, re.S):
    nm, expr = m.groups()
    def ev(e):
        e = e.strip()
        if e.startswith('!listconcat('):
            inner = e[len('!listconcat('):-1]
            depth = 0; parts = []; cur = ''
            for ch in inner:
                if ch == '[': depth += 1
                if ch == ']': depth -= 1
                if ch == ',' and depth == 0: parts.append(cur); cur = ''
                else: cur += ch
            parts.append(cur)
            r = []
            for p in parts:
                x = ev(p)
                if x is None: return None
                r += x
            return r
        if e.startswith('['):
            return [x.strip() for x in e[1:-1].split(',') if x.strip()]
        if e.startswith('!'): return None
        if e not in lists: return None
        return list(lists[e])
    v = ev(expr)
    if v is not None: lists[nm] = v  # None: !listremove etc., only used by CPUs we do not support


def proc(name):
    m = re.search(r'def\s*:\s*Proc(?:Model)?<"' + re.escape(name) + r'",\s*(?:\w+,\s*)?(.*?)>\s*;', td, re.S)
    if m is None:
        # foreach P = ["a", "b", ...] in { def : ProcModel<P, Model, Features, Tuning>; }
        for fm in re.finditer(r'foreach P = \[([^\]]*)\] in \{\s*def\s*:\s*Proc(?:Model)?<P,\s*(?:\w+,\s*)?(.*?)>\s*;\s*\}', td, re.S):
            if name in [x.strip().strip('"') for x in fm.group(1).split(',')]:
                m = fm
                break
        body = m.group(2)
    else:
        body = m.group(1)
    # two lists: features, tuning
    parts = []; depth = 0; cur = ''
    for ch in body:
        if ch == '[': depth += 1
        if ch == ']': depth -= 1
        if ch == ',' and depth == 0: parts.append(cur); cur = ''
        else: cur += ch
    parts.append(cur)
    def ev(e):
        e = e.strip()
        if e.startswith('['): return [x.strip() for x in e[1:-1].split(',') if x.strip()]
        return list(lists[e.replace('ProcessorFeatures.', '')])
    return ev(parts[0]), ev(parts[1])


CPUS = ['generic', 'i586', 'x86-64', 'x86-64-v2', 'x86-64-v3', 'x86-64-v4',
        # Intel/AMD CPUs used by -mcpu in the test corpus (feature and tuning lists; no scheduling models)
        'core2', 'nehalem', 'corei7', 'westmere', 'sandybridge', 'corei7-avx', 'ivybridge', 'core-avx-i', 'haswell',
        'core-avx2', 'broadwell', 'skylake', 'skylake-avx512', 'skx', 'cascadelake', 'cooperlake', 'cannonlake',
        'icelake-client', 'icelake-server', 'tigerlake', 'alderlake', 'sapphirerapids', 'knl', 'knm',
        'bonnell', 'atom', 'silvermont', 'slm', 'goldmont', 'goldmont-plus', 'tremont',
        'btver1', 'btver2', 'bdver1', 'bdver2', 'bdver3', 'bdver4', 'znver1', 'znver2', 'znver3', 'znver4', 'znver5']
cpu_rows = []
skipped = []
for c in CPUS:
    try:
        f, t = proc(c)
        row = (c, [idx[x] for x in f], [idx[x] for x in t])
    except KeyError:
        # a list built with !listremove & co. (not evaluated), or a feature without a name (ProcIntelAtom):
        # the CPU stays unsupported (fails loudly)
        skipped.append(c)
        continue
    cpu_rows.append(row)
CPUS = [c for c in CPUS if c not in skipped]
if skipped: print('CPUs skipped:', ' '.join(skipped), file=sys.stderr)

# ---- vector MVTs
vts = [m.group(1) for m in re.finditer(r'\ndef (v\d+(?:i|f|bf)\d+)\s*:', open(VT).read())]
vts = [v for v in vts if re.fullmatch(r'v\d+(i1|i2|i4|i8|i16|i32|i64|i128|f16|bf16|f32|f64|f80|f128)', v)]

o = []
o.append('// Generated by tools/gen_x86costs.py from LLVM 23.1.5 (X86TargetTransformInfo.cpp, X86.td, ValueTypes.td).')
o.append('// Do not edit. MVT encoding: element code | (elements << 8); see tti_x86.goose.')
for n, isd in enumerate(isds):
    o.append(f'let XISD_{isd}: i32 = {n + 1};')
for t, (nm, _) in enumerate(tables):
    o.append(f'let {nm}: i32 = {t};')
start = [0]
for _, e in tables: start.append(start[-1] + len(e))
E = start[-1]
allents = [x for _, e in tables for x in e]
o.append(f'let XCT_START: i32[{len(start)}] = [{", ".join(map(str, start))}];')
o.append(f'let XCE_ISD: i32[{E}] = [{", ".join(str(isds.index(x[0]) + 1) for x in allents)}];')
o.append(f'let XCE_DST: i32[{E}] = [{", ".join(str(x[1]) for x in allents)}];')
o.append(f'let XCE_SRC: i32[{E}] = [{", ".join(str(x[2]) for x in allents)}];')
o.append(f'let XCE_COST: i32[{4 * E}] = [{", ".join(str(c) for x in allents for c in x[3])}];')
o.append(f'let X86F_COUNT: i32 = {len(feats)};')
o.append(f'let X86F_WORDS: i32 = {WORDS};')
for i, (d, s, _) in enumerate(feats):
    o.append(f'let X86F_{d}: i32 = {i};')
o.append(f'let X86F_NAMES: const u8[:][] = [{", ".join(chr(34) + s + chr(34) for _, s, _ in feats)}];')
imp = []
for i in range(len(feats)): imp += bits(closure(i))
o.append(f'let X86F_IMPLIES: u64[{len(imp)}] = [{", ".join(str(x) for x in imp)}];')
o.append(f'let X86CPU_NAMES: const u8[:][] = [{", ".join(chr(34) + c + chr(34) for c in CPUS)}];')
cf = []; ct = []
for _, f, t in cpu_rows: cf += bits(f); ct += bits(t)
o.append(f'let X86CPU_FEATURES: u64[{len(cf)}] = [{", ".join(map(str, cf))}];')
o.append(f'let X86CPU_TUNING: u64[{len(ct)}] = [{", ".join(map(str, ct))}];')
o.append(f'let X86_VECTOR_MVTS: i32[{len(vts)}] = [{", ".join(str(mvt(v)) for v in vts)}];')
with open(sys.argv[1] if len(sys.argv) > 1 else 'src/gen_x86costs.goose', 'w') as f:
    f.write('\n'.join(o) + '\n')
print(len(tables), 'tables,', E, 'entries,', len(feats), 'features,', len(vts), 'vector MVTs')
