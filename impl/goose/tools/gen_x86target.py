#!/usr/bin/env python3
"""Generate the X86 target description the Goose TTI uses, from LLVM 23.1.5:

src/gen_x86target.goose
  * MVTs (MVT::SimpleValueType numbering, `llvm-min-tblgen -gen-vt`): MVT_<name> constants, size/element/count/kind
    arrays and the MVT ranges (integer_valuetypes() & co.);
  * ISD opcodes (ISDOpcodes.h; XISD_<name>, the X86ISD names the cost tables use numbered after BUILTIN_OP_END);
  * every SubtargetFeature of X86.td with its transitive implications, and a getter `xst_<getter>()` for every
    boolean subtarget field (GET_SUBTARGETINFO_MACRO: hasCMOV() = HasCMOV, ...);
  * every processor LLVM accepts (Proc / ProcModel records): features, tune features and scheduling model;
  * every SchedMachineModel's MCSchedModel parameters (IssueWidth, MicroOpBufferSize, LoopMicroOpBufferSize,
    LoadLatency, HighLatency, MispredictPenalty; -1 replaced by the MCSchedModel defaults, as SubtargetEmitter does).
  All from TableGen's own evaluation of X86.td (`--print-records`), so !listconcat/!listremove CPU lists are exact.

src/gen_x86costs.goose
  * every static cost table of X86TargetTransformInfo.cpp (CostTblEntry, CostKindTblEntry,
    TypeConversionCostKindTblEntry), named XCT_<function code>_<table name>, packed into one string decoded at start-up
    (huge array literals make goose build slow).

Usage: python3 impl/goose/tools/gen_x86target.py      (needs tools/build_min_tblgen.sh's llvm-min-tblgen)
"""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import x86gen_common as C

LLVM = C.LLVM
TTI = LLVM + '/lib/Target/X86/X86TargetTransformInfo.cpp'

vts = C.value_types()
mvt = C.mvt_index()
isds = C.isd_names()
isd_num = {n: k for k, n in enumerate(isds)}
BUILTIN_OP_END = len(isds)

# ---------------------------------------------------------------- cost tables
FUNCS = {'getArithmeticInstrCost': 'A', 'getCastInstrCost': 'C', 'getCmpSelInstrCost': 'S',
         'getIntrinsicInstrCost': 'I', 'getVectorInstrCost': 'V', 'getShuffleCost': 'H', 'getMemoryOpCost': 'M',
         'getArithmeticReductionCost': 'R', 'getMinMaxReductionCost': 'N', 'getInterleavedMemoryOpCost': 'L',
         'getInterleavedMemoryOpCostAVX512': 'K'}
hdr = open(LLVM + '/include/llvm/Analysis/TargetTransformInfo.h').read()
sk_body = hdr[hdr.index('enum ShuffleKind {'):]
sk_body = sk_body[:sk_body.index('};')]
SK = [m.group(1) for m in re.finditer(r'\b(SK_\w+)', re.sub(r'///[^\n]*', '', sk_body))]
text = open(TTI).read()
fstarts = [(m.start(), m.group(1)) for m in re.finditer(r'^(?:[\w:<>]+[ *&]+\n?)?X86TTIImpl::(\w+)\(', text, re.M)]
x86isd = []
tables = []
seen = set()
for tm in re.finditer(r'static const (CostKindTblEntry|CostTblEntry|TypeConversionCostKindTblEntry|TypeConversionCostTblEntry)'
                      r'\s+(\w+)\[\]\s*=?\s*\{(.*?)\n\s*\};', text, re.S):
    kind, tname, content = tm.groups()
    fn = None
    for p, n in fstarts:
        if p < tm.start():
            fn = n
    assert fn in FUNCS, (fn, tname)
    cname = f'XCT_{FUNCS[fn]}_{tname}'
    assert cname not in seen, cname
    seen.add(cname)
    content = re.sub(r'//[^\n]*', '', content)
    ents = []
    conv = kind.startswith('TypeConversion')
    for em in re.finditer(r'\{\s*([\w:]+)\s*,\s*MVT::(\w+)\s*,\s*(?:MVT::(\w+)\s*,\s*)?(\{[^}]*\}|[\w~]+)\s*\}', content):
        key, dst, src, costs = em.groups()
        assert (src is not None) == conv, em.group(0)
        if key.startswith('ISD::'):
            k = isd_num[key[5:]]
        elif key.startswith('X86ISD::'):
            nm = 'X86_' + key[8:]
            if nm not in x86isd:
                x86isd.append(nm)
            k = BUILTIN_OP_END + 1 + x86isd.index(nm)
        elif key.startswith('TTI::SK_'):
            k = SK.index(key[5:])
        else:
            k = int(key)
        if costs.startswith('{'):
            cs = [c.strip() for c in costs[1:-1].split(',') if c.strip()]
            cs = [int(c) for c in cs] + [-1] * (4 - len(cs))
        else:
            cs = [int(costs)] * 4
        ents.append((k, mvt[dst], mvt[src] if src else 0, cs))
    n_braces = len(re.findall(r'\{\s*[\w:]+\s*,\s*MVT::', content))
    assert n_braces == len(ents), (cname, n_braces, len(ents))
    tables.append((cname, ents))

# ---------------------------------------------------------------- features, CPUs, scheduling models
rec = C.x86_records()
feats = sorted(n for n, (cl, b) in rec.items() if 'SubtargetFeature' in cl.split())
fidx = {d: i for i, d in enumerate(feats)}
WORDS = (len(feats) + 63) // 64
fname = {d: C.rec_field(rec[d][1], 'Name') for d in feats}
fimpl = {d: C.rec_field(rec[d][1], 'Implies') for d in feats}


def closure(d, out):
    for x in fimpl[d]:
        if x not in out:
            out.add(x)
            closure(x, out)
    return out


def bits(names):
    w = [0] * WORDS
    for n in names:
        j = fidx[n]
        w[j // 64] |= 1 << (j % 64)
    return w


getters = {}   # getter -> (default true?, [features])
levels = {}    # enum field -> [(feature, value)]
for d in feats:
    b = rec[d][1]
    field, value = C.rec_field(b, 'FieldName'), C.rec_field(b, 'Value')
    if value in ('true', 'false'):
        g = field[0].lower() + field[1:]
        if not re.fullmatch(r'\w+', g):
            continue  # ReservedRReg[X86::EDI] & co.: not a getter
        dflt, lst = getters.get(g, (value == 'false', []))
        assert dflt == (value == 'false'), g
        lst.append(d)
        getters[g] = (dflt, lst)
    else:
        levels.setdefault(field, []).append((d, value))
assert list(levels) == ['X86SSELevel'], levels

models = sorted(n for n, (cl, b) in rec.items() if cl.split()[:1] == ['SchedMachineModel'])
MDEF = {'IssueWidth': 1, 'MicroOpBufferSize': 0, 'LoopMicroOpBufferSize': 0, 'LoadLatency': 4, 'HighLatency': 10,
        'MispredictPenalty': 10}
mparams = {}
for m in models:
    b = rec[m][1]
    row = []
    for p, dv in MDEF.items():
        v = int(C.rec_field(b, p))
        row.append(dv if v < 0 else v)
    row.append(int(C.rec_field(b, 'PostRAScheduler')))
    row.append(int(C.rec_field(b, 'CompleteModel')))
    mparams[m] = row
procs = []
for n, (cl, b) in rec.items():
    if cl.split()[:1] != ['Processor']:
        continue
    procs.append((C.rec_field(b, 'Name'), C.rec_field(b, 'Features'), C.rec_field(b, 'TuneFeatures'),
                  C.rec_field(b, 'SchedModel')))
procs.sort()
assert len(set(p[0] for p in procs)) == len(procs)


def gstr(s):
    return '"' + s + '"'


o = []
o.append('// Generated by tools/gen_x86target.py from LLVM 23.1.5 (ValueTypes.td via llvm-min-tblgen -gen-vt,')
o.append('// ISDOpcodes.h, X86.td via llvm-min-tblgen --print-records). Do not edit; rerun the script.')
o.append('')
o.append('// ---- MVTs: MVT::SimpleValueType numbers (0 = INVALID_SIMPLE_VALUE_TYPE)')
o.append(f'let MVT_COUNT: i32 = {len(vts) + 1};')
for k, v in enumerate(vts):
    o.append(f'let MVT_{v[0]}: i32 = {k + 1};')
o.append(f'let MVT_SIZE: i32[{len(vts) + 1}] = [0, {", ".join(str(v[1]) for v in vts)}];')
o.append(f'let MVT_NELEM: i32[{len(vts) + 1}] = [0, {", ".join(str(v[6]) for v in vts)}];')
o.append(f'let MVT_ELT: i32[{len(vts) + 1}] = [0, {", ".join(str(mvt[v[7]]) if v[7] else "0" for v in vts)}];')
o.append('// bit 0 integer, 1 floating point, 2 vector, 3 scalable')
o.append(f'let MVT_KIND: i32[{len(vts) + 1}] = [0, {", ".join(str(int(v[2]) | int(v[3]) << 1 | int(v[4]) << 2 | int(v[5]) << 3) for v in vts)}];')
hv = open(os.devnull).read()
gvt = C.tblgen(['-gen-vt', '-I', 'include', 'include/llvm/CodeGen/ValueTypes.td'])
for m in re.finditer(r'^\s*(FIRST|LAST)_(\w+_)?VALUETYPE = (\w+),', gvt, re.M):
    o.append(f'let MVT_{m.group(1)}_{(m.group(2) or "VALUE_")[:-1]}: i32 = {mvt[m.group(3)]};')
o.append('')
o.append('// ---- ISD opcodes (ISD::NodeType values), then target (X86ISD) opcodes')
for k, n in enumerate(isds):
    o.append(f'let XISD_{n}: i32 = {k};')
o.append(f'let XISD_BUILTIN_OP_END: i32 = {BUILTIN_OP_END};')
for k, n in enumerate(x86isd):
    o.append(f'let XISD_{n}: i32 = {BUILTIN_OP_END + 1 + k};')
o.append(f'let XISD_COUNT: i32 = {BUILTIN_OP_END + 1 + len(x86isd)};')
o.append('// TTI::ShuffleKind')
for k, n in enumerate(SK):
    o.append(f'let {n.upper()}: i64 = {k};')
o.append('')
o.append('// ---- subtarget features (sorted by TableGen def name, like the X86 feature enum)')
o.append(f'let X86F_COUNT: i32 = {len(feats)};')
o.append(f'let X86F_WORDS: i32 = {WORDS};')
for i, d in enumerate(feats):
    o.append(f'let X86F_{d}: i32 = {i};')
o.append(f'let X86F_NAMES: const u8[:][] = [{", ".join(gstr(fname[d]) for d in feats)}];')
imp = []
for d in feats:
    imp += bits(closure(d, set()))
o.append(f'let X86F_IMPLIES: u64[{len(imp)}] = [{", ".join(str(x) for x in imp)}];')
o.append('// X86SSELevel set by a feature (0 = none; 1 SSE1 .. 9 AVX512)')
LV = ['NoSSE', 'SSE1', 'SSE2', 'SSE3', 'SSSE3', 'SSE41', 'SSE42', 'AVX', 'AVX2', 'AVX512']
sse = [0] * len(feats)
for d, v in levels['X86SSELevel']:
    sse[fidx[d]] = LV.index(v)
o.append(f'let X86F_SSE_LEVEL: i32[{len(feats)}] = [{", ".join(map(str, sse))}];')
o.append('')
o.append('// the enabled features of the current subtarget (tti_x86.goose x86_subtarget_init)')
o.append(f'var x86_bits: u64[{WORDS}] = [{", ".join(["0"] * WORDS)}];')
o.append('fn x86_has(f: i32) -> bool { ((x86_bits[f / 64] >> ((f % 64) as u64)) & 1) != 0 }')
o.append('// boolean subtarget fields (GET_SUBTARGETINFO_MACRO getters)')
for g in sorted(getters):
    dflt, lst = getters[g]
    e = ' || '.join(f'x86_has(X86F_{d})' for d in lst)
    if dflt:
        e = f'!({e})'
    o.append(f'fn xst_{g}() -> bool {{ {e} }}')
o.append('')
o.append('// ---- processors: name, features, tune features, scheduling model')
o.append(f'let X86CPU_COUNT: i32 = {len(procs)};')
o.append(f'let X86CPU_NAMES: const u8[:][] = [{", ".join(gstr(p[0]) for p in procs)}];')
cf, ct = [], []
for p in procs:
    cf += bits(p[1])
    ct += bits(p[2])
o.append(f'let X86CPU_FEATURES: u64[{len(cf)}] = [{", ".join(map(str, cf))}];')
o.append(f'let X86CPU_TUNING: u64[{len(ct)}] = [{", ".join(map(str, ct))}];')
o.append(f'let X86CPU_SCHED: i32[{len(procs)}] = [{", ".join(str(models.index(p[3])) for p in procs)}];')
o.append('// ---- scheduling models (MCSchedModel)')
o.append(f'let X86SM_NAMES: const u8[:][] = [{", ".join(gstr(m) for m in models)}];')
for j, p in enumerate(list(MDEF) + ['PostRAScheduler', 'CompleteModel']):
    nm = re.sub(r'(?<!^)(?=[A-Z])', '_', p).upper()
    o.append(f'let X86SM_{nm}: i32[{len(models)}] = [{", ".join(str(mparams[m][j]) for m in models)}];')
with open(os.path.join(C.SRC, 'gen_x86target.goose'), 'w') as f:
    f.write('\n'.join(o) + '\n')

# ---------------------------------------------------------------- tables file
o = []
o.append('// Generated by tools/gen_x86target.py from LLVM 23.1.5 lib/Target/X86/X86TargetTransformInfo.cpp: every static')
o.append('// cost table. Entry = (key: ISD / X86ISD (gen_x86target.goose) / TTI::ShuffleKind / interleave factor, dst MVT,')
o.append('// src MVT (conversion tables; else 0), 4 costs (RecipThroughput, Latency, CodeSize, SizeAndLatency; -1 none;')
o.append('// a CostTblEntry has its one cost in all four)). Do not edit; rerun the script.')
o.append('import std;')
for t, (nm, _) in enumerate(tables):
    o.append(f'let {nm}: i32 = {t};')
o.append(f'let XCT_COUNT: i32 = {len(tables)};')
start = [0]
for _, e in tables:
    start.append(start[-1] + len(e))
o.append(f'let XCT_START: i32[{len(start)}] = [{", ".join(map(str, start))}];')
flat = []
for _, e in tables:
    for k, d, s, cs in e:
        flat += [k, d, s] + cs
o.append(f'let XCE_COUNT: i32 = {start[-1]};')
o.append('// 7 numbers per entry, comma-separated')
o.append(f'let XCE_BLOB: const u8[:] = "{",".join(map(str, flat))}";')
o.append('var xce_data: i32[>..] = [];')
o.append('''// decode XCE_BLOB on first use
fn xce_init() {
    if xce_data.len > 0 { return; }
    var v: i64 = 0;
    var neg = false;
    for c in XCE_BLOB {
        if c == ',' { xce_data.push((if neg { -v } else { v }) as i32); v = 0; neg = false; }
        else if c == '-' { neg = true; }
        else { v = v * 10 + (c - '0') as i64; }
    }
    xce_data.push((if neg { -v } else { v }) as i32);
}''')
with open(os.path.join(C.SRC, 'gen_x86costs.goose'), 'w') as f:
    f.write('\n'.join(o) + '\n')
print(f'{len(vts)} MVTs, {len(isds)} ISD + {len(x86isd)} X86ISD opcodes, {len(feats)} features, {len(getters)} getters, '
      f'{len(procs)} CPUs, {len(models)} sched models, {len(tables)} tables / {start[-1]} entries', file=sys.stderr)
