#!/usr/bin/env python3
"""Generate src/gen_x86_tti.jai from LLVM 23.1.5's X86 target sources.

* every static cost table of X86TargetTransformInfo.cpp (CostKindTblEntry, TypeConversionCostKindTblEntry and
  CostTblEntry) as a constant array named XT_<function>_<table> (the function prefix keeps tables with the same
  name in different functions apart), entries in source order (CostTableLookup returns the first match);
* the ISD / X86ISD / TTI::SK_* opcodes the tables use (ISD_* constants);
* the X86 subtarget features of X86.td with their transitive implications (X86F_* bit numbers) and the feature
  lists of every CPU in X86.td (ProcModel / ProcessorModel definitions), for -mattr / -mcpu / "target-features".

MVT encoding (shared with tti_x86.jai): element code | (number of elements << 8); 0 elements = scalar.
Usage: impl/jai/gen/gen_x86_tti.py   (writes impl/jai/src/gen_x86_tti.jai)
"""
import os, re, sys

LLVM = '/opt/llvm-project-23.1.5/llvm'
TTI = LLVM + '/lib/Target/X86/X86TargetTransformInfo.cpp'
TD = LLVM + '/lib/Target/X86/X86.td'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'gen_x86_tti.jai')

ELT = {'i1': 1, 'i2': 2, 'i4': 3, 'i8': 4, 'i16': 5, 'i32': 6, 'i64': 7, 'i128': 8, 'f16': 9, 'bf16': 10,
       'f32': 11, 'f64': 12, 'f80': 13, 'f128': 14, 'Other': 15, 'isVoid': 16}


def mvt(name):
    if name in ELT:
        return ELT[name]
    m = re.fullmatch(r'v(\d+)(\w+)', name)
    assert m and m.group(2) in ELT, name
    return ELT[m.group(2)] | (int(m.group(1)) << 8)


text = open(TTI).read()
# function boundaries: "X86TTIImpl::name(" at the start of a definition
starts = [(m.start(), m.group(1)) for m in re.finditer(r'\n[^\n;{}]*?X86TTIImpl::(\w+)\(', text)]
starts.append((len(text), None))
tables = []
isds = []
seen = set()
for k in range(len(starts) - 1):
    pos, fname = starts[k]
    body = text[pos:starts[k + 1][0]]
    for tm in re.finditer(r'static const (CostKindTblEntry|TypeConversionCostKindTblEntry|CostTblEntry)\s+(\w+)\[\]\s*=?\s*\{(.*?)\n\s*\};',
                          body, re.S):
        kind, tname, content = tm.groups()
        content = re.sub(r'//[^\n]*', '', content)
        ents = []
        conv = kind == 'TypeConversionCostKindTblEntry'
        if kind == 'CostTblEntry':
            pat = r'\{\s*((?:X86ISD|ISD|TTI)::\w+)\s*,\s*MVT::(\w+)\s*,\s*(\d+)\s*\}'
        elif conv:
            pat = r'\{\s*((?:X86ISD|ISD)::\w+)\s*,\s*MVT::(\w+)\s*,\s*MVT::(\w+)\s*,\s*\{([^}]*)\}\s*\}'
        else:
            pat = r'\{\s*((?:X86ISD|ISD|TTI)::\w+)\s*,\s*MVT::(\w+)\s*,\s*\{([^}]*)\}\s*\}'
        for em in re.finditer(pat, content):
            g = em.groups()
            isd = g[0].replace('X86ISD::', 'X86_').replace('ISD::', '').replace('TTI::', '')
            if isd not in isds:
                isds.append(isd)
            if kind == 'CostTblEntry':
                ents.append((isd, mvt(g[1]), 0, [int(g[2]), -1, -1, -1]))
            else:
                costs = g[3] if conv else g[2]
                cs = [c.strip() for c in costs.split(',') if c.strip()]
                cs = [int(c) for c in cs] + [-1] * (4 - len(cs))
                if conv:
                    ents.append((isd, mvt(g[1]), mvt(g[2]), cs))
                else:
                    ents.append((isd, mvt(g[1]), 0, cs))
        # the interleaved-access tables are keyed by the interleave factor: {Factor, MVT, Cost} (isd = the factor)
        if kind == 'CostTblEntry' and not ents:
            for em in re.finditer(r'\{\s*(\d+)\s*,\s*MVT::(\w+)\s*,\s*(\d+)\s*\}', content):
                ents.append((int(em.group(1)), mvt(em.group(2)), 0, [int(em.group(3)), -1, -1, -1]))
        # sanity: count the entries by counting '{' at depth 1
        n_open = len(re.findall(r'\{\s*(?:X86ISD|ISD|TTI)::', content)) + len(re.findall(r'\{\s*\d+\s*,\s*MVT::', content))
        assert n_open == len(ents), (fname, tname, n_open, len(ents))
        name = f'XT_{fname}_{tname}'
        assert name not in seen, name
        seen.add(name)
        tables.append((name, ents))

EXTRA_ISDS = ['FREM', 'TRUNCATE', 'ZERO_EXTEND', 'SIGN_EXTEND', 'ANY_EXTEND', 'FP_TO_UINT', 'FP_TO_SINT', 'UINT_TO_FP',
              'SINT_TO_FP', 'FP_ROUND', 'FP_EXTEND', 'BITCAST', 'ADDRSPACECAST', 'SETCC', 'SELECT', 'VSELECT',
              'EXTRACT_VECTOR_ELT', 'INSERT_VECTOR_ELT', 'ABS', 'BITREVERSE', 'BSWAP', 'CTLZ', 'CTPOP', 'CTTZ',
              'CTLZ_ZERO_UNDEF', 'CTTZ_ZERO_UNDEF', 'FSHL', 'FSHR', 'ROTL', 'ROTR', 'FMAXNUM', 'FMINNUM', 'SADDSAT',
              'SMAX', 'SMIN', 'SSUBSAT', 'UADDSAT', 'UMAX', 'UMIN', 'USUBSAT', 'FSQRT', 'SADDO', 'UADDO', 'SSUBO',
              'USUBO', 'SMULO', 'UMULO', 'BR_JT', 'BRIND', 'LOAD', 'STORE', 'FNEG', 'FADD', 'FSUB', 'FMUL', 'FDIV',
              'ADD', 'SUB', 'MUL', 'SDIV', 'UDIV', 'SREM', 'UREM', 'SHL', 'SRL', 'SRA', 'AND', 'OR', 'XOR',
              'FCOPYSIGN', 'FABS', 'FMA', 'FMAXIMUM', 'FMINIMUM', 'FMAXIMUMNUM', 'FMINIMUMNUM', 'FCEIL', 'FFLOOR',
              'FNEARBYINT', 'FRINT', 'FROUND', 'FROUNDEVEN', 'FTRUNC', 'LROUND', 'LLROUND', 'LRINT', 'LLRINT',
              'FPOW', 'FPOWI', 'FEXP', 'FEXP2', 'FEXP10', 'FLOG', 'FLOG2', 'FLOG10', 'FSIN', 'FCOS', 'FTAN',
              'FSINCOS', 'FLDEXP', 'FFREXP', 'SMUL_LOHI', 'UMUL_LOHI', 'MULHS', 'MULHU', 'SMULFIX', 'UMULFIX',
              'SMULFIXSAT', 'UMULFIXSAT', 'SDIVFIX', 'UDIVFIX', 'SDIVFIXSAT', 'UDIVFIXSAT', 'SDIVREM', 'UDIVREM',
              'FP_TO_SINT_SAT', 'FP_TO_UINT_SAT', 'SSHLSAT', 'USHLSAT', 'MLOAD', 'MSTORE', 'MGATHER', 'MSCATTER',
              'VECREDUCE_ADD', 'VECREDUCE_MUL', 'VECREDUCE_AND', 'VECREDUCE_OR', 'VECREDUCE_XOR',
              'VECREDUCE_SMAX', 'VECREDUCE_SMIN', 'VECREDUCE_UMAX', 'VECREDUCE_UMIN', 'VECREDUCE_FADD',
              'VECREDUCE_FMUL', 'VECREDUCE_FMAX', 'VECREDUCE_FMIN', 'VECREDUCE_SEQ_FADD', 'VECREDUCE_SEQ_FMUL',
              'VECREDUCE_FMAXIMUM', 'VECREDUCE_FMINIMUM', 'SCMP', 'UCMP', 'AVGFLOORS', 'AVGFLOORU', 'AVGCEILS',
              'AVGCEILU', 'ABDS', 'ABDU', 'IS_FPCLASS', 'FCANONICALIZE', 'CLMUL', 'CLMULH', 'CLMULR',
              'SELECT_CC', 'BR_CC', 'BRCOND', 'GlobalAddress', 'ConstantPool', 'VAARG', 'DYNAMIC_STACKALLOC',
              'STRICT_FADD', 'FMAD', 'PARITY', 'SPLAT_VECTOR', 'BUILD_VECTOR', 'CONCAT_VECTORS',
              'EXTRACT_SUBVECTOR', 'INSERT_SUBVECTOR', 'VECTOR_SHUFFLE', 'SCALAR_TO_VECTOR', 'VECTOR_COMPRESS',
              'GET_ACTIVE_LANE_MASK', 'VECTOR_REVERSE', 'VECTOR_SPLICE', 'FREEZE', 'X86_PMULUDQ', 'X86_VROTLI',
              'X86_VSHLI', 'X86_VSRLI', 'X86_VSRAI']
for e in EXTRA_ISDS:
    if e not in isds:
        isds.append(e)

# ---- subtarget features (X86.td)
td = open(TD).read()
feats = []
for m in re.finditer(r'\ndef (\w+)\s*:\s*SubtargetFeature<\s*"([^"]*)"\s*,(.*?)>\s*;', td, re.S):
    dname, sname, rest = m.groups()
    im = re.search(r'\[([^\]]*)\]\s*$', rest.strip(), re.S)
    impl = [x.strip() for x in im.group(1).split(',') if x.strip()] if im else []
    feats.append((dname, sname, impl))
idx = {d: i for i, (d, _, _) in enumerate(feats)}
NWORDS = (len(feats) + 63) // 64


def closure(i, acc):
    for d in feats[i][2]:
        j = idx[d]
        if j not in acc:
            acc.add(j)
            closure(j, acc)
    return acc


# CPU feature lists: X86.td builds them from list<SubtargetFeature> lets; evaluate the lets.
lets = {}
for m in re.finditer(r'\n\s*(?:defvar|list<SubtargetFeature>)\s+(\w+)\s*=\s*(.*?);', td, re.S):
    lets[m.group(1)] = m.group(2)


def eval_list(expr, depth=0):
    expr = expr.strip()
    if expr.startswith("ProcessorFeatures."):
        expr = expr[len("ProcessorFeatures."):]
    assert depth < 50, expr
    if expr.startswith('!listconcat('):
        inner = expr[len('!listconcat('):-1]
        parts, level, cur = [], 0, ''
        for ch in inner:
            if ch == '[' or ch == '(':
                level += 1
            if ch == ']' or ch == ')':
                level -= 1
            if ch == ',' and level == 0:
                parts.append(cur)
                cur = ''
            else:
                cur += ch
        parts.append(cur)
        out = []
        for p in parts:
            out += eval_list(p, depth + 1)
        return out
    if expr.startswith('!listremove('):
        inner = expr[len('!listremove('):-1]
        level, cut = 0, None
        for k, ch in enumerate(inner):
            if ch in '[(':
                level += 1
            if ch in '])':
                level -= 1
            if ch == ',' and level == 0:
                cut = k
                break
        a = eval_list(inner[:cut], depth + 1)
        b = eval_list(inner[cut + 1:], depth + 1)
        return [x for x in a if x not in b]
    if expr.startswith('['):
        return [x.strip() for x in expr[1:-1].split(',') if x.strip()]
    if expr in lets:
        return eval_list(lets[expr], depth + 1)
    raise AssertionError('cannot evaluate ' + expr)


cpus = []
for m in re.finditer(r'\ndef\s*:\s*(ProcModel|Proc)<\s*"([^"]+)"\s*,(.*?)>\s*;', td, re.S):
    kind, name, rest = m.groups()
    rest = re.sub(r'//[^\n]*', '', rest)
    # ProcModel<Name, SchedModel, Features, TuneFeatures>; Proc<Name, Features, TuneFeatures>
    args, level, cur = [], 0, ''
    for ch in rest:
        if ch in '[(':
            level += 1
        if ch in '])':
            level -= 1
        if ch == ',' and level == 0:
            args.append(cur)
            cur = ''
        else:
            cur += ch
    args.append(cur)
    args = [a.strip() for a in args if a.strip()]
    if kind == 'ProcModel':
        f, t = args[1], args[2]
    else:
        f, t = args[0], args[1]
    try:
        fl, tl = eval_list(f), eval_list(t)
    except AssertionError as e:
        print('warning: CPU', name, e, file=sys.stderr)
        continue
    cpus.append((name, [x for x in fl if x in idx], [x for x in tl if x in idx]))
# foreach loops: "foreach P = ["...", "..."] in { def : ProcModel<P, ...> }"
for m in re.finditer(r'\nforeach\s+(\w+)\s*=\s*\[([^\]]*)\]\s*in\s*\{(.*?)\n\}', td, re.S):
    var, names, body = m.groups()
    for dm in re.finditer(r'def\s*:\s*(ProcModel|Proc)<\s*' + var + r'\s*,(.*?)>\s*;', body, re.S):
        kind, rest = dm.groups()
        args = [a.strip() for a in re.split(r',(?![^\[]*\])', re.sub(r'//[^\n]*', '', rest)) if a.strip()]
        f, t = (args[1], args[2]) if kind == 'ProcModel' else (args[0], args[1])
        fl, tl = eval_list(f), eval_list(t)
        for n in re.findall(r'"([^"]+)"', names):
            cpus.append((n, [x for x in fl if x in idx], [x for x in tl if x in idx]))

with open(OUT, 'w') as o:
    o.write('// Generated by gen/gen_x86_tti.py from LLVM 23.1.5 (X86TargetTransformInfo.cpp, X86.td). Do not edit.\n')
    o.write('// MVT encoding: element code | (elements << 8), see tti_x86.jai.\n\n')
    for k, i in enumerate(isds):
        o.write(f'ISD_{i} : u32 : {k + 1};\n')
    o.write('\n')
    for e, c in ELT.items():
        o.write(f'MVE_{e.upper()} : u32 : {c};\n')
    o.write('\nXCost_Entry :: struct { isd: u32; dst: u32; src: u32; c: [4] s32; }\n\n')
    for name, ents in tables:
        o.write(f'{name} :: XCost_Entry.[\n')
        for isd, d, s, cs in ents:
            key = str(isd) if isinstance(isd, int) else f'ISD_{isd}'
            o.write(f'    .{{{key}, {d}, {s}, .[{cs[0]}, {cs[1]}, {cs[2]}, {cs[3]}]}},\n')
        o.write('];\n')
    o.write(f'\nX86_FEATURE_WORDS :: {NWORDS};\n')
    for i, (d, s, _) in enumerate(feats):
        o.write(f'X86F_{d} :: {i};\n')
    fields = {}
    for m in re.finditer(r'\ndef (\w+)\s*:\s*SubtargetFeature<\s*"([^"]*)"\s*,\s*"(\w+)"\s*,\s*"(\w+)"', td):
        d, _, fld, val = m.groups()
        if val == 'true' and d in idx:
            fields.setdefault(fld, []).append(d)
    for fld, ds in sorted(fields.items()):
        if len(ds) == 1:
            o.write(f'X86FLD_{fld} :: X86F_{ds[0]};\n')
    o.write('\nX86_Feature_Info :: struct { name: string; implies: [X86_FEATURE_WORDS] u64; }\n')
    o.write('X86_FEATURES :: X86_Feature_Info.[\n')
    for i, (d, s, _) in enumerate(feats):
        bits = closure(i, set())
        words = [0] * NWORDS
        for b in bits:
            words[b // 64] |= 1 << (b % 64)
        o.write(f'    .{{"{s}", .[{", ".join(hex(w) for w in words)}]}},\n')
    o.write('];\n')
    o.write('\nX86_Cpu_Info :: struct { name: string; features: [X86_FEATURE_WORDS] u64; tune: [X86_FEATURE_WORDS] u64; }\n')
    o.write('X86_CPUS :: X86_Cpu_Info.[\n')
    def words_of(fl):
        bits = set()
        for f in fl:
            bits.add(idx[f])
            closure(idx[f], bits)
        words = [0] * NWORDS
        for b in bits:
            words[b // 64] |= 1 << (b % 64)
        return '.[' + ', '.join(hex(w) for w in words) + ']'
    for name, fl, tl in cpus:
        o.write(f'    .{{"{name}", {words_of(fl)}, {words_of(tl)}}},\n')
    o.write('];\n')
print(f'{len(tables)} tables, {sum(len(e) for _, e in tables)} entries, {len(feats)} features, {len(cpus)} CPUs -> {OUT}')
