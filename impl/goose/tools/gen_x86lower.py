#!/usr/bin/env python3
"""Translate LLVM 23.1.5's TargetLoweringBase::initActions (lib/CodeGen/TargetLoweringBase.cpp) and the
X86TargetLowering constructor up to computeRegisterProperties (lib/Target/X86/X86ISelLowering.cpp) into Goose:
src/gen_x86lower.goose with `xl_init_actions()` and `xl_x86_ctor()`.

A small C++ statement/expression parser (the subset these two functions use: blocks, if/else, range-for, local
declarations, lambdas, calls, ternaries) re-emits the code with
  Subtarget.hasX()          -> xst_hasX() (generated getters, gen_x86target.goose) or the hand-written x86_* query
  MVT::v4i32 / ISD::ADD     -> MVT_v4i32 / XISD_ADD (gen_x86target.goose)
  setOperationAction & co.  -> xl_soa / xl_slea / xl_stsa / xl_scca / xl_sopt / xl_add_reg_class (x86_lower.goose),
                               list arguments ({a, b}) expanded into loops
Statements that cannot affect a legality query (DAG combines, libcall names, FP immediates, scheduling preference,
atomic sizes, indexed/atomic-load modes, promoted-to types) are dropped. Anything not understood stops the script.

Usage: python3 impl/goose/tools/gen_x86lower.py
"""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import x86gen_common as C

LLVM = C.LLVM
mvt = C.mvt_index()
isds = set(C.isd_names())

DROP = {'setAtomicLoadExtAction', 'setIndexedLoadAction', 'setIndexedStoreAction', 'setIndexedMaskedLoadAction',
        'setIndexedMaskedStoreAction', 'AddPromotedToType', 'setTargetDAGCombine', 'addLegalFPImmediate',
        'setSchedulingPreference', 'setMaxAtomicSizeInBitsSupported', 'setMaxDivRemBitWidthSupported',
        'setMaxLargeFPConvertBitWidthSupported', 'setStackPointerRegisterToSaveRestore', 'setBooleanContents',
        'setBooleanVectorContents', 'addBypassSlowDiv', 'memset', 'fill', 'assert', 'setLibcallImpl',
        'setMinFunctionAlignment', 'setPrefFunctionAlignment', 'setPrefLoopAlignment', 'setMinStackArgumentAlignment',
        'setMaxBytesForAlignment', 'setJumpIsExpensive', 'setPartialReduceMLAAction'}
# ArrayRef parameter positions of the action setters (0-based) -> loops
SETTERS = {'setOperationAction': ('xl_soa', [0, 1]), 'setLoadExtAction': ('xl_slea', [0, 1, 2]),
           'setTruncStoreAction': ('xl_stsa', []), 'setCondCodeAction': ('xl_scca', [0, 1]),
           'setOperationPromotedToType': ('xl_sopt', [0]), 'addRegisterClass': ('xl_add_reg_class', [])}
QUERIES = {'isTypeLegal': 'xl_is_type_legal', 'isOperationCustom': 'xl_is_op_custom',
           'isOperationExpand': 'xl_is_op_expand', 'isOperationExpandOrLibCall': 'xl_is_op_expand_or_libcall'}
SUBTARGET = {'is64Bit': 'x86_is64', 'useSoftFloat': 'x86_use_soft_float', 'hasSSE1': 'x86_sse1', 'hasSSE2': 'x86_sse2',
             'hasSSE3': 'x86_sse3', 'hasSSSE3': 'x86_ssse3', 'hasSSE41': 'x86_sse41', 'hasSSE42': 'x86_sse42',
             'hasAVX': 'x86_avx', 'hasAVX2': 'x86_avx2', 'hasAVX512': 'x86_avx512', 'hasInt256': 'x86_avx2',
             'hasAnyFMA': 'x86_any_fma', 'canUseCMOV': 'x86_can_use_cmov', 'canUseCMPXCHG16B': 'x86_cx16_64',
             'canUseCMPXCHG8B': 'xst_hasCX8', 'hasSSEPrefetch': 'x86_sse_prefetch', 'useAVX512Regs': 'x86_use_avx512_regs',
             'useBWIRegs': 'x86_use_bwi_regs', 'canExtendTo512DQ': 'x86_can_extend_512dq',
             'canExtendTo512BW': 'x86_can_extend_512bw', 'isTargetWin64': 'x86_is_win64',
             'isTargetWindowsMSVC': 'x86_is_windows_msvc', 'isTargetWindowsItanium': 'x86_is_windows_itanium',
             'isTargetCygMing': 'x86_is_cygming', 'isOSWindows': 'x86_is_windows', 'isTargetDarwin': 'x86_is_darwin',
             'isTargetELF': 'x86_is_elf', 'isTargetPS': 'x86_is_ps', 'isTargetMachO': 'x86_is_darwin',
             'isTargetWin32': 'x86_is_win32', 'isTargetLinux': 'x86_is_linux'}
gen_target = open(os.path.join(C.SRC, 'gen_x86target.goose')).read()
GETTERS = set(re.findall(r'^fn xst_(\w+)\(', gen_target, re.M))


def die(msg):
    print('gen_x86lower.py: ' + msg, file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------- source extraction + macro expansion
def body_of(text, head):
    s = text.index(head)
    s = text.index('{', s)
    d, j = 0, s
    while True:
        if text[j] == '{':
            d += 1
        elif text[j] == '}':
            d -= 1
            if d == 0:
                return text[s + 1:j]
        j += 1


def expand_defs(t):
    """#define M(...) stmt  #include "x.def"  ->  stmt for every M(...) in x.def"""
    def rep(m):
        mac, params, stmt, inc = m.group(1), m.group(2), m.group(3), m.group(4)
        stmt = stmt.replace('\\\n', ' ')
        d = open(LLVM + '/include/' + inc).read()
        d = re.sub(r'//[^\n]*', '', d)
        out = []
        pnames = [p.strip() for p in params.split(',')]
        names = set()
        for mm in re.finditer(r'^\s*(\w+)\(([^()]*(?:\([^()]*\)[^()]*)*)\)', d, re.M):
            call, args = mm.group(1), [a.strip() for a in mm.group(2).split(',')]
            if call == 'BEGIN_REGISTER_VP' and mac == 'BEGIN_REGISTER_VP_SDNODE':
                args = [args[3]]
            elif call == 'CMP_INSTRUCTION' and mac == 'DAG_INSTRUCTION':
                pass
            elif call != mac:
                continue
            s = stmt
            for k, p in enumerate(pnames):
                if p == '...':
                    continue
                if k < len(args):
                    s = re.sub(r'\b' + p + r'\b', args[k], s)
            s = s.replace('##', '')
            s = re.sub(r'ISD::\s+', 'ISD::', s)
            if s not in names:
                names.add(s)
                out.append(s)
        return '\n'.join(out) + '\n'
    return re.sub(r'#define (\w+)\(([^)]*)\)\s*((?:[^\n]|\\\n)*?)\n#include "([^"]+)"\n', rep, t)


tlb = open(LLVM + '/lib/CodeGen/TargetLoweringBase.cpp').read()
init_src = body_of(tlb, 'void TargetLoweringBase::initActions() {')
x86 = open(LLVM + '/lib/Target/X86/X86ISelLowering.cpp').read()
ctor = x86[x86.index('X86TargetLowering::X86TargetLowering(const X86TargetMachine &TM,'):]
ctor = ctor[ctor.index('{'):]
ctor = ctor[1:ctor.index('computeRegisterProperties(Subtarget.getRegisterInfo());')]


def clean(t):
    t = re.sub(r'//[^\n]*', '', t)
    t = re.sub(r'/\*.*?\*/', '', t, flags=re.S)
    t = re.sub(r'const X86RegisterInfo \*RegInfo = Subtarget.getRegisterInfo\(\);', '', t)
    t = re.sub(r'\bbool ignored;', '', t)
    # opt's TargetMachine is built at the default -O2 level; the exception model only guards EH_SJLJ actions
    t = t.replace('TM.getOptLevel() >= CodeGenOptLevel::Default', 'true')
    t = t.replace('TM.Options.ExceptionModel != ExceptionHandling::SjLj', 'true')
    t = re.sub(r'getRegClassFor\([^)]*\)\s*==\s*&X86::\w+', 'false', t)
    return expand_defs(t)


# ---------------------------------------------------------------- tokenizer
TOK = re.compile(r'\s+|(?P<flt>\d+\.\d*f?)|(?P<num>0x[0-9a-fA-F]+|\d+)[uUlL]*|(?P<id>[A-Za-z_]\w*)|(?P<str>"(?:\\.|[^"])*")|'
                 r'(?P<op>::|&&|\|\||==|!=|<=|>=|<<|>>|->|\+\+|--|\+=|-=|\|=|&=|[-+*/%<>=!&|^~?:;,.(){}\[\]#])')


def tokenize(s):
    out = []
    i = 0
    while i < len(s):
        m = TOK.match(s, i)
        if not m:
            die('cannot tokenize at: ' + s[i:i + 60])
        i = m.end()
        if m.group('flt'):
            out.append(('flt', m.group('flt')))
        elif m.group('num'):
            out.append(('num', m.group('num')))
        elif m.group('id'):
            out.append(('id', m.group('id')))
        elif m.group('str'):
            out.append(('str', m.group('str')))
        elif m.group('op'):
            out.append(('op', m.group('op')))
    out.append(('eof', ''))
    return out


# ---------------------------------------------------------------- parser -> AST
class P:
    def __init__(self, toks):
        self.t = toks
        self.i = 0

    def peek(self, k=0):
        return self.t[self.i + k]

    def at(self, v, k=0):
        return self.t[self.i + k][1] == v and self.t[self.i + k][0] != 'str'

    def next(self):
        x = self.t[self.i]
        self.i += 1
        return x

    def expect(self, v):
        x = self.next()
        if x[1] != v:
            die(f'expected {v!r}, got {x!r} near {self.ctx()}')
        return x

    def ctx(self):
        return ' '.join(x[1] for x in self.t[max(0, self.i - 15):self.i + 15])

    # statements
    def stmts(self, end):
        out = []
        while not self.at(end):
            if self.peek()[0] == 'eof':
                die('unexpected end')
            s = self.stmt()
            if s is not None:
                out.append(s)
        return out

    def stmt(self):
        if self.at(';'):
            self.next()
            return None
        if self.at('{'):
            self.next()
            b = self.stmts('}')
            self.expect('}')
            return ('block', b)
        if self.at('if'):
            self.next()
            self.expect('(')
            c = self.expr()
            self.expect(')')
            th = self.stmt()
            el = None
            if self.at('else'):
                self.next()
                el = self.stmt()
            return ('if', c, th, el)
        if self.at('for'):
            self.next()
            self.expect('(')
            # range-for: <type tokens> NAME : expr
            j = self.i
            depth = 0
            while not (self.t[j][1] == ':' and depth == 0):
                if self.t[j][1] in '([{':
                    depth += 1
                if self.t[j][1] in ')]}':
                    depth -= 1
                if self.t[j][1] == ';' or depth < 0:
                    die('only range-for loops are supported: ' + self.ctx())
                j += 1
            var = self.t[j - 1][1]
            self.i = j + 1
            rng = self.expr()
            self.expect(')')
            body = self.stmt()
            return ('for', var, rng, body)
        # lambda: auto NAME = [&](params) { body };
        if self.at('auto') and self.peek(1)[0] == 'id' and self.at('=', 2) and self.at('[', 3):
            self.next()
            name = self.next()[1]
            self.expect('=')
            self.expect('[')
            while not self.at(']'):
                self.next()
            self.expect(']')
            self.expect('(')
            params = []
            while not self.at(')'):
                toks = []
                while not self.at(',') and not self.at(')'):
                    toks.append(self.next()[1])
                params.append(toks[-1])
                if self.at(','):
                    self.next()
            self.expect(')')
            self.expect('{')
            b = self.stmts('}')
            self.expect('}')
            self.expect(';')
            return ('lambda', name, params, b)
        # declaration
        k = 0
        while self.at('const', k):
            k += 1
        if self.peek(k)[0] == 'id' and self.peek(k)[1] in ('bool', 'LegalizeAction', 'MVT', 'unsigned', 'auto', 'int',
                                                           'APFloat') :
            if self.peek(k + 1)[0] == 'id' and (self.at('=', k + 2) or self.at(';', k + 2) or self.at('(', k + 2)):
                ty = self.peek(k)[1]
                self.i += k + 1
                name = self.next()[1]
                if ty == 'APFloat':
                    # only feeds addLegalFPImmediate (dropped)
                    while not self.at(';'):
                        self.next()
                    self.next()
                    return None
                if self.at(';'):
                    self.next()
                    return ('decl', ty, name, None)
                self.expect('=')
                e = self.expr()
                self.expect(';')
                return ('decl', ty, name, e)
        e = self.expr()
        self.expect(';')
        return ('expr', e)

    # expressions (precedence climbing)
    BIN = [['||'], ['&&'], ['|'], ['^'], ['&'], ['==', '!='], ['<', '>', '<=', '>='], ['<<', '>>'], ['+', '-'],
           ['*', '/', '%']]

    def expr(self):
        c = self.binary(0)
        if self.at('?'):
            self.next()
            a = self.expr()
            self.expect(':')
            b = self.expr()
            return ('?:', c, a, b)
        if self.at('='):
            self.next()
            r = self.expr()
            return ('assign', c, r)
        return c

    def binary(self, lvl):
        if lvl == len(self.BIN):
            return self.unary()
        l = self.binary(lvl + 1)
        while self.peek()[0] == 'op' and self.peek()[1] in self.BIN[lvl]:
            o = self.next()[1]
            r = self.binary(lvl + 1)
            l = ('bin', o, l, r)
        return l

    def unary(self):
        if self.at('!') or self.at('-') or self.at('~') or self.at('&') or self.at('+'):
            o = self.next()[1]
            return ('un', o, self.unary())
        return self.postfix(self.primary())

    def primary(self):
        x = self.next()
        if x[0] == 'num':
            return ('num', x[1])
        if x[0] == 'flt':
            return ('flt', x[1])
        if x[0] == 'str':
            return ('str', x[1])
        if x[1] == '(':
            e = self.expr()
            self.expect(')')
            return ('paren', e)
        if x[1] == '{':
            items = []
            while not self.at('}'):
                items.append(self.expr())
                if self.at(','):
                    self.next()
            self.expect('}')
            return ('list', items)
        if x[0] == 'id':
            name = x[1]
            while self.at('::'):
                self.next()
                name += '::' + self.next()[1]
            return ('name', name)
        die(f'unexpected token {x!r} near {self.ctx()}')

    def postfix(self, e):
        while True:
            if self.at('('):
                self.next()
                args = []
                while not self.at(')'):
                    args.append(self.expr())
                    if self.at(','):
                        self.next()
                self.expect(')')
                e = ('call', e, args)
            elif self.at('.') or self.at('->'):
                self.next()
                e = ('member', e, self.next()[1])
            elif self.at('['):
                self.next()
                ix = self.expr()
                self.expect(']')
                e = ('index', e, ix)
            else:
                return e


# ---------------------------------------------------------------- emitter
LA = {'Legal': 'LA_LEGAL', 'Promote': 'LA_PROMOTE', 'Expand': 'LA_EXPAND', 'LibCall': 'LA_LIBCALL',
      'Custom': 'LA_CUSTOM'}
RANGES = {'integer_valuetypes': ('INTEGER',), 'fp_valuetypes': ('FP',), 'vector_valuetypes': ('VECTOR',),
          'fixedlen_vector_valuetypes': ('FIXEDLEN_VECTOR',), 'integer_fixedlen_vector_valuetypes':
          ('INTEGER_FIXEDLEN_VECTOR',), 'fp_fixedlen_vector_valuetypes': ('FP_FIXEDLEN_VECTOR',),
          'all_valuetypes': (None,), 'scalable_vector_valuetypes': ('SCALABLE_VECTOR',),
          'integer_scalable_vector_valuetypes': ('INTEGER_SCALABLE_VECTOR',),
          'fp_scalable_vector_valuetypes': ('FP_SCALABLE_VECTOR',)}
LOADEXT = ['NON_EXTLOAD', 'EXTLOAD', 'SEXTLOAD', 'ZEXTLOAD']
_h = open(LLVM + '/include/llvm/CodeGen/ISDOpcodes.h').read()
_h = re.sub(r'//[^\n]*', '', _h[_h.index('enum CondCode {'):])
CONDCODES = re.findall(r'\b(SET\w+)', _h[:_h.index('};')])
lambdas = {}
uniq = [0]


def ex(e):
    k = e[0]
    if k == 'num':
        return str(int(e[1], 0))
    if k == 'paren':
        return '(' + ex(e[1]) + ')'
    if k == 'name':
        n = e[1]
        if n.startswith('MVT::'):
            v = n[5:]
            if v not in mvt:
                die('unknown MVT ' + n)
            return 'MVT_' + v
        if n.startswith('ISD::'):
            v = n[5:]
            if v in isds:
                return 'XISD_' + v
            if v in CONDCODES:
                return 'XCC_' + v
            if v in LOADEXT:
                return 'XLE_' + v
            die('unknown ISD ' + n)
        if n in LA:
            return LA[n]
        if n in ('true', 'false'):
            return n
        if '::' in n:
            die('unknown scoped name ' + n)
        return n
    if k == 'un':
        if e[1] == '!':
            return '!' + ex(e[2])
        if e[1] == '-':
            return '-' + ex(e[2])
        die('unsupported unary ' + e[1])
    if k == 'bin':
        return f'{ex(e[2])} {e[1]} {ex(e[3])}'
    if k == '?:':
        return f'(if {ex(e[1])} {{ {ex(e[2])} }} else {{ {ex(e[3])} }})'
    if k == 'list':
        return '[' + ', '.join(ex(x) for x in e[1]) + ']'
    if k == 'member':
        die('member access without call: ' + str(e))
    if k == 'call':
        f, args = e[1], e[2]
        if f[0] == 'member':
            obj, meth = f[1], f[2]
            if obj == ('name', 'Subtarget'):
                if meth in SUBTARGET:
                    return SUBTARGET[meth] + '()'
                if meth in GETTERS:
                    return f'xst_{meth}()'
                die('unknown subtarget query ' + meth)
            if obj == ('name', 'TM') and meth == 'getPointerSizeInBits':
                return 'x86_ptr_bits()'
            if obj == ('name', 'TM') and meth == 'getOptLevel':
                return 'XL_OPT_LEVEL'
            m = {'getVectorElementType': 'mvt_elt', 'getVectorNumElements': 'mvt_nelem',
                 'getScalarSizeInBits': 'mvt_scalar_bits', 'getSizeInBits': 'mvt_bits',
                 'getFixedSizeInBits': 'mvt_bits', 'isFloatingPoint': 'mvt_is_fp', 'isInteger': 'mvt_is_int',
                 'isVector': 'mvt_is_vec', 'is128BitVector': 'mvt_is128', 'is256BitVector': 'mvt_is256',
                 'is512BitVector': 'mvt_is512', 'isValid': 'mvt_valid', 'isScalableVector': 'mvt_is_scalable',
                 'changeVectorElementTypeToInteger': 'mvt_change_elt_to_int', 'getScalarType': 'mvt_scalar'}
            if meth in m and not args:
                return f'{m[meth]}({ex(obj)})'
            die('unknown method ' + meth)
        if f[0] == 'name':
            n = f[1]
            if n == 'MVT::getIntegerVT':
                return f'mvt_int({ex(args[0])})'
            if n == 'MVT::getVectorVT':
                return f'mvt_vec({ex(args[0])}, {ex(args[1])})'
            if n in QUERIES:
                return f'{QUERIES[n]}({", ".join(ex(a) for a in args)})'
            if n in lambdas:
                return f'{lambdas[n]}({", ".join(ex(a) for a in args)})'
            if n == 'getRegClassFor':
                return 'XL_REGCLASS_UNUSED'
        die('unknown call ' + str(f))
    if k == 'index':
        die('indexing not supported')
    die('cannot emit ' + str(e))


def is_drop(e):
    if e[0] != 'call':
        return False
    f = e[1]
    n = f[1] if f[0] == 'name' else (f[2] if f[0] == 'member' else None)
    if f[0] == 'member' and f[1][0] == 'name' and f[1][1] in ('TmpFlt', 'TmpFlt2', 'RegInfo'):
        return True
    if f[0] == 'name' and n in ('fill', 'llvm::fill'):
        return True
    return n in DROP


def emit_stmt(s, ind, out):
    p = '    ' * ind
    k = s[0]
    if k == 'block':
        for x in s[1]:
            emit_stmt(x, ind, out)
        return
    if k == 'if':
        out.append(f'{p}if {ex(s[1])} {{')
        emit_stmt(s[2], ind + 1, out)
        if s[3] is not None:
            if s[3][0] == 'if':
                out.append(f'{p}}} else {{')
                emit_stmt(s[3], ind + 1, out)
                out.append(f'{p}}}')
            else:
                out.append(f'{p}}} else {{')
                emit_stmt(s[3], ind + 1, out)
                out.append(f'{p}}}')
        else:
            out.append(f'{p}}}')
        return
    if k == 'for':
        var, rng, body = s[1], s[2], s[3]
        if rng[0] == 'list':
            r = ex(rng)
        elif rng[0] == 'call' and rng[1][0] == 'name' and rng[1][1].startswith('MVT::') and rng[1][1][5:] in RANGES:
            rn = RANGES[rng[1][1][5:]][0]
            if rn is None:
                r = 'MVT_FIRST_VALUE..MVT_LAST_VALUE + 1'
            else:
                r = f'MVT_FIRST_{rn}..MVT_LAST_{rn} + 1'
        elif rng[0] == 'call' and rng[1][0] == 'name' and rng[1][1] == 'enum_seq':
            die('enum_seq loops are not translated')
        else:
            die('unsupported for range ' + str(rng))
        out.append(f'{p}for {var} in {r} {{')
        emit_stmt(body, ind + 1, out)
        out.append(f'{p}}}')
        return
    if k == 'decl':
        if s[3] is None:
            die('declaration without initializer: ' + s[2])
        out.append(f'{p}let {s[2]} = {ex(s[3])};')
        return
    if k == 'lambda':
        hoist_lambda(s)
        return
    if k == 'expr':
        e = s[1]
        if is_drop(e):
            return
        if e in (('name', 'continue'), ('name', 'break')):
            out.append(f'{p}{e[1]};')
            return
        if e[0] == 'call' and e[1][0] == 'name' and e[1][1] in SETTERS:
            fn, listpos = SETTERS[e[1][1]]
            args = e[2]
            loops = []
            names = []
            for j, a in enumerate(args):
                if j in listpos and a[0] == 'list':
                    uniq[0] += 1
                    v = f'xl_l{uniq[0]}'
                    loops.append(f'for {v} in {ex(a)} {{')
                    names.append(v)
                elif a[0] == 'list':
                    die(f'list argument {j} of {e[1][1]}')
                elif e[1][1] == 'addRegisterClass' and j == 1:
                    break
                else:
                    names.append(ex(a))
            q = p
            for l in loops:
                out.append(q + l)
                q += '    '
            out.append(f'{q}{fn}({", ".join(names)});')
            for _ in loops:
                q = q[:-4]
                out.append(q + '}')
            return
        if e[0] == 'call' and e[1][0] == 'name' and e[1][1] in lambdas:
            out.append(f'{p}{ex(e)};')
            return
        die('unsupported statement: ' + str(e)[:300])
    die('unknown statement kind ' + k)


hoisted = []


def hoist_lambda(s):
    name, params, b = s[1], s[2], s[3]
    gname = 'xl_lambda_' + re.sub(r'(?<!^)(?=[A-Z])', '_', name).lower()
    lambdas[name] = gname
    fo = [f'fn {gname}({", ".join(p + ": i32" for p in params)}) {{']
    for x in b:
        emit_stmt(x, 1, fo)
    fo.append('}')
    hoisted.append('\n'.join(fo))


def translate(src, fname):
    toks = tokenize(clean(src))
    ps = P(toks)
    st = ps.stmts('eof') if False else None
    st = []
    while ps.peek()[0] != 'eof':
        s = ps.stmt()
        if s is not None:
            st.append(s)
    body = []
    for s in st:
        emit_stmt(s, 1, body)
    return [], f'fn {fname}() {{\n' + '\n'.join(body) + '\n}'


# initActions: drop the indexed-mode loops (C-style for) and the i2/i4 enum_seq loop (applied in xl_op_action)
def drop_c_for(t):
    while True:
        k = t.find('for (unsigned IM')
        if k < 0:
            return t
        j = t.index('(', k)
        d = 0
        while True:
            if t[j] == '(':
                d += 1
            elif t[j] == ')':
                d -= 1
                if d == 0:
                    break
            j += 1
        # body: a statement or block
        j += 1
        while t[j].isspace():
            j += 1
        if t[j] == '{':
            d = 0
            while True:
                if t[j] == '{':
                    d += 1
                elif t[j] == '}':
                    d -= 1
                    if d == 0:
                        break
                j += 1
            t = t[:k] + t[j + 1:]
        else:
            t = t[:k] + t[t.index(';', j) + 1:]


init_src = drop_c_for(re.sub(r'//[^\n]*', '', init_src))
k = init_src.index('for (ISD::NodeType NT : enum_seq(')
k2 = init_src.index('}', init_src.index('OpActions[', k))
init_src = init_src[:k] + init_src[k2 + 1:]
f1, init_fn = translate(init_src, 'xl_init_actions')
f2, ctor_fn = translate(ctor, 'xl_x86_ctor')
with open(os.path.join(C.SRC, 'gen_x86lower.goose'), 'w') as o:
    o.write('// Generated by tools/gen_x86lower.py from LLVM 23.1.5 lib/CodeGen/TargetLoweringBase.cpp (initActions) and\n')
    o.write('// lib/Target/X86/X86ISelLowering.cpp (the X86TargetLowering constructor up to computeRegisterProperties).\n')
    o.write('// Do not edit; rerun the script.\n')
    o.write('import gen_x86target;\nimport tti_x86;\nimport x86_lower;\n\n')
    for k, n in enumerate(LOADEXT):
        o.write(f'let XLE_{n}: i32 = {k};\n')
    for k, n in enumerate(CONDCODES):
        o.write(f'let XCC_{n}: i32 = {k};\n')
    o.write('\n')
    for f in hoisted:
        o.write(f + '\n\n')
    o.write(init_fn + '\n\n' + ctor_fn + '\n')
print('wrote src/gen_x86lower.goose', file=sys.stderr)
