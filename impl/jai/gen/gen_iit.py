#!/usr/bin/env python3
"""Generates src/gen_iit.jai: the type signature of every intrinsic, as IIT descriptors.

LLVM's IntrinsicEmitter (llvm/utils/TableGen/Basic/IntrinsicEmitter.cpp) computes, from the `def int_*` records of
llvm/include/llvm/IR/Intrinsics*.td, an encoded type table (IIT_Table) that Intrinsic::getIntrinsicInfoTableEntries
decodes into IITDescriptors (llvm/lib/IR/Intrinsics.cpp: DecodeIITType). We have no TableGen binary, so this script
contains a small TableGen evaluator (classes with template arguments, defs, `let ... in`, `foreach`, `defvar`,
field access, the few bang operators the intrinsic definitions use; fields are evaluated lazily so the IIT
bookkeeping classes that need !filter etc. are never evaluated) and emits the *decoded* descriptor list directly:
the same sequence DecodeIITType produces for the record's TypeInfo (TypeInfoGen in Intrinsics.td).

Only Intrinsics.td and IntrinsicsX86.td are read (the corpus is x86-only; other targets' intrinsic names are
therefore unknown to the implementation, which reports them like LLVM reports unknown intrinsics).

Run: python3 impl/jai/gen/gen_iit.py > impl/jai/src/gen_iit.jai
"""
import re, sys

TD = '/opt/llvm-project-23.1.5/llvm/include/llvm/IR/'

# ------------------------------------------------------------------ lexer
TOK = re.compile(r'''
   (?P<ws>\s+|//[^\n]*|/\*.*?\*/)
 | (?P<str>"(?:[^"\\]|\\.)*")
 | (?P<code>\[\{.*?\}\])
 | (?P<num>0x[0-9a-fA-F]+|0b[01]+|-?[0-9]+)
 | (?P<bang>![a-z]+)
 | (?P<id>[A-Za-z_][A-Za-z0-9_]*)
 | (?P<dots>\.\.\.)
 | (?P<p>[<>\[\]{}(),;:=.#?+-])
''', re.S | re.X)

def lex(src):
    out = []
    i = 0
    while i < len(src):
        m = TOK.match(src, i)
        if not m:
            raise SyntaxError('bad char at %d: %r' % (i, src[i:i + 20]))
        i = m.end()
        k = m.lastgroup
        if k == 'ws':
            continue
        out.append((k, m.group(k)))
    out.append(('eof', ''))
    return out

# ------------------------------------------------------------------ values
class Rec:
    """A record: superclass chain (list of (class name, {targ: value})) and lazy fields."""
    def __init__(self, name):
        self.name = name
        self.chain = []
        self.fields = {}    # name -> (expr, env)
        self.cache = {}
    def isa(self, cls):
        return any(c == cls for c, _ in self.chain)
    def args(self, cls):
        for c, a in self.chain:
            if c == cls:
                return a
        return None
    def get(self, f):
        if f in self.cache:
            return self.cache[f]
        if f not in self.fields:
            raise KeyError('%s has no field %s' % (self.name, f))
        expr, env = self.fields[f]
        v = ev(expr, env, self)
        self.cache[f] = v
        return v
    def __repr__(self):
        return 'Rec(%s)' % self.name

class Sym:
    """An identifier we don't model (value types like i32, v4f32, iAny ...)."""
    def __init__(self, name): self.name = name
    def __repr__(self): return 'Sym(%s)' % self.name
    def __eq__(self, o): return isinstance(o, Sym) and o.name == self.name
    def __hash__(self): return hash(self.name)

UNSET = object()

classes = {}     # name -> (targs [(name, default expr)], parents [(name, [arg exprs])], body)
defs = {}        # name -> Rec
gvars = {}       # defvar name -> value
order = []       # def names in definition order

# ------------------------------------------------------------------ parser
class Parser:
    def __init__(self, toks):
        self.t = toks
        self.i = 0
    def peek(self, k=0): return self.t[self.i + k]
    def next(self):
        t = self.t[self.i]; self.i += 1; return t
    def accept(self, v):
        if self.t[self.i][1] == v and self.t[self.i][0] != 'str':
            self.i += 1; return True
        return False
    def expect(self, v):
        t = self.next()
        if t[1] != v:
            raise SyntaxError('expected %r got %r near %r' % (v, t, self.t[self.i:self.i + 8]))
        return t

    def skip_type(self):
        # list<...>, bits<N>, Name
        self.next()
        if self.accept('<'):
            depth = 1
            while depth:
                t = self.next()
                if t[1] == '<': depth += 1
                elif t[1] == '>': depth -= 1

    # value expressions -> AST tuples
    def value(self):
        v = self.simple()
        while True:
            if self.peek()[1] == '.' and self.peek(1)[0] == 'id':
                self.next(); f = self.next()[1]
                v = ('field', v, f)
            elif self.peek()[1] == '[' and v[0] == 'id':
                self.next(); ix = self.value(); self.expect(']')
                v = ('index', v, ix)
            elif self.peek()[1] == '#':
                self.next()
                r = self.simple()
                v = ('paste', v, r)
            elif self.peek()[1] == '...':
                self.next()
                r = self.simple()
                v = ('range', v, r)
            else:
                break
        return v

    def simple(self):
        k, s = self.next()
        if k == 'num':
            return ('lit', int(s, 0))
        if k == 'str':
            v = s[1:-1]
            while self.peek()[0] == 'str':   # adjacent string concatenation
                v += self.next()[1][1:-1]
            return ('lit', v)
        if k == 'code':
            return ('lit', s)
        if s == '?':
            return ('lit', None)
        if s == '[':
            items = []
            if not self.accept(']'):
                while True:
                    items.append(self.value())
                    if self.accept(']'): break
                    self.expect(',')
                    if self.accept(']'): break
            if self.peek()[1] == '<':   # []<type>
                self.skip_type_args()
            return ('list', items)
        if s == '(':
            # dag: skip
            depth = 1
            while depth:
                t = self.next()
                if t[1] == '(': depth += 1
                elif t[1] == ')': depth -= 1
            return ('lit', None)
        if s == '{':
            items = []
            while not self.accept('}'):
                items.append(self.value()); self.accept(',')
            return ('lit', items)
        if k == 'bang':
            op = s[1:]
            if self.peek()[1] == '<':
                self.skip_type_args()
            self.expect('(')
            args = []
            if not self.accept(')'):
                while True:
                    args.append(self.value())
                    if self.accept(')'): break
                    if self.accept(':'):
                        args.append(self.value())
                        if self.accept(')'): break
                    self.expect(',')
            return ('bang', op, args)
        if k == 'id':
            if s in ('true', 'false'):
                return ('lit', 1 if s == 'true' else 0)
            if self.peek()[1] == '<':
                self.next()
                args = []
                if not self.accept('>'):
                    while True:
                        args.append(self.value())
                        if self.accept('>'): break
                        self.expect(',')
                return ('inst', s, args)
            return ('id', s)
        raise SyntaxError('unexpected %r' % ((k, s),))

    def skip_type_args(self):
        self.expect('<')
        depth = 1
        while depth:
            t = self.next()
            if t[1] == '<': depth += 1
            elif t[1] == '>': depth -= 1

    def parents(self):
        ps = []
        if self.accept(':'):
            while True:
                n = self.next()[1]
                args = []
                if self.accept('<'):
                    if not self.accept('>'):
                        while True:
                            args.append(self.value())
                            if self.accept('>'): break
                            self.expect(',')
                ps.append((n, args))
                if not self.accept(','): break
        return ps

    def body(self):
        items = []
        if self.accept(';'):
            return items
        self.expect('{')
        while not self.accept('}'):
            if self.accept('let'):
                n = self.next()[1]
                self.expect('=')
                items.append(('let', n, self.value()))
                self.expect(';')
            elif self.accept('assert'):
                self.value(); self.expect(','); self.value(); self.expect(';')
            elif self.accept('defvar'):
                n = self.next()[1]; self.expect('='); items.append(('defvar', n, self.value())); self.expect(';')
            else:
                self.skip_type()
                n = self.next()[1]
                if self.accept('='):
                    items.append(('field', n, self.value()))
                else:
                    items.append(('field', n, ('lit', UNSET)))
                self.expect(';')
        return items

    def stmts(self, lets, env, until=None):
        while True:
            t = self.peek()
            if t[0] == 'eof' or (until and t[1] == until):
                return
            self.stmt(lets, env)

    def block_or_stmt(self, lets, env):
        if self.accept('{'):
            self.stmts(lets, env, '}')
            self.expect('}')
        else:
            self.stmt(lets, env)

    def stmt(self, lets, env):
        k, s = self.next()
        if s == '#':   # preprocessor: TEST_INTRINSICS_SUPPRESS_DEFS is not defined, keep everything
            d = self.next()[1]
            if d in ('ifndef', 'ifdef', 'define'):
                self.next()
            return
        if s == 'include':
            f = self.next()[1][1:-1]
            if f == 'llvm/IR/IntrinsicsX86.td':
                p = Parser(lex(open(TD + 'IntrinsicsX86.td').read()))
                p.stmts(lets, env)
            return
        if s == 'class':
            name = self.next()[1]
            targs = []
            if self.accept('<'):
                while True:
                    self.skip_type()
                    an = self.next()[1]
                    dflt = None
                    if self.accept('='):
                        dflt = self.value()
                    targs.append((an, dflt))
                    if self.accept('>'): break
                    self.expect(',')
            ps = self.parents()
            b = self.body()
            classes[name] = (targs, ps, b)
            return
        if s == 'def':
            nexpr = None
            if self.peek()[1] != ':':
                nexpr = self.value()
            ps = self.parents()
            b = self.body()
            name = to_str(ev(nexpr, env, None)) if nexpr else '__anon%d' % len(defs)
            r = Rec(name)
            build(r, ps, b, env, lets)
            defs[name] = r
            order.append(name)
            return
        if s == 'defvar':
            n = self.next()[1]; self.expect('=')
            e = self.value(); self.expect(';')
            if env is gvars:
                gvars[n] = ('lazy', e)
            else:
                env[n] = ev(e, env, None)
            return
        if s == 'let':
            new = list(lets)
            while True:
                n = self.next()[1]
                self.expect('=')
                new.append((n, self.value(), env))
                if not self.accept(','): break
            self.expect('in')
            self.block_or_stmt(new, env)
            return
        if s == 'foreach':
            var = self.next()[1]
            self.expect('=')
            rng = ev(self.value(), env, None)
            self.expect('in')
            start = self.i
            for v in rng:
                self.i = start
                e2 = dict(env) if env is not gvars else {}
                e2[var] = v
                e2['__parent'] = env
                self.block_or_stmt(lets, e2)
            return
        if s == 'defset':
            self.skip_type(); self.next(); self.expect('=')
            self.expect('{')
            self.stmts(lets, env, '}')
            self.expect('}')
            return
        if s in ('multiclass', 'defm'):
            raise SyntaxError('multiclass/defm not supported by this evaluator')
        raise SyntaxError('unexpected statement %r near %r' % (s, self.t[self.i:self.i + 10]))

# ------------------------------------------------------------------ evaluation
def lookup(name, env, rec):
    e = env
    while e is not None and e is not gvars:
        if name in e:
            return e[name]
        e = e.get('__parent')
    if rec is not None and name in rec.fields:
        return rec.get(name)
    if name in defs:
        return defs[name]
    if name in gvars:
        v = gvars[name]
        if isinstance(v, tuple) and v[0] == 'lazy':
            v = ev(v[1], gvars, None)
            gvars[name] = v
        return v
    return Sym(name)

def to_str(v):
    if isinstance(v, str): return v
    if isinstance(v, int): return str(v)
    if isinstance(v, Sym): return v.name
    if isinstance(v, Rec): return v.name
    raise TypeError(repr(v))

def ev(e, env, rec):
    k = e[0]
    if k == 'lit':
        return e[1]
    if k == 'id':
        return lookup(e[1], env, rec)
    if k == 'list':
        return [ev(x, env, rec) for x in e[1]]
    if k == 'paste':
        l = ev(e[1], env, rec); r = ev(e[2], env, rec)
        if isinstance(l, list) or isinstance(r, list):
            return (l or []) + (r or [])
        return to_str(ev(e[1], env, rec)) + to_str(ev(e[2], env, rec))
    if k == 'range':
        return list(range(ev(e[1], env, rec), ev(e[2], env, rec) + 1))
    if k == 'index':
        return ev(e[1], env, rec)[ev(e[2], env, rec)]
    if k == 'field':
        b = ev(e[1], env, rec)
        if isinstance(b, Rec):
            return b.get(e[2])
        raise TypeError('field %s of %r' % (e[2], b))
    if k == 'inst':
        r = Rec('anon:' + e[1])
        build(r, [(e[1], e[2])], [], env, [], rec)
        return r
    if k == 'bang':
        op, a = e[1], e[2]
        if op == 'listsplat':
            v = ev(a[0], env, rec); n = ev(a[1], env, rec)
            return [v] * n
        if op == 'listconcat':
            out = []
            for x in a: out += ev(x, env, rec)
            return out
        if op == 'if':
            return ev(a[1], env, rec) if ev(a[0], env, rec) else ev(a[2], env, rec)
        if op == 'eq':
            return int(ev(a[0], env, rec) == ev(a[1], env, rec))
        if op == 'not':
            return int(not ev(a[0], env, rec))
        if op == 'or':
            v = 0
            for x in a: v |= ev(x, env, rec)
            return v
        if op == 'and':
            v = -1
            for x in a: v &= ev(x, env, rec)
            return v
        if op == 'shl':
            return ev(a[0], env, rec) << ev(a[1], env, rec)
        if op == 'add':
            return sum(ev(x, env, rec) for x in a)
        if op == 'strconcat':
            return ''.join(ev(x, env, rec) for x in a)
        raise NotImplementedError('!' + op)
    raise TypeError(k)

def build(r, parents, body, env, lets, outer_rec=None):
    """Fill record r from superclasses `parents` (arg exprs evaluated in env), then body, then lets."""
    for (cname, argexprs) in parents:
        args = [ev(x, env, outer_rec) for x in argexprs]
        inherit(r, cname, args)
    # outer `let`s are applied before the body (TGParser::ParseObjectBody)
    for (n, e, lenv) in lets:
        r.fields[n] = (e, lenv); r.cache.pop(n, None)
    benv = {'__parent': env} if env is not gvars else {}
    for item in body:
        if item[0] == 'defvar':
            benv[item[1]] = ev(item[2], benv, r)
        else:
            if item[2] == ('lit', UNSET) and item[1] in r.fields:
                continue
            r.fields[item[1]] = (item[2], benv); r.cache.pop(item[1], None)

def inherit(r, cname, args):
    if cname not in classes:
        r.chain.append((cname, {}))
        return
    targs, ps, body = classes[cname]
    cenv = {}
    for i, (an, dflt) in enumerate(targs):
        if i < len(args):
            cenv[an] = args[i]
        elif dflt is not None:
            cenv[an] = ev(dflt, cenv, None)
        else:
            cenv[an] = None
    r.chain.append((cname, dict(cenv)))
    for (pn, pargs) in ps:
        inherit(r, pn, [ev(x, cenv, None) for x in pargs])
    for item in body:
        if item[0] == 'defvar':
            cenv[item[1]] = ev(item[2], cenv, r)
        elif item[0] in ('field', 'let'):
            if item[2] == ('lit', UNSET) and item[1] in r.fields:
                continue
            r.fields[item[1]] = (item[2], cenv); r.cache.pop(item[1], None)

# ------------------------------------------------------------------ IIT descriptors
# IITDescriptor::IITDescriptorKind order from llvm/include/llvm/IR/Intrinsics.h
KINDS = ['Void', 'VarArg', 'MMX', 'Token', 'Metadata', 'Half', 'BFloat', 'Float', 'Double', 'Quad', 'Integer',
         'Vector', 'Pointer', 'Struct', 'Overloaded', 'Match', 'Extend', 'Trunc', 'SameVecWidth', 'VecOfAnyPtrsToElt',
         'VecElement', 'Subdivide2', 'Subdivide4', 'VecOfBitcastsToInt', 'AMX', 'PPCQuad', 'AArch64Svcount',
         'WasmExternref', 'WasmFuncref', 'OneNthEltsVec']

SCALAR_VT = {
    'isVoid': ('VarArg', 0, 0), 'x86mmx': ('MMX', 0, 0), 'token': ('Token', 0, 0), 'MetadataVT': ('Metadata', 0, 0),
    'f16': ('Half', 0, 0), 'bf16': ('BFloat', 0, 0), 'f32': ('Float', 0, 0), 'f64': ('Double', 0, 0),
    'f128': ('Quad', 0, 0), 'ppcf128': ('PPCQuad', 0, 0), 'x86amx': ('AMX', 0, 0), 'iPTR': ('Pointer', 0, 0),
    'aarch64svcount': ('AArch64Svcount', 0, 0), 'externref': ('WasmExternref', 0, 0),
    'funcref': ('WasmFuncref', 0, 0),
}

def vt_descs(vt):
    m = re.fullmatch(r'(nx)?v(\d+)(.*)', vt)
    if m:
        return [('Vector', int(m.group(2)), 1 if m.group(1) else 0)] + vt_descs(m.group(3))
    m = re.fullmatch(r'i(\d+)', vt)
    if m:
        return [('Integer', int(m.group(1)), 0)]
    if vt in SCALAR_VT:
        return [SCALAR_VT[vt]]
    raise ValueError('value type ' + vt)

def type_descs(t, oidx):
    """Descriptors for one LLVMType record (DecodeIITType of its patched Sig)."""
    def idx_of(cls):
        return t.args(cls)['oidx']
    if t.isa('LLVMAnyType'):
        a = t.args('LLVMAnyType')
        packed = (((a['VecKind'] << 4) | a['ElemKind']) << 8) | oidx
        return [('Overloaded', packed, 0)]
    if t.isa('LLVMQualPointerType'):
        return [('Pointer', t.args('LLVMQualPointerType')['addrspace'], 0)]
    if t.isa('LLVMVectorOfAnyPointersToElt'):
        return [('VecOfAnyPtrsToElt', oidx, idx_of('LLVMVectorOfAnyPointersToElt'))]
    if t.isa('LLVMScalarOrSameVectorWidth'):
        a = t.args('LLVMScalarOrSameVectorWidth')
        return [('SameVecWidth', a['oidx'], 0)] + type_descs(a['elty'], None)
    if t.isa('LLVMOneNthElementsVectorType'):
        a = t.args('LLVMOneNthElementsVectorType')
        return [('OneNthEltsVec', a['oidx'], a['n'])]
    simple = {'LLVMMatchType': 'Match', 'LLVMExtendedType': 'Extend', 'LLVMTruncatedType': 'Trunc',
              'LLVMVectorElementType': 'VecElement', 'LLVMSubdivide2VectorType': 'Subdivide2',
              'LLVMSubdivide4VectorType': 'Subdivide4', 'LLVMVectorOfBitcastsToInt': 'VecOfBitcastsToInt'}
    for c, kd in simple.items():
        if t.isa(c):
            return [(kd, idx_of(c), 0)]
    if t.isa('LLVMType'):
        vt = t.args('LLVMType')['vt']
        return vt_descs(vt.name)
    raise ValueError('type record %r chain %r' % (t, t.chain))

def is_overload_type(t):
    return t.isa('LLVMAnyType') or t.isa('LLVMPartiallyDependentType')

def signature(r):
    rets = r.get('RetTypes')
    params = r.get('ParamTypes')
    alltys = rets + params
    oidxs = []
    n = 0
    for t in alltys:
        if is_overload_type(t):
            oidxs.append(n); n += 1
        else:
            oidxs.append(None)
    out = []
    if len(rets) == 0:
        out.append(('Void', 0, 0))
    elif len(rets) > 1:
        out.append(('Struct', len(rets), 0))
    for t, o in zip(alltys, oidxs):
        out += type_descs(t, o)
    return out, n > 0

def main():
    p = Parser(lex(open(TD + 'Intrinsics.td').read()))
    p.stmts([], gvars)
    rows = []
    for name in order:
        if not name.startswith('int_'):
            continue
        r = defs[name]
        if not r.isa('Intrinsic'):
            continue
        llname = r.get('LLVMName')
        if not llname:
            llname = 'llvm.' + name[4:].replace('_', '.')
        descs, ovl = signature(r)
        rows.append((r.get('TargetPrefix'), llname, descs, ovl))
    # IntrinsicNameTable order: the generic intrinsics, then each target's, each sorted by name
    rows.sort(key=lambda x: (x[0] != '', x[0], x[1].encode()))
    x86_start = next(i for i, r in enumerate(rows) if r[0] == 'x86')
    rows = [r[1:] for r in rows]
    print('// GENERATED by impl/jai/gen/gen_iit.py from Intrinsics.td + IntrinsicsX86.td. Do not edit.')
    print('// Each intrinsic: name, overloaded flag, and the IITDescriptors DecodeIITType would produce')
    print('// (kind, a, b) as a slice of IIT_DESCS. Sorted by name (as IntrinsicNameTable).')
    print('IIT_Kind :: enum u8 {')
    for k in KINDS:
        print('    %s;' % k)
    print('}')
    print('IIT_Desc :: struct { kind: IIT_Kind; a: u32; b: u32; }')
    print('Intrinsic_Info :: struct { name: string; overloaded: bool; first: u32; count: u32; }')
    print('INTRINSIC_X86_START :: %d;   // first index of the x86 target subtable' % x86_start)
    print('IIT_DESCS :: IIT_Desc.[')
    flat = 0
    infos = []
    for (n, descs, ovl) in rows:
        infos.append((n, ovl, flat, len(descs)))
        print('    ' + ', '.join('.{.%s, %d, %d}' % d for d in descs) + ',  // ' + n)
        flat += len(descs)
    print('];')
    print('INTRINSIC_INFOS :: Intrinsic_Info.[')
    for (n, ovl, f, c) in infos:
        print('    .{"%s", %s, %d, %d},' % (n, 'true' if ovl else 'false', f, c))
    print('];')

main()
