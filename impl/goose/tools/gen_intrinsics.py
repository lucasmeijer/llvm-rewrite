#!/usr/bin/env python3
"""Generates src/gen_intrinsics.goose: LLVM's intrinsic tables, from TableGen's own output.

Run tools/build_min_tblgen.sh first (it builds llvm-min-tblgen from the LLVM sources and writes
IntrinsicImpl.inc). This script reads that file (the same tables Intrinsics.cpp includes) and writes:
  INTR_NAMES          intrinsic names indexed by Intrinsic::ID (0 = not_intrinsic), sorted as in LLVM
  INTR_OVERLOADED     Intrinsic::isOverloaded per ID
  INTR_IIT_OFF/INTR_IIT  the type-signature encoding per ID, already expanded to IIT bytes (the long
                      encoding table is copied whole; inline nibble encodings are appended, IIT_Done-padded)
  INTR_TARGET_*       TargetInfos (name, offset, count) for findTargetSubtable
  INTR_FN_ATTR/INTR_ARG_ATTR, INTR_ARGINFO_*, INTR_ARGPAIR_*  IntrinsicsToAttributesMap and friends
  INTR_FNSETS/INTR_ARGSETS  the attribute sets as space-separated items (see intrinsics.goose)
Usage: python3 impl/goose/tools/gen_intrinsics.py [path/to/IntrinsicImpl.inc]
"""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
INC = sys.argv[1] if len(sys.argv) > 1 else "/persistent/llvm-rewrite/min-tblgen/IntrinsicImpl.inc"
TD = "/opt/llvm-project-23.1.5/llvm/include/llvm/IR/Attributes.td"
src = open(INC).read()

def section(name):
    a = src.index("#ifdef " + name + "\n")
    b = src.index("#endif // " + name, a)
    return src[a:b]

# AttrKind enum name -> IR spelling
irname = {}
for m in re.finditer(r'^def\s+(\w+)\s*:\s*\w*Attr<"([^"]+)"', open(TD).read(), re.M):
    irname[m.group(1)] = m.group(2)

# Names, in ID order
s = section("GET_INTRINSIC_NAME_TABLE")
off = s[s.index("IntrinsicNameOffsetTable[] = {"):]
names = re.findall(r"^\s*\d+, // (\S+)$", off, re.M)
assert names[0] == "not_intrinsic"
N = len(names)

# Targets
s = section("GET_INTRINSIC_TARGET_DATA")
targets = re.findall(r'\{"(\w*)", (\d+), (\d+)\}', s)

# Overload bitset
s = section("GET_INTRINSIC_OVERLOAD_TABLE")
body = s[s.index("{") + 1:s.index("};")]
bytes_ = []
for chunk in body.split(","):
    chunk = chunk.strip()
    if not chunk: continue
    v = 0
    for b in re.findall(r"1<<(\d)", chunk): v |= 1 << int(b)
    bytes_.append(v)
overloaded = [1 if (bytes_[i // 8] >> (i % 8)) & 1 else 0 for i in range(N)]

# IIT tables
s = section("GET_INTRINSIC_GENERATOR_GLOBAL")
t = s[s.index("IIT_Table[] = {") + len("IIT_Table[] = {"):]
t = t[:t.index("};")]
fixed = []
for e in t.split(","):
    e = e.strip()
    if not e: continue
    m = re.match(r"\(1U<<15\) \| (\d+)$", e)
    if m: fixed.append(("long", int(m.group(1))))
    else: fixed.append(("inline", int(e, 0)))
lt = s[s.index("IIT_LongEncodingTable[] = {"):]
lt = lt[lt.index("{") + 1:lt.index("};")]
lt = re.sub(r"/\*.*?\*/", "", lt)
long_tab = [int(x) for x in lt.replace("\n", " ").split(",") if x.strip()]
iit = list(long_tab)
iit_off = [0]
for kind, v in fixed[:N - 1]:
    if kind == "long":
        iit_off.append(v)
    else:
        iit_off.append(len(iit))
        vals = []
        while True:
            vals.append(v & 0xF); v >>= 4
            if v == 0: break
        vals += [0] * (5 - len(vals) + 1)
        iit += vals
assert len(iit_off) == N

# Attributes
s = section("GET_INTRINSIC_ATTRIBUTES")
def parse_sets(fn_name):
    a = s.index(fn_name)
    b = s.index("\n}", a)
    body = s[a:b]
    sets = {}
    for m in re.finditer(r"case (\d+):[^\n]*\n\s*return AttributeSet::get\(C, \{(.*?)\}\);", body, re.S):
        items = []
        for line in m.group(2).split("\n"):
            line = line.strip()
            if not line or line.startswith("//"): continue
            mm = re.match(r"Attribute::get\(C, Attribute::(\w+)\),$", line)
            if mm: items.append(irname[mm.group(1)]); continue
            mm = re.match(r"Attribute::get\(C, Attribute::(\w+), (\d+)\),$", line)
            if mm: items.append(irname[mm.group(1)] + ":" + mm.group(2)); continue
            mm = re.match(r"Attribute::getWithCaptureInfo\(C, CaptureInfo::none\(\)\),$", line)
            if mm: items.append("captures:0"); continue
            mm = re.match(r"Attribute::getWithMemoryEffects\(C, MemoryEffects::createFromIntValue\((\d+)\)\),$", line)
            if mm: items.append("memory:" + mm.group(1)); continue
            mm = re.match(r"Attribute::get\(C, Attribute::Range, ConstantRange\(APInt\(BitWidth, (-?\d+),.*?APInt\(BitWidth, (-?\d+),.*\)\)\),$", line)
            if mm: items.append("range:%s:%s" % (mm.group(1), mm.group(2))); continue
            raise SystemExit("unknown attribute line: " + line)
        sets[int(m.group(1))] = " ".join(items)
    return [sets[i] for i in range(len(sets))]
argsets = parse_sets("getIntrinsicArgAttributeSet")
fnsets = parse_sets("getIntrinsicFnAttributeSet")
m = s[s.index("IntrinsicsToAttributesMap[] = {"):]
m = m[m.index("{") + 1:m.index("};")]
packed = [(int(a), int(b)) for a, b in re.findall(r"(\d+) << 9 \| (\d+),", m)]
assert len(packed) == N - 1
pt = s[s.index("ArgAttrIdTable[] = {"):]
pt = pt[pt.index("{") + 1:pt.index("};")]
pairs = [(int(a), int(b)) for a, b in re.findall(r"\{(\d+), (\d+)\}", re.sub(r"/\*.*?\*/", "", pt))]
it = s[s.index("ArgAttributesInfoTable[] = {"):]
it = it[it.index("{") + 1:it.index("};")]
info = [(int(a), int(b)) for a, b in re.findall(r"\{(\d+), (\d+)\}", it)]

def strs(xs): return "[" + ", ".join('"%s"' % x for x in xs) + "]"
# Big tables are hex strings (fixed width per entry): Goose compiles a long string literal quickly, while
# array literals with tens of thousands of elements take minutes.
def hexs(xs, w):
    xs = list(xs)
    for x in xs: assert 0 <= x < 16 ** w, (x, w)
    body = "".join("%0*x" % (w, x) for x in xs)
    return '"' + body + '"'
out = []
out.append("// Generated by tools/gen_intrinsics.py from TableGen's IntrinsicImpl.inc (LLVM 23.1.5). Do not edit.")
out.append("// Read by src/intrinsics.goose (port of llvm/lib/IR/Intrinsics.cpp). Hex tables: fixed width per entry.")
out.append("let INTR_COUNT: i64 = %d;" % N)
out.append('let INTR_NAMES_BLOB: const u8[:] = "%s\\n";' % "\\n".join(names))
out.append("let INTR_OVERLOADED: const u8[:] = %s;" % hexs(overloaded, 1))
out.append("let INTR_IIT_OFF: const u8[:] = %s;" % hexs(iit_off, 5))
out.append("let INTR_IIT: const u8[:] = %s;" % hexs(iit, 2))
out.append("let INTR_TARGET_NAMES: const u8[:][] = %s;" % strs(t[0] for t in targets))
out.append("let INTR_TARGET_OFF: i32[] = [%s];" % ", ".join(t[1] for t in targets))
out.append("let INTR_TARGET_CNT: i32[] = [%s];" % ", ".join(t[2] for t in targets))
out.append("let INTR_FN_ATTR: const u8[:] = %s;" % hexs([255] + [a for a, _ in packed], 2))
out.append("let INTR_ARG_ATTR: const u8[:] = %s;" % hexs([0] + [b for _, b in packed], 3))
out.append("let INTR_ARGINFO_START: const u8[:] = %s;" % hexs((a for a, _ in info), 4))
out.append("let INTR_ARGINFO_COUNT: const u8[:] = %s;" % hexs((b for _, b in info), 2))
out.append("let INTR_ARGPAIR_NO: const u8[:] = %s;" % hexs((a for a, _ in pairs), 2))
out.append("let INTR_ARGPAIR_SET: const u8[:] = %s;" % hexs((b for _, b in pairs), 2))
out.append("let INTR_ARGSETS: const u8[:][] = %s;" % strs(argsets))
out.append("let INTR_FNSETS: const u8[:][] = %s;" % strs(fnsets))
open(os.path.join(HERE, "../src/gen_intrinsics.goose"), "w").write("\n".join(out) + "\n")
print("wrote %d intrinsics, %d IIT bytes, %d fn sets, %d arg sets" % (N, len(iit), len(fnsets), len(argsets)))
