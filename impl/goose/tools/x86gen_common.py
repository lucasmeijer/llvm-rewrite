"""Shared by tools/gen_x86target.py and tools/gen_x86lower.py: LLVM 23.1.5's value types (MVT numbering =
MVT::SimpleValueType, from `llvm-min-tblgen -gen-vt`), ISD opcode names (ISDOpcodes.h, then the X86ISD names the
tables use) and the TableGen records of X86.td.

Needs llvm-min-tblgen (tools/build_min_tblgen.sh; default /persistent/llvm-rewrite/min-tblgen/min-tblgen).
"""
import os, re, subprocess, tempfile

LLVM = '/opt/llvm-project-23.1.5/llvm'
TBLGEN = os.environ.get('MIN_TBLGEN', '/persistent/llvm-rewrite/min-tblgen/min-tblgen')
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'src')


def tblgen(args):
    with tempfile.NamedTemporaryFile('r', suffix='.txt') as f:
        subprocess.run([TBLGEN] + args + ['-o', f.name], check=True, cwd=LLVM)
        return open(f.name).read()


_vts = None


def value_types():
    """[(name, size_bits, is_int, is_fp, is_vec, is_scalable, nelem, elt_name)], index + 1 = SimpleValueType"""
    global _vts
    if _vts is None:
        txt = tblgen(['-gen-vt', '-I', 'include', 'include/llvm/CodeGen/ValueTypes.td'])
        body = txt[txt.index('#ifdef GET_VT_ATTR'):]
        body = body[:body.index('#endif')]
        _vts = []
        for m in re.finditer(r'GET_VT_ATTR\((\w+), (\d+), (\d+), (\d+), (\d+), (\d+), (\d+), (\d+), (\d+), (\d+), (\w+)\)', body):
            name, sz, any_, isint, isfp, isvec, sc, tup, nf, nelem, elt = m.groups()
            _vts.append((name, int(sz), int(isint) != 0, int(isfp) != 0, int(isvec) != 0, int(sc) != 0, int(nelem),
                         None if elt == 'INVALID_SIMPLE_VALUE_TYPE' else elt))
    return _vts


def mvt_index():
    return {v[0]: k + 1 for k, v in enumerate(value_types())}


def isd_names():
    """ISD::NodeType names up to BUILTIN_OP_END (VP opcodes included), in enum order (value = index)."""
    h = open(LLVM + '/include/llvm/CodeGen/ISDOpcodes.h').read()
    s = h.index('enum NodeType {')
    e = h.index('BUILTIN_OP_END', s)
    body = h[s + len('enum NodeType {'):e]
    body = re.sub(r'//[^\n]*', '', body)
    body = re.sub(r'/\*.*?\*/', '', body, flags=re.S)
    names = []
    vp = open(LLVM + '/include/llvm/IR/VPIntrinsics.def').read()
    vp = re.sub(r'//[^\n]*', '', vp)
    for line in body.split('\n'):
        line = line.strip()
        if line.startswith('#include'):
            for m in re.finditer(r'^\s*BEGIN_REGISTER_VP(?:_SDNODE)?\(([^)]*)\)', vp, re.M):
                a = [x.strip() for x in m.group(1).split(',')]
                nm = a[3] if len(a) == 5 else a[0]
                if m.group(0).strip().startswith('BEGIN_REGISTER_VP_SDNODE'):
                    nm = a[0]
                if nm not in names:
                    names.append(nm)
            continue
        if line.startswith('#'):
            continue
        for tok in line.split(','):
            tok = tok.strip()
            if not tok:
                continue
            m = re.match(r'([A-Za-z_][A-Za-z_0-9]*)\s*(=.*)?$', tok)
            assert m, tok
            names.append(m.group(1))
    return names


_records = None


def x86_records():
    """{def name: (class list string, body text)} for X86.td"""
    global _records
    if _records is None:
        txt = tblgen(['--print-records', '-I', 'include', '-I', 'lib/Target/X86', 'lib/Target/X86/X86.td'])
        _records = {}
        for m in re.finditer(r'^def (\w+) \{\t// ([^\n]*)\n(.*?)^\}', txt, re.M | re.S):
            _records[m.group(1)] = (m.group(2), m.group(3))
    return _records


def rec_field(body, name):
    m = re.search(r'^  \S[^\n]*? ' + re.escape(name) + r' = (.*?);$', body, re.M)
    if not m:
        return None
    v = m.group(1)
    if v.startswith('"'):
        return v[1:-1]
    if v.startswith('['):
        return [x.strip() for x in v[1:-1].split(',') if x.strip()]
    return v
