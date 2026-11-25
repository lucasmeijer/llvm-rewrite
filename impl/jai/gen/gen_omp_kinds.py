#!/usr/bin/env python3
"""Generates src/gen_omp_kinds.jai from llvm/include/llvm/Frontend/OpenMP/OMPKinds.def (the parts OpenMPOpt and the
OpenMPIRBuilder pieces it uses read):

- `Omp_Rtl`: the RuntimeFunction enum (OMP_RTL entries in input order; the last one is `__last`).
- `OMP_RTL_NAMES`, `OMP_RTL_VARARG`, `OMP_RTL_SIG_OFFSET` / `OMP_RTL_SIG`: name, IsVarArg and the signature (return
  type, then argument types, terminated by `.END`) of every runtime function. All OpenMP pointer types (`IdentPtr`,
  `VoidPtr`, `ParallelTaskPtr`, `FuncPtrTy`, ...) are `.PTR` (address space 0: the default target and program address
  spaces on the targets we support); `SizeTy` is the DataLayout's intptr type.
- `Omp_Atom`: the attributes the attribute sets contain; `OMP_ATTR_SET_OFFSET` / `OMP_ATTR_ATOMS`: every attribute
  set (named OMP_ATTRS_SET or written inline), twice: index 2k is the set with OptimisticAttributes = false, 2k+1 with
  true, each terminated by `.END`.
- `OMP_RTL_ATTRS_OFFSET` (-1: no OMP_RTL_ATTRS entry) / `OMP_RTL_ATTRS`: per runtime function the attribute set ids of
  the function, the return value and the parameters (`fn, ret, nparams, p0, p1, ...`).
- `Omp_Icv` and the ICV_DATA_ENV / ICV_RT_SET / ICV_RT_GET tables.

Usage: python3 impl/jai/gen/gen_omp_kinds.py > impl/jai/src/gen_omp_kinds.jai
"""
import re

DEF = '/opt/llvm-project-23.1.5/llvm/include/llvm/Frontend/OpenMP/OMPKinds.def'

src = open(DEF).read()
src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
src = re.sub(r'//[^\n]*', '', src)
# drop `#if 0 ... #endif` blocks (the only conditionals in the file besides the #ifndef/#define guards)
src = re.sub(r'#if 0.*?#endif', '', src, flags=re.S)
src = re.sub(r'\\\n', ' ', src)
lines = [l for l in src.split('\n') if not l.strip().startswith('#')]
src = '\n'.join(lines)


def calls(name):
    """Every `name(...)` invocation with balanced parentheses, as the argument text."""
    out = []
    for m in re.finditer(r'(?<![A-Za-z0-9_])' + re.escape(name) + r'\s*\(', src):
        i = m.end()
        depth = 1
        j = i
        while depth:
            c = src[j]
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
            j += 1
        out.append(src[i:j - 1])
    return out


def split_args(s):
    args, depth, cur = [], 0, ''
    for c in s:
        if c in '(':
            depth += 1
        elif c == ')':
            depth -= 1
        if c == ',' and depth == 0:
            args.append(cur.strip())
            cur = ''
        else:
            cur += c
    args.append(cur.strip())
    return [' '.join(a.split()) for a in args]


TYPES = {'Void': 'VOID', 'Int1': 'I1', 'Int8': 'I8', 'Int16': 'I16', 'Int32': 'I32', 'Int63': 'I63', 'Int64': 'I64',
         'Double': 'DOUBLE', 'SizeTy': 'SIZE'}


def ty(t):
    if t in TYPES:
        return TYPES[t]
    assert t.endswith('Ptr') or t.endswith('PtrTy'), t
    return 'PTR'


# ---------------------------------------------------------------- runtime functions
rtls = []
for a in calls('__OMP_RTL'):
    args = split_args(a)
    name, vararg, ret = args[0], args[1], args[2]
    params = [x for x in args[3:] if x]
    assert vararg in ('true', 'false'), a
    rtls.append((name, vararg == 'true', ty(ret), [ty(p) for p in params]))
rtl_index = {r[0]: i for i, r in enumerate(rtls)}
assert len(rtl_index) == len(rtls)

# ---------------------------------------------------------------- attribute sets
ATOMS = []


def atom(a):
    if a not in ATOMS:
        ATOMS.append(a)
    return a


MEM = {
    'MemoryEffects::inaccessibleMemOnly(ModRefInfo::Ref)': 'MEM_INACC_REF',
    'MemoryEffects::inaccessibleOrArgMemOnly(ModRefInfo::Ref)': 'MEM_INACC_OR_ARG_REF',
    'MemoryEffects::argMemOnly() | MemoryEffects::inaccessibleMemOnly(ModRefInfo::Ref)': 'MEM_ARG_OR_INACC_REF',
    'MemoryEffects::inaccessibleMemOnly(ModRefInfo::Mod)': 'MEM_INACC_MOD',
    'MemoryEffects::inaccessibleOrArgMemOnly()': 'MEM_INACC_OR_ARG',
}
named_sets = {}


def eval_set(e, optimistic):
    """An attribute-set expression -> list of atoms."""
    e = e.strip()
    m = re.match(r'^OptimisticAttributes\s*\?(.*)$', e, re.S)
    if m:
        rest = m.group(1)
        depth = 0
        for k, c in enumerate(rest):
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
            elif c == ':' and depth == 0 and rest[k - 1] != ':' and rest[k + 1] != ':':
                return eval_set(rest[:k] if optimistic else rest[k + 1:], optimistic)
        raise Exception(e)
    if e.startswith('M.getDataLayout().getIntPtrType(Ctx)->getBitWidth() < 64'):
        return [atom('SIZE_TY_EXT')]
    if e in named_sets:
        return named_sets[e][1 if optimistic else 0]
    m = re.match(r'^AttributeSet\s*\((.*)\)$', e, re.S)
    assert m, e
    out = []
    for x in split_args(m.group(1)):
        if not x:
            continue
        mm = re.match(r'^EnumAttr\((\w+)\)$', x)
        if mm:
            out.append(atom(mm.group(1).upper()))
            continue
        mm = re.match(r'^MemoryAttr\((.*)\)$', x)
        if mm:
            out.append(atom(MEM[' '.join(mm.group(1).split())]))
            continue
        if x == 'NoCaptureAttr':
            out.append(atom('NOCAPTURE'))
            continue
        if x == 'AllocSizeAttr(0, std::nullopt)':
            out.append(atom('ALLOCSIZE_0'))
            continue
        if x == 'AllocKindAttr(AllocFnKind::Alloc | AllocFnKind::Uninitialized)':
            out.append(atom('ALLOCKIND_ALLOC_UNINIT'))
            continue
        if x == 'AllocKindAttr(AllocFnKind::Free)':
            out.append(atom('ALLOCKIND_FREE'))
            continue
        if x == 'AllocFamilyAttr("__kmpc_alloc_shared")':
            out.append(atom('ALLOC_FAMILY_SHARED'))
            continue
        raise Exception('unknown attribute ' + x)
    return out


for a in calls('__OMP_ATTRS_SET'):
    args = split_args(a)
    assert len(args) == 2, a
    named_sets[args[0]] = (eval_set(args[1], False), eval_set(args[1], True))

SETS = []   # list of (pessimistic atoms, optimistic atoms)


def set_id(e):
    v = (tuple(eval_set(e, False)), tuple(eval_set(e, True)))
    if v not in SETS:
        SETS.append(v)
    return SETS.index(v)


set_id('AttributeSet()')   # set 0: empty
rtl_attrs = {}
for a in calls('__OMP_RTL_ATTRS'):
    args = split_args(a)
    assert len(args) == 4, a
    name, fn, ret, params = args
    m = re.match(r'^ParamAttrs\s*\((.*)\)$', params, re.S)
    assert m, params
    ps = [x for x in split_args(m.group(1)) if x]
    assert name in rtl_index, name
    rtl_attrs[name] = (set_id(fn), set_id(ret), [set_id(p) for p in ps])

# ---------------------------------------------------------------- ICVs
icv_init = [split_args(a)[0] for a in calls('__ICV_INIT_VALUE')]
icvs = [split_args(a) for a in calls('__ICV_DATA_ENV')]
icv_set = {split_args(a)[0]: split_args(a)[1] for a in calls('__ICV_RT_SET')}
icv_get = {split_args(a)[0]: split_args(a)[1] for a in calls('__ICV_RT_GET')}

# ---------------------------------------------------------------- output
o = []
o.append('// GENERATED by impl/jai/gen/gen_omp_kinds.py from llvm/include/llvm/Frontend/OpenMP/OMPKinds.def. Do not edit.')
o.append('')
o.append('Omp_Rtl :: enum u16 {')
for r in rtls:
    o.append('    %s;' % r[0])
o.append('}')
assert rtls[-1][0] == '__last'
o.append('// the number of runtime functions (EnumeratedArray<..., OMPRTL___last>): every entry but the final `__last`')
o.append('OMP_RTL_COUNT :: %d;' % (len(rtls) - 1))
o.append('')
o.append('Omp_Ty :: enum u8 { END; VOID; I1; I8; I16; I32; I63; I64; DOUBLE; SIZE; PTR; }')
o.append('')
o.append('OMP_RTL_NAMES :: string.[')
for r in rtls:
    o.append('    "%s",' % r[0])
o.append('];')
o.append('OMP_RTL_VARARG :: bool.[')
o.append('    ' + ', '.join('true' if r[1] else 'false' for r in rtls))
o.append('];')
offs, sig = [], []
for r in rtls:
    offs.append(len(sig))
    sig += [r[2]] + r[3] + ['END']
o.append('OMP_RTL_SIG_OFFSET :: u16.[')
for k in range(0, len(offs), 16):
    o.append('    ' + ', '.join(str(x) for x in offs[k:k + 16]) + ',')
o.append('];')
o.append('OMP_RTL_SIG :: Omp_Ty.[')
for k in range(0, len(sig), 16):
    o.append('    ' + ', '.join('.' + x for x in sig[k:k + 16]) + ',')
o.append('];')
o.append('')
o.append('Omp_Atom :: enum u8 {')
o.append('    END;')
for a in ATOMS:
    o.append('    %s;' % a)
o.append('}')
aoffs, atoms = [], []
for pess, opt in SETS:
    for variant in (pess, opt):
        aoffs.append(len(atoms))
        atoms += list(variant) + ['END']
o.append('OMP_ATTR_SET_COUNT :: %d;' % len(SETS))
o.append('OMP_ATTR_SET_OFFSET :: u16.[')
for k in range(0, len(aoffs), 16):
    o.append('    ' + ', '.join(str(x) for x in aoffs[k:k + 16]) + ',')
o.append('];')
o.append('OMP_ATTR_ATOMS :: Omp_Atom.[')
for k in range(0, len(atoms), 12):
    o.append('    ' + ', '.join('.' + x for x in atoms[k:k + 12]) + ',')
o.append('];')
roffs, rattrs = [], []
for r in rtls:
    if r[0] not in rtl_attrs:
        roffs.append(-1)
        continue
    fn, ret, ps = rtl_attrs[r[0]]
    roffs.append(len(rattrs))
    rattrs += [fn, ret, len(ps)] + ps
o.append('OMP_RTL_ATTRS_OFFSET :: s16.[')
for k in range(0, len(roffs), 16):
    o.append('    ' + ', '.join(str(x) for x in roffs[k:k + 16]) + ',')
o.append('];')
o.append('OMP_RTL_ATTRS :: u16.[')
for k in range(0, len(rattrs), 16):
    o.append('    ' + ', '.join(str(x) for x in rattrs[k:k + 16]) + ',')
o.append('];')
o.append('')
o.append('Omp_Icv_Init :: enum u8 {')
for n in icv_init:
    o.append('    ICV_%s;' % n)
o.append('}')
o.append('Omp_Icv :: enum u8 {')
for a in icvs:
    o.append('    ICV_%s;' % a[0])
o.append('}')
o.append('Omp_Icv_Info :: struct { name: string; env_var_name: string; init: Omp_Icv_Init; setter: s32; getter: s32; }')
o.append('// setter / getter: the Omp_Rtl, -1 if the ICV has none')
o.append('OMP_ICVS :: Omp_Icv_Info.[')
for a in icvs:
    name, env, init = a
    s = icv_set.get(name)
    g = icv_get.get(name)
    o.append('    .{"%s", "%s", .%s, %s, %s},' % (name, env, init, rtl_index[s] if s else -1, rtl_index[g] if g else -1))
o.append('];')
print('\n'.join(o))
