#!/usr/bin/env python3
"""Generates src/gen_msan_switch.jai: the intrinsic dispatch switches of MemorySanitizerVisitor
(maybeHandleCrossPlatformIntrinsic and maybeHandleX86SIMDIntrinsic in
llvm/lib/Transforms/Instrumentation/MemorySanitizer.cpp) as `if name == { case "llvm...."; ... }` chains on the
intrinsic's base name. The handler calls are translated by the table HANDLERS below; an unknown statement stops the
script, so a new LLVM handler shows up as an error here rather than as a missing case.

Run: python3 impl/jai/gen/gen_msan_switch.py > impl/jai/src/gen_msan_switch.jai
"""
import re, sys, os
SRC = '/opt/llvm-project-23.1.5/llvm/lib/Transforms/Instrumentation/MemorySanitizer.cpp'
GEN_IIT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'gen_iit.jai')

names = {}
for m in re.finditer(r'\.\{"(llvm\.[^"]+)"', open(GEN_IIT).read()):
    n = m.group(1)
    names[n[5:].replace('.', '_')] = n

def iname(enum, optional=False):
    if enum not in names:
        if optional and (enum.startswith('aarch64_') or enum.startswith('arm_')): return None   # not in gen_iit.jai
        sys.exit('unknown intrinsic enum %s' % enum)
    return names[enum]

src = open(SRC).read()
src = re.sub(r'//[^\n]*', '', src)
src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)

HANDLERS = {
    'handleArithmeticWithOverflow': 'msan_handle_arithmetic_with_overflow',
    'handleAbsIntrinsic': 'msan_handle_abs',
    'handleIntrinsicByApplyingToShadow': 'msan_handle_intrinsic_by_applying_to_shadow',
    'handleIsFpClass': 'msan_handle_is_fpclass',
    'handleLifetimeStart': 'msan_handle_lifetime_start',
    'handleInvariantGroup': 'msan_handle_invariant_group',
    'handleBswap': 'msan_handle_bswap',
    'handleCountLeadingTrailingZeros': 'msan_handle_count_leading_trailing_zeros',
    'handleMaskedCompressStore': 'msan_handle_masked_compress_store',
    'handleMaskedExpandLoad': 'msan_handle_masked_expand_load',
    'handleMaskedGather': 'msan_handle_masked_gather',
    'handleMaskedScatter': 'msan_handle_masked_scatter',
    'handleMaskedStore': 'msan_handle_masked_store',
    'handleMaskedLoad': 'msan_handle_masked_load',
    'handleVectorReduceAndIntrinsic': 'msan_handle_vector_reduce_and',
    'handleVectorReduceOrIntrinsic': 'msan_handle_vector_reduce_or',
    'handleVectorReduceIntrinsic': 'msan_handle_vector_reduce',
    'handleVectorReduceWithStarterIntrinsic': 'msan_handle_vector_reduce_with_starter',
    'handleShadowOr': 'msan_handle_shadow_or',
    'handleFunnelShift': 'msan_handle_funnel_shift',
    'handleGenericBitManipulation': 'msan_handle_generic_bit_manipulation',
    'handleGenericVectorConvertIntrinsic': 'msan_handle_generic_vector_convert',
    'handleStmxcsr': 'msan_handle_stmxcsr',
    'handleLdmxcsr': 'msan_handle_ldmxcsr',
    'handleSSEVectorConvertIntrinsic': 'msan_handle_sse_vector_convert',
    'handleSSEVectorConvertIntrinsicByProp': 'msan_handle_sse_vector_convert_by_prop',
    'handleAVX512VectorConvertFPToInt': 'msan_handle_avx512_vector_convert_fp_to_int',
    'handleVectorShiftIntrinsic': 'msan_handle_vector_shift',
    'handleVectorPackIntrinsic': 'msan_handle_vector_pack',
    'handleBlendvIntrinsic': 'msan_handle_blendv',
    'handleDppIntrinsic': 'msan_handle_dpp',
    'handleVectorSadIntrinsic': 'msan_handle_vector_sad',
    'handleVectorDotProductIntrinsic': 'msan_handle_vector_dot_product',
    'handleVectorCompareScalarIntrinsic': 'msan_handle_vector_compare_scalar',
    'handleVectorComparePackedIntrinsic': 'msan_handle_vector_compare_packed',
    'handlePclmulIntrinsic': 'msan_handle_pclmul',
    'handleRoundPdPsIntrinsic': 'msan_handle_round_pd_ps',
    'handleUnarySdSsIntrinsic': 'msan_handle_unary_sd_ss',
    'handleBinarySdSsIntrinsic': 'msan_handle_binary_sd_ss',
    'handleVtestIntrinsic': 'msan_handle_vtest',
    'handlePairwiseShadowOrIntrinsic': 'msan_handle_pairwise_shadow_or',
    'handleAVXMaskedStore': 'msan_handle_avx_masked_store',
    'handleAVXMaskedLoad': 'msan_handle_avx_masked_load',
    'handleAVXVpermilvar': 'msan_handle_avx_vpermilvar',
    'handleAVXVpermi2var': 'msan_handle_avx_vpermi2var',
    'handleAVX512VectorDownConvert': 'msan_handle_avx512_vector_down_convert',
    'handleAVX512VectorGenericMaskedFP': 'msan_handle_avx512_vector_generic_masked_fp',
    'visitGenericScalarHalfwordInst': 'msan_visit_generic_scalar_halfword',
    'handleAVXGF2P8Affine': 'msan_handle_avx_gf2p8_affine',
}

def arg(a):
    a = a.strip()
    if a == 'I.getIntrinsicID()': return 'n'
    m = re.fullmatch(r'Intrinsic::(\w+)', a)
    if m: return '"%s"' % iname(m.group(1))
    if a in ('true', 'false'): return a
    if re.fullmatch(r'-?\d+', a): return a
    m = re.fullmatch(r'\{([\d, ]+)\}', a)
    if m: return 'u32.[%s]' % m.group(1)
    if a in ('kBothLanes', 'kEvenLanes', 'kOddLanes'): return '.' + {'kBothLanes': 'BOTH', 'kEvenLanes': 'EVEN', 'kOddLanes': 'ODD'}[a]
    sys.exit('unknown argument %r' % a)

def stmt(s):
    s = ' '.join(s.split())
    if s in ('setShadow(&I, getCleanShadow(&I)); setOrigin(&I, getCleanOrigin());',):
        return 'msan_set_clean(ms, i);'
    m = re.fullmatch(r'\[\[maybe_unused\]\] bool Success = maybeHandleSimpleNomemIntrinsic\(I, (\d+)\); assert\(Success\);', s)
    if m: return 'if !msan_maybe_handle_simple_nomem_intrinsic(ms, i, %s) fatal("internal: msan: simple nomem intrinsic");' % m.group(1)
    m = re.fullmatch(r'(\w+)\(I(.*)\);', s)
    if m and m.group(1) in HANDLERS:
        rest = m.group(2)
        args = []
        if rest.strip():
            rest = rest.strip()[1:]  # drop the leading comma
            depth = 0; cur = ''
            for ch in rest:
                if ch in '({': depth += 1
                if ch in ')}': depth -= 1
                if ch == ',' and depth == 0: args.append(cur); cur = ''
                else: cur += ch
            if cur.strip(): args.append(cur)
        return '%s(ms, i%s);' % (HANDLERS[m.group(1)], ''.join(', ' + arg(x) for x in args))
    sys.exit('unknown statement %r' % s)

def convert(fn):
    a = src.index('bool %s(IntrinsicInst &I) {' % fn)
    body = src[a:]
    sw = body.index('switch (I.getIntrinsicID()) {')
    i = sw + len('switch (I.getIntrinsicID()) {')
    depth = 1; j = i
    while depth:
        if body[j] == '{': depth += 1
        elif body[j] == '}': depth -= 1
        j += 1
    text = body[i:j-1]
    out = []
    out.append('%s :: (ms: *Msan, i: Value_Id) -> bool {' % {'maybeHandleCrossPlatformIntrinsic': 'msan_maybe_handle_cross_platform_intrinsic', 'maybeHandleX86SIMDIntrinsic': 'msan_maybe_handle_x86_simd_intrinsic'}[fn])
    out.append('    n := function_intrinsic_base(call_called_function(i));')
    out.append('    if n == {')
    # split into groups: case labels then statements up to break
    toks = re.split(r'(case Intrinsic::\w+:|default:|break;)', text)
    cases = []; stmts = ''
    for t in toks:
        t2 = t.strip()
        if not t2: continue
        m = re.fullmatch(r'case Intrinsic::(\w+):', t2)
        if m:
            if stmts.strip().strip('{}').strip():
                sys.exit('statements before break: %r' % stmts)
            stmts = ''
            cases.append(iname(m.group(1), True)); continue
        if t2 == 'default:':
            stmts = ''
            cases.append('DEFAULT'); continue
        if t2 == 'break;':
            body = stmts.strip()
            if body.startswith('{'): body = body[1:].strip()
            if cases == ['DEFAULT']:
                sys.exit('default with statements')
            # one Jai statement per C++ statement group
            parts = [p.strip() + ';' for p in body.split(';') if p.strip() and p.strip() != '}']
            code = stmt(' '.join(parts)) if len(parts) <= 2 else None
            if code is None: sys.exit('unexpected body %r' % body)
            cases = [c for c in cases if c is not None]
            for k, c in enumerate(cases):
                if k < len(cases) - 1: out.append('        case "%s"; #through;' % c)
                else: out.append('        case "%s"; %s' % (c, code))
            cases = []; stmts = ''; continue
        if cases == ['DEFAULT'] and t2.startswith('return false;'):
            cases = []; stmts = ''; continue
        stmts += ' ' + t2
    out.append('        case; return false;')
    out.append('    }')
    out.append('    return true;')
    out.append('}')
    return '\n'.join(out)

print('// GENERATED by impl/jai/gen/gen_msan_switch.py from MemorySanitizer.cpp: do not edit, rerun the script.')
print('// maybeHandleCrossPlatformIntrinsic / maybeHandleX86SIMDIntrinsic (the handlers are in msan_intrinsics.jai).')
print()
print(convert('maybeHandleCrossPlatformIntrinsic'))
print()
print(convert('maybeHandleX86SIMDIntrinsic'))
