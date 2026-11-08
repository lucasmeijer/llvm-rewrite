#!/usr/bin/env python3
"""Random differential test of apint.goose against Python integers. Usage: tools/aptest.py [count] [seed]
Needs bin/aptest (tools/gb.sh src/aptest.goose bin/aptest)."""
import random, subprocess, sys, os
n = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
random.seed(int(sys.argv[2]) if len(sys.argv) > 2 else 1)
here = os.path.dirname(os.path.abspath(__file__))
def sx(x, w): return x - (1 << w) if x >> (w - 1) else x
def val(w):
    k = random.random()
    if k < 0.2: return random.choice([0, 1, (1 << w) - 1, 1 << (w - 1), (1 << (w - 1)) - 1])
    if k < 0.4: return random.getrandbits(random.randint(1, w))
    if k < 0.5: return ((1 << w) - 1) ^ random.getrandbits(random.randint(1, w))
    return random.getrandbits(w)
ops = "add sub mul udiv urem sdiv srem shl lshr ashr rotl rotr and or xor not neg ult slt clz clo ctz cto pop sext bswap brev umulov smulov dec sdec".split()
lines, exp = [], []
for _ in range(n):
    w = random.choice([1, 7, 8, 16, 32, 63, 64, 65, 80, 96, 127, 128, 129, 191, 256, 300, 512, 1024, 4097])
    op = random.choice(ops)
    m = (1 << w) - 1
    a, b = val(w), val(w)
    if op in ("shl", "lshr", "ashr", "rotl", "rotr", "sext"):
        b = random.randint(0, w - 1) if op != "sext" else random.randint(1, w)
    if op in ("udiv", "urem", "sdiv", "srem") and b == 0: b = 1
    if op == "bswap" and w % 16: w = 128; m = (1 << w) - 1; a &= m; b &= m
    sa, sb = sx(a, w), sx(b, w)
    def t(q): return int(abs(q)) * (1 if q >= 0 else -1)
    if op == "add": r = (a + b) & m
    elif op == "sub": r = (a - b) & m
    elif op == "mul": r = (a * b) & m
    elif op == "udiv": r = a // b
    elif op == "urem": r = a % b
    elif op == "sdiv":
        q = abs(sa) // abs(sb); r = (q if (sa < 0) == (sb < 0) else -q) & m
    elif op == "srem":
        q = abs(sa) % abs(sb); r = (q if sa >= 0 else -q) & m
    elif op == "shl": r = (a << b) & m
    elif op == "lshr": r = a >> b
    elif op == "ashr": r = (sa >> b) & m
    elif op == "rotl": r = ((a << b) | (a >> (w - b))) & m if b else a
    elif op == "rotr": r = ((a >> b) | (a << (w - b))) & m if b else a
    elif op == "and": r = a & b
    elif op == "or": r = a | b
    elif op == "xor": r = a ^ b
    elif op == "not": r = a ^ m
    elif op == "neg": r = (-a) & m
    elif op == "ult": r = int(a < b)
    elif op == "slt": r = int(sa < sb)
    elif op == "clz": r = w - a.bit_length()
    elif op == "clo": r = w - (a ^ m).bit_length()
    elif op == "ctz": r = (a & -a).bit_length() - 1 if a else w
    elif op == "cto": c = a ^ m; r = (c & -c).bit_length() - 1 if c else w
    elif op == "pop": r = bin(a).count("1")
    elif op == "sext": tb = a & ((1 << b) - 1); r = sx(tb, b) & m
    elif op == "bswap": r = int.from_bytes(a.to_bytes(w // 8, "little"), "big")
    elif op == "brev": r = int(format(a, "0%db" % w)[::-1], 2)
    elif op == "umulov": p = a * b; r = "%x %d" % (p & m, int(p > m))
    elif op == "smulov": p = sa * sb; r = "%x %d" % (p & m, int(p < -(1 << (w - 1)) or p >= (1 << (w - 1))))
    elif op == "dec": r = str(a)
    elif op == "sdec": r = str(sa)
    if op in ("ult", "slt", "clz", "clo", "ctz", "cto", "pop", "dec", "sdec") or isinstance(r, str): r = str(r)
    else: r = "%x" % r
    lines.append("%s %d %x %x" % (op, w, a, b)); exp.append(r)
out = subprocess.run([os.path.join(here, "..", "bin", "aptest")], input="\n".join(lines) + "\n", capture_output=True, text=True).stdout.split("\n")
bad = 0
for l, e, o in zip(lines, exp, out):
    if e != o:
        bad += 1
        if bad <= 20: print("MISMATCH", l, "expected", e, "got", o)
print("%d cases, %d mismatches" % (n, bad))
sys.exit(1 if bad else 0)
