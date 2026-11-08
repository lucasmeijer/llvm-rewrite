#!/usr/bin/env python3
"""Translate the operation-action part of LLVM 23.1.5's X86TargetLowering constructor
(lib/Target/X86/X86ISelLowering.cpp, from the constructor's first line to computeRegisterProperties) into Jai:
src/gen_x86_lowering.jai, procedure `x86_lowering_actions(st: *X86_Lowering)`.

The C++ is close enough to Jai that a token-level rewrite works:
  Subtarget.hasX()       -> st_hasX(st)          (procedures in tti_x86.jai)
  MVT::v4i32             -> MVT_v4i32           (constants generated below, encoding of tti_x86.jai)
  MVT::xxx_valuetypes()  -> mvt_xxx_valuetypes()
  ISD::FOO               -> ISD_FOO             (one constant per name used here or in gen_x86_tti.jai)
  {a, b} in call args / for ranges -> u32.[a, b]
  Legal/Custom/...       -> LA_LEGAL/...
  setOperationAction(...)-> soa(st, ...) etc.;  for (T X : R) -> for X: R
Statements that do not affect legality queries (DAG combines, libcalls, FP immediates, scheduling, atomics sizes)
are dropped; anything the translator does not know makes it stop with an error.

Usage: impl/jai/gen/gen_x86_lowering.py
"""
import os, re, sys

LLVM = '/opt/llvm-project-23.1.5/llvm'
SRC = LLVM + '/lib/Target/X86/X86ISelLowering.cpp'
VT = LLVM + '/include/llvm/CodeGen/ValueTypes.td'
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'src', 'gen_x86_lowering.jai')
TTI_GEN = os.path.join(HERE, '..', 'src', 'gen_x86_tti.jai')

ELT = {'i1': 1, 'i2': 2, 'i4': 3, 'i8': 4, 'i16': 5, 'i32': 6, 'i64': 7, 'i128': 8, 'f16': 9, 'bf16': 10,
       'f32': 11, 'f64': 12, 'f80': 13, 'f128': 14, 'Other': 15, 'isVoid': 16, 'ppcf128': 17, 'x86amx': 18,
       'Glue': 19, 'Untyped': 20, 'token': 21, 'aarch64svcount': 22, 'spirvbuiltin': 23, 'amdgpuBufferFatPointer': 24,
       'amdgpuBufferStridedPointer': 25, 'MetadataVT': 26, 'iPTR': 27, 'iAny': 28, 'fAny': 29, 'vAny': 30,
       'Any': 31, 'pAny': 32, 'externref': 33, 'funcref': 34, 'exnref': 35, 'f8E4M3FN': 36, 'f8E5M2': 37,
       'i256': 38, 'i512': 39, 'x86fp80': 13, 'x86mmx': 40}
SCALABLE = 1 << 30

# ---- value types (ValueTypes.td): name -> encoding, in definition order
vts = []
for m in re.finditer(r'^def (\w+)\s*:\s*(VTInt|VTFP|VTVec|VTScalableVec|ValueType|VTAny|VTCheriCapability)?<([^>]*)>', open(VT).read(), re.M):
    name, kind, args = m.groups()
    if kind == 'VTInt' or kind == 'VTFP':
        if name in ELT:
            vts.append((name, ELT[name], kind))
    elif kind == 'VTVec' or kind == 'VTScalableVec':
        a = [x.strip() for x in args.split(',')]
        n, e = int(a[0]), a[1]
        if e in ELT:
            enc = ELT[e] | (n << 8) | (SCALABLE if kind == 'VTScalableVec' else 0)
            vts.append((name, enc, kind))
for sp in ['x86mmx', 'Other', 'isVoid', 'Glue', 'Untyped', 'x86amx', 'ppcf128', 'token', 'iPTR']:
    if sp not in [n for n, _, _ in vts]:
        vts.append((sp, ELT[sp], 'special'))
vt_names = {n for n, _, _ in vts}

text = open(SRC).read()
start = text.index('X86TargetLowering::X86TargetLowering(const X86TargetMachine &TM,')
start = text.index('{', start) + 1
end = text.index('computeRegisterProperties(Subtarget.getRegisterInfo());', start)
body = text[start:end]
tlb = open(LLVM + '/lib/CodeGen/TargetLoweringBase.cpp').read()
ia = tlb.index('void TargetLoweringBase::initActions() {')
ia_end = tlb.index('\nMVT TargetLoweringBase::getScalarShiftAmountTy', ia)
init_body = tlb[tlb.index('{', ia) + 1:tlb.rindex('}', ia, ia_end)]
init_body = re.sub(r'//[^\n]*', '', init_body)
init_body = re.sub(r'#define[^\n]*\\\n[^\n]*\n#include[^\n]*\n', '', init_body)
def drop_im_loops(t):
    while True:
        k = t.find('for (unsigned IM')
        if k < 0:
            return t
        j = t.index('{', k)
        depth = 1
        j += 1
        while depth:
            if t[j] == '{':
                depth += 1
            elif t[j] == '}':
                depth -= 1
            j += 1
        t = t[:k] + t[j:]
init_body = drop_im_loops(init_body)
init_body = re.sub(r'memset\([^;]*;|llvm::fill\([^;]*;', '', init_body)
# the i2/i4 "every opcode is Expand" loop is applied in x86_get_op_action
k = init_body.index('for (ISD::NodeType NT : enum_seq(')
k2 = init_body.index('}', init_body.index('OpActions[', k))
init_body = init_body[:k] + init_body[k2 + 1:]
if os.environ.get('DEBUG_INIT'):
    print(init_body); sys.exit(0)
body = init_body + '\n@@X86@@\n' + body
body = re.sub(r'//[^\n]*', '', body)
body = re.sub(r'/\*.*?\*/', '', body, flags=re.S)

# ---- statement-level drops (balanced to the terminating ';')
DROP_CALLS = ['setAtomicLoadExtAction', 'setIndexedLoadAction', 'setIndexedStoreAction', 'setIndexedMaskedLoadAction',
              'setIndexedMaskedStoreAction', 'AddPromotedToType', 'setTargetDAGCombine', 'addLegalFPImmediate', 'setSchedulingPreference',
              'setMaxAtomicSizeInBitsSupported', 'setMaxDivRemBitWidthSupported',
              'setMaxLargeFPConvertBitWidthSupported', 'setStackPointerRegisterToSaveRestore',
              'setBooleanContents', 'setBooleanVectorContents', 'addBypassSlowDiv',
              'TmpFlt.changeSign', 'TmpFlt2.changeSign', 'TmpFlt2.convert', 'assert']


def find_stmt_end(s, i):
    depth = 0
    while i < len(s):
        c = s[i]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif c == ';' and depth == 0:
            return i
        i += 1
    raise ValueError('no end')


def drop_calls(s):
    out, i = [], 0
    pat = re.compile(r'\b(' + '|'.join(re.escape(c) for c in DROP_CALLS) + r')\s*\(')
    while True:
        m = pat.search(s, i)
        if not m:
            out.append(s[i:])
            break
        out.append(s[i:m.start()])
        e = find_stmt_end(s, m.start())
        out.append('{}')   # keep an empty statement so "if (c) dropped();" stays valid
        i = e + 1
    return ''.join(out)


body = drop_calls(body)
# only guards dropped FP-immediate statements
body = re.sub(r'getRegClassFor\([^)]*\)\s*==\s*&X86::\w+', 'false', body)
# APFloat temporaries and "bool ignored;" only feed addLegalFPImmediate
body = re.sub(r'const X86RegisterInfo \*RegInfo = Subtarget.getRegisterInfo\(\);', '', body)
body = re.sub(r'APFloat\s+\w+\s*(=[^;]*|\([^;]*\))?;', '{}', body)
body = re.sub(r'bool ignored;', '{}', body)

# ---- lambdas: setF16Action / SetFPMinMaxAction become procedures written in tti_x86.jai
lambdas = {}
for lname in ['setF16Action', 'SetFPMinMaxAction', 'setGroup']:
    m = re.search(r'auto\s+' + lname + r'\s*=\s*\[&\]\s*\(MVT VT(?:, LegalizeAction Action)?\)\s*\{', body)
    if m:
        depth, j = 1, m.end()
        while depth:
            if body[j] == '{':
                depth += 1
            elif body[j] == '}':
                depth -= 1
            j += 1
        lam_body = body[m.end():j - 1]
        assert body[j] == ';'
        lambdas[lname] = lam_body
        body = body[:m.start()] + body[j + 1:]

# ---- addRegisterClass(MVT::x, <regclass expression>) -> add_reg_class(st, MVT_x)
def rewrite_regclass(s):
    out, i = [], 0
    while True:
        k = s.find('addRegisterClass(', i)
        if k < 0:
            out.append(s[i:])
            break
        out.append(s[i:k])
        e = find_stmt_end(s, k)
        inner = s[k + len('addRegisterClass('):e]
        inner = inner[:inner.rindex(')')]
        vt = inner.split(',')[0].strip()
        out.append(f'add_reg_class(st, {vt});')
        i = e + 1
    return ''.join(out)


body = rewrite_regclass(body)

isd_names = set()


def tr(s):
    s = re.sub(r'for\s*\(\s*(?:auto|MVT|unsigned|ISD::NodeType|u32|const auto &|auto &)\s+(\w+)\s*:\s*', r'for (\1 : ', s)
    # ternaries in this constructor are all "cond ? A : B" inside a call argument or an initializer
    def ternary(m):
        return f'{m.group(1)} ifx {m.group(2).strip()} then {m.group(3).strip()} else {m.group(4).strip()}'
    s = re.sub(r'(,|\s=\s)([^,;?{}]+?)\?\s*([\w:]+)\s*:\s*([\w:]+)\s*(?=[);])', ternary, s)
    s = re.sub(r'\bSubtarget\.(\w+)\(\)', r'st_\1(st)', s)
    s = s.replace('TM.getOptLevel() >= CodeGenOptLevel::Default', 'true')
    s = s.replace('TM.Options.ExceptionModel != ExceptionHandling::SjLj', 'true')
    s = re.sub(r'\bTM\.getPointerSizeInBits\(0\)', 'st_ptr_bits(st)', s)
    s = s.replace('MVT::getIntegerVT(', 'mvt_int(').replace('MVT::getVectorVT(', 'mvt_vec(')
    s = re.sub(r'\bMVT::(\w+_valuetypes)\(\)', r'mvt_\1()', s)
    s = re.sub(r'\b(\w+)\.getVectorElementType\(\)', r'mvt_elt(\1)', s)
    s = re.sub(r'\b(\w+)\.getVectorNumElements\(\)', r'mvt_n(\1)', s)
    s = re.sub(r'\b(\w+)\.getScalarSizeInBits\(\)', r'mvt_scalar_bits(\1)', s)
    s = re.sub(r'\b(\w+)\.getSizeInBits\(\)', r'mvt_bits(\1)', s)
    s = re.sub(r'\b(\w+)\.getFixedSizeInBits\(\)', r'mvt_bits(\1)', s)
    s = re.sub(r'\b(\w+)\.isValid\(\)', r'(\1 != 0)', s)
    s = re.sub(r'\b(\w+)\.is512BitVector\(\)', r'(mvt_bits(\1) == 512)', s)
    s = re.sub(r'\b(\w+)\.is256BitVector\(\)', r'(mvt_bits(\1) == 256)', s)
    s = re.sub(r'\b(\w+)\.is128BitVector\(\)', r'(mvt_bits(\1) == 128)', s)
    s = re.sub(r'\b(\w+)\.isFloatingPoint\(\)', r'mvt_is_fp(\1)', s)
    s = re.sub(r'\b(\w+)\.isInteger\(\)', r'mvt_is_int(\1)', s)
    s = re.sub(r'\b(\w+)\.isVector\(\)', r'mvt_is_vec(\1)', s)
    s = re.sub(r'\b(\w+)\.SimpleTy\b', r'\1', s)

    def mvt_const(m):
        n = m.group(1)
        assert n in vt_names, n
        return 'MVT_' + n
    s = re.sub(r'\bMVT::(\w+)', mvt_const, s)

    def isd(m):
        n = (m.group(1) or '') + m.group(2)
        n = n.replace('X86ISD::', 'X86_')
        isd_names.add(n)
        return 'ISD_' + n
    s = re.sub(r'\b(X86ISD::)?ISD::(\w+)', lambda m: isd(m) if not m.group(1) else 'ISD_X86_' + m.group(2), s)
    s = re.sub(r'\bX86ISD::(\w+)', lambda m: (isd_names.add('X86_' + m.group(1)), 'ISD_X86_' + m.group(1))[1], s)
    s = re.sub(r'\bISD::CondCode\b', 'u32', s)
    for a, b in [('Legal', 'LA_LEGAL'), ('Custom', 'LA_CUSTOM'), ('Expand', 'LA_EXPAND'), ('Promote', 'LA_PROMOTE'),
                 ('LibCall', 'LA_LIBCALL')]:
        s = re.sub(r'\b' + a + r'\b', b, s)
    return s


body = tr(body)
lambda_bodies = {k: tr(v) for k, v in lambdas.items()}

# ---- braces: "{" that starts a list (after "(", ",", ":" or "=") becomes "u32.[" ... "]"
def lists(s):
    out = []
    stack = []
    i = 0
    prev_sig = ''
    while i < len(s):
        c = s[i]
        if c == '{':
            if prev_sig in '(,:=':
                out.append('u32.[')
                stack.append(']')
            else:
                out.append('{')
                stack.append('}')
        elif c == '}':
            out.append(stack.pop())
        else:
            out.append(c)
        if not c.isspace():
            prev_sig = c
        i += 1
    return ''.join(out)


body = lists(body)
lambda_bodies = {k: lists(v) for k, v in lambda_bodies.items()}

# ---- for (X : R) -> for X: R   (balanced)
def fors(s):
    out, i = [], 0
    while True:
        k = s.find('for (', i)
        if k < 0:
            out.append(s[i:])
            break
        out.append(s[i:k])
        j = k + len('for (')
        depth = 1
        while depth:
            if s[j] == '(':
                depth += 1
            elif s[j] == ')':
                depth -= 1
            j += 1
        inner = s[k + len('for ('):j - 1]
        if ' : ' not in inner:
            print('cannot translate for loop:', inner, file=sys.stderr)
            sys.exit(1)
        var, rng = inner.split(' : ', 1)
        out.append(f'for {var.strip()}: {rng.strip()} ')
        i = j
    return ''.join(out)


body = fors(body)
lambda_bodies = {k: fors(v) for k, v in lambda_bodies.items()}

# ---- calls
CALLS = {'setOperationAction': 'soa', 'setOperationPromotedToType': 'sopt', 'setLoadExtAction': 'slea',
         'setTruncStoreAction': 'stsa', 'setCondCodeAction': 'scca', 'SetFPMinMaxAction': 'set_fp_min_max_action',
         'setF16Action': 'set_f16_action', 'setGroup': 'set_group', 'isOperationExpandOrLibCall': 'is_op_expand_or_libcall',
         'isOperationExpand': 'is_op_expand', 'isOperationCustom': 'is_op_custom', 'isTypeLegal': 'is_type_legal_mvt'}


def calls(s):
    for a, b in CALLS.items():
        s = re.sub(r'\b' + a + r'\s*\(', b + '(st, ', s)
    return s


body = calls(body)
lambda_bodies = {k: calls(v) for k, v in lambda_bodies.items()}

# declarations
body = re.sub(r'\b(?:bool|LegalizeAction|MVT|unsigned|auto)\s+(\w+)\s*=', r'\1 :=', body)

# sanity: every identifier call must be known
known = set(CALLS.values()) | {'add_reg_class', 'mvt_int', 'mvt_vec', 'mvt_elt', 'mvt_n', 'mvt_bits', 'mvt_scalar_bits',
                               'mvt_is_fp', 'mvt_is_int', 'mvt_is_vec', 'if', 'for', 'ifx', 'st_ptr_bits'}
for m in re.finditer(r'\b([A-Za-z_]\w*)\s*\(', body + ' '.join(lambda_bodies.values())):
    n = m.group(1)
    if n in known or n.startswith('st_') or n.startswith('mvt_'):
        continue
    print('unknown call:', n, file=sys.stderr)
    sys.exit(1)

# ISD names also used by the cost tables
for m in re.finditer(r'^ISD_(\w+) :', open(TTI_GEN).read(), re.M):
    isd_names.add(m.group(1))

with open(OUT, 'w') as o:
    o.write('// Generated by gen/gen_x86_lowering.py from LLVM 23.1.5 lib/Target/X86/X86ISelLowering.cpp\n')
    o.write('// (the X86TargetLowering constructor up to computeRegisterProperties). Do not edit.\n\n')
    for name, enc, kind in vts:
        o.write(f'MVT_{name} : u32 : {enc};\n')
    o.write('\nMVT_ALL :: u32.[' + ', '.join(f'MVT_{n}' for n, _, _ in vts) + '];\n\n')
    # ISD numbering: names not in gen_x86_tti.jai get numbers after its range
    tti_isds = [m.group(1) for m in re.finditer(r'^ISD_(\w+) : u32 : (\d+);', open(TTI_GEN).read(), re.M)]
    extra = sorted(n for n in isd_names if n not in tti_isds)
    for k, n in enumerate(extra):
        o.write(f'ISD_{n} : u32 : {len(tti_isds) + 1 + k};\n')
    o.write(f'ISD_COUNT :: {len(tti_isds) + 1 + len(extra)};\n\n')
    tgt = [n for n in tti_isds + extra if n.startswith('X86_')]
    o.write('// target-specific (X86ISD) opcodes: getOperationAction answers Custom\n')
    o.write('isd_is_target :: (isd: u32) -> bool {\n    return ' + ' || '.join(f'isd == ISD_{n}' for n in tgt) + ';\n}\n\n')
    o.write(f'set_f16_action :: (st: *X86_Lowering, VT: u32, Action: u8) {{{lambda_bodies["setF16Action"]}}}\n\n')
    o.write(f'set_group :: (st: *X86_Lowering, VT: u32) {{{lambda_bodies["setGroup"]}}}\n\n')
    o.write(f'set_fp_min_max_action :: (st: *X86_Lowering, VT: u32) {{{lambda_bodies["SetFPMinMaxAction"]}}}\n\n')
    ib, xb = body.split('@@X86@@')
    o.write('// TargetLoweringBase::initActions\n')
    o.write('tlb_init_actions :: (st: *X86_Lowering) {\n')
    o.write(ib)
    o.write('\n}\n\n')
    o.write('x86_lowering_actions :: (st: *X86_Lowering) {\n')
    o.write(xb)
    o.write('\n}\n')
print('wrote', OUT)
