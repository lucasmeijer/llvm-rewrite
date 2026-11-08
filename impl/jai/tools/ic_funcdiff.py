#!/usr/bin/env python3
# Usage: python3 impl/jai/tools/ic_funcdiff.py tests/imported/llvm/Transforms/InstCombine/*.ll
# For each file: split into functions with llvm-extract, run LLVM and our opt -passes=instcombine, compare outputs
# for functions that only use "ported" opcodes.
import sys, subprocess, re, os, concurrent.futures as cf
LL="/opt/llvm-23.1.5/bin"
OURS=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "opt")
PORTED=set("add sub mul udiv sdiv urem srem and or xor shl lshr ashr icmp ret br select fcmp fneg fadd fsub fmul".split())
def run(cmd, inp=None):
    r=subprocess.run(cmd, input=inp, capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout, r.stderr
def canon(txt):
    r=subprocess.run(f"{LL}/llvm-as -o - | {LL}/llvm-dis -o -", shell=True, input=txt, capture_output=True, text=True)
    return r.stdout
def body_ops(fn_text):
    ops=set()
    for line in fn_text.splitlines():
        line=line.strip()
        if not line or line.startswith(';') or line.startswith('define') or line=='}' or line.endswith(':'): continue
        m=re.match(r'(?:%[\w.\-]+ = )?(\w+)', line)
        if m: ops.add(m.group(1))
    return ops
def one(path, fn, args):
    rc, out, err = run([f"{LL}/llvm-extract", f"--func={fn}", "-S", path, "-o", "-"])
    if rc: return None
    m=re.search(r'define [^\n]*@'+re.escape(fn)+r'\([^\n]*\{.*?\n\}', out, re.S)
    if not m: return None
    ops=body_ops(m.group(0))
    if not ops <= PORTED: return None
    tmp=f"/tmp/icfd_{os.getpid()}_{abs(hash((path,fn)))}.ll"
    open(tmp,'w').write(out)
    r1=run([f"{LL}/opt"]+args+["-S",tmp,"-o","-"])
    r2=run([OURS]+args+["-S",tmp,"-o","-"])
    os.unlink(tmp)
    if r1[0]: return None
    if r2[0]: return f"FAIL {path} {fn}: {r2[2].strip().splitlines()[0] if r2[2].strip() else ''}"
    if canon(r1[1])!=canon(r2[1]): return f"DIFF {path} {fn}"
    return None
def main():
    files=sys.argv[1:]
    jobs=[]
    with cf.ThreadPoolExecutor(16) as ex:
        for f in files:
            src=open(f).read()
            fns=re.findall(r'^define [^@]*@("?[\w.\-]+"?)\(', src, re.M)
            for fn in fns: jobs.append(ex.submit(one, f, fn.strip('"'), ["-passes=instcombine"]))
        for j in jobs:
            r=j.result()
            if r: print(r, flush=True)
main()
