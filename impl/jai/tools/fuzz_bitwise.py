#!/usr/bin/env python3
# Random differential fuzzer for InstCombine bitwise/shift folds: straight-line functions over
# and/or/xor/shifts/add/sub/icmp (scalar and <2 x i8> with poison lanes), LLVM vs impl/jai/bin/opt, per function.
# Usage: python3 impl/jai/tools/fuzz_bitwise.py SEED COUNT   (prints DIFF/FAIL lines)
# Random straight-line functions over and/or/xor/shifts/add/sub/icmp; ret iN or i1.
import random, sys
OPS=["and","or","xor","shl","lshr","ashr","add","sub","and","or","xor"]
PREDS=["eq","ne","ult","ugt","slt","sgt","ule","sge"]
def gen(fid, rnd):
    w=rnd.choice([8,8,8,32,16])
    vec=rnd.random()<0.3
    if vec: w=8
    t=f"<2 x i8>" if vec else f"i{w}"
    bt="<2 x i1>" if vec else "i1"
    vals=["%a","%b","%c"]
    lines=[]
    n=rnd.randint(2,7)
    def opnd():
        if rnd.random()<0.35:
            c=rnd.choice([0,1,-1,2,3,4,7,8,15,16,31,32,63,64,127,128,-128,-2,-8,-16,255,w-1,w-2,5,6,0x55,0xF0,0x0F])
            if t!="i8": pass
            else: c=((c+128)%256)-128
            if vec:
                r2=rnd.random()
                if r2<0.6: return f"splat (i8 {c})"
                d=rnd.choice([c,0,1,-1,7,'poison'])
                return f"<i8 {c}, i8 {d}>"
            return str(c)
        if len(vals)>3 and rnd.random()<0.7: return rnd.choice(vals[-2:])
        return rnd.choice(vals)
    bools=[]
    for k in range(n):
        r=rnd.random()
        name=f"%v{k}"
        if r<0.15 and len(bools)<3:
            p=rnd.choice(PREDS)
            lines.append(f"  {name} = icmp {p} {t} {opnd()}, {opnd()}")
            bools.append(name); continue
        if r<0.25 and len(bools)>=1:
            o=rnd.choice(["and","or","xor"])
            lines.append(f"  {name} = {o} {bt} {rnd.choice(bools)}, {rnd.choice(bools[-1:]+(['splat (i1 true)','zeroinitializer'] if vec else ['true','false']) if len(bools)<2 else bools[-2:])}")
            bools.append(name); continue
        o=rnd.choice(OPS)
        flags=""
        if o in("shl","add","sub") and rnd.random()<0.25: flags=rnd.choice([" nuw"," nsw"," nuw nsw"])
        if o in("lshr","ashr") and rnd.random()<0.2: flags=" exact"
        if o=="or" and rnd.random()<0.15: flags=" disjoint"
        a=opnd(); b=opnd()
        if o in ("shl","lshr","ashr") and rnd.random()<0.6: b=(f"splat (i8 {rnd.randint(0,w-1)})" if vec else str(rnd.randint(0,w-1)))
        lines.append(f"  {name} = {o}{flags} {t} {a}, {b}")
        vals.append(name)
    if bools and rnd.random()<0.4:
        ret=f"  ret {bt} {bools[-1]}"; rt=bt
    else:
        ret=f"  ret {t} {vals[-1]}"; rt=t
    return f"define {rt} @f{fid}({t} %a, {t} %b, {t} %c) {{\n"+"\n".join(lines)+"\n"+ret+"\n}\n"
def main():
    seed=int(sys.argv[1]); cnt=int(sys.argv[2])
    rnd=random.Random(seed)
    src="".join(gen(i,rnd) for i in range(cnt))
    compare(src, seed)
import os, re, subprocess
LL = "/opt/llvm-23.1.5/bin"
OURS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "opt")
def canon(txt):
    out = subprocess.run(f"{LL}/llvm-as | {LL}/llvm-dis", shell=True, input=txt, capture_output=True, text=True).stdout
    return {m.group(1): m.group(0) for m in re.finditer(r'define [^@]*@(\w+)\(.*?\n\}', out, re.S)}
def compare(src, seed):
    exp = subprocess.run([f"{LL}/opt", "-passes=instcombine", "-S", "-", "-o", "-"], input=src, capture_output=True, text=True)
    if exp.returncode: print("llvm failed"); return
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".ll", delete=False) as f: f.write(src)
    act = subprocess.run([OURS, "-passes=instcombine", "-S", f.name, "-o", "-"], capture_output=True, text=True)
    os.unlink(f.name)
    if act.returncode: print("FAIL", seed, act.stderr.strip().splitlines()[:1]); return
    e = canon(exp.stdout); a = canon(act.stdout)
    for k in e:
        if e[k] != a.get(k): print("DIFF", seed, k)
main()
