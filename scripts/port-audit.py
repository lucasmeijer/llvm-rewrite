#!/usr/bin/env python3
"""Estimate, per LLVM .cpp file, which share of its code an implementation has ported (input for port-progress.txt).

Method (a heuristic, meant to be spot-checked by hand):
  1. Extract the function definitions of the LLVM file (free functions, out-of-line methods and methods defined
     inside class bodies) with a small brace-matching scanner (comments/strings/preprocessor lines stripped).
     Each definition is weighted by its non-blank body lines. Lambdas and nested code count toward the enclosing
     function.
  2. A function counts as ported when its name, normalised (lower case, '_' removed), occurs as an identifier or a
     word in comments of the implementation sources: first among the "associated" files (impl source files whose
     header names this LLVM file), else anywhere in impl/<lang>/src when the name is distinctive (at least 8
     characters and defined in at most 2 LLVM files in scope). A few naming variants are tried (llvm:: prefix,
     trailing Inst/Impl/Instruction/Intrinsic dropped, visitXxx -> visit_xxx and so on).
  3. fraction = matched function lines / all function lines.
The heuristic over-counts (a name in a comment is not a full port) and under-counts (ports that renamed things), so
round the result and spot-check large files.

Usage: scripts/port-audit.py --impl goose [--file lib/Analysis/ValueTracking.cpp] [--missing] [--all]
  default: files that port-progress.py counts and port-progress.txt has no line for
  --all: every counted file;  --missing: list unmatched functions (largest first)
"""
import argparse
import importlib.util
import re
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("pp", REPO / "scripts" / "port-progress.py")
pp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pp)
LIB = pp.LLVM / "lib"

KEYWORDS = {"if", "for", "while", "switch", "return", "sizeof", "catch", "decltype", "alignof", "static_assert",
            "defined", "assert", "LLVM_DEBUG", "DEBUG_WITH_TYPE"}


def strip(text):
    """Blank out comments, string/char literals and preprocessor lines, keeping newlines."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        elif c == "R" and text.startswith('R"', i) and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_")):
            m = re.match(r'R"([^(]*)\(', text[i:])
            end = text.find(")" + m.group(1) + '"', i) if m else -1
            j = n if end < 0 else end + len(m.group(1)) + 2
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        elif c in "\"'":
            if c == "'" and i > 0 and text[i - 1].isalnum():  # digit separator 1'000
                out.append(" ")
                i += 1
                continue
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append(" " * (j + 1 - i))
            i = j + 1
        else:
            out.append(c)
            i += 1
    lines = "".join(out).split("\n")
    res, cont = [], False
    for l in lines:
        if cont or l.lstrip().startswith("#"):
            cont = l.rstrip().endswith("\\")
            res.append("")
        else:
            res.append(l)
    return "\n".join(res)


def functions(path):
    """[(qualified_name, short_name, code_lines, called_identifiers)] for the function definitions of an LLVM .cpp file."""
    src = strip(path.read_text(errors="replace"))
    line_of = []
    ln = 1
    for ch in src:
        line_of.append(ln)
        if ch == "\n":
            ln += 1
    lines = src.split("\n")
    funcs = []
    stack = []  # (kind, name) ; kind in ns, class, func, other
    head_start = 0
    i, n = 0, len(src)
    paren = 0
    func_start = None
    while i < n:
        c = src[i]
        if c == "(":
            paren += 1
        elif c == ")":
            paren -= 1
        elif c == ";" and paren == 0 and (not stack or stack[-1][0] in ("ns", "class")):
            head_start = i + 1
        elif c == "{":
            transparent = not stack or stack[-1][0] in ("ns", "class")
            if transparent and paren == 0:
                head = src[head_start:i]
                kind, name = classify(head)
                if kind == "func":
                    cls = [s[1] for s in stack if s[0] == "class"]
                    qual = "::".join(cls + [name])
                    func_start = (qual, line_of[i])
                stack.append((kind, name))
            else:
                stack.append(("other", ""))
            head_start = i + 1
        elif c == "}":
            if stack:
                kind, name = stack.pop()
                if kind == "func" and func_start:
                    qual, start = func_start
                    end = line_of[i]
                    body = sum(1 for l in lines[start - 1:end] if l.strip())
                    text = "\n".join(lines[start - 1:end])
                    ids = set(re.findall(r"Intrinsic::(\w+)", text)) | set(re.findall(r"\b([A-Za-z_]\w{5,})\s*\(", text))
                    funcs.append((qual, qual.split("::")[-1], body, ids))
                    func_start = None
            if not stack or stack[-1][0] in ("ns", "class"):
                head_start = i + 1
        i += 1
    return funcs


def classify(head):
    h = " ".join(head.split())
    if re.search(r"\bnamespace\b", h) or re.match(r'^extern\s*$', h) or h.endswith("extern"):
        return "ns", ""
    if "(" not in h or re.search(r"=\s*$", h) or re.search(r"=\s*[^(]*$", h.split("(")[0]) and "operator" not in h:
        m = re.search(r"\b(class|struct|union)\s+(?:LLVM_\w+\s+|alignas\(\w+\)\s+)*(\w+)", h)
        if m and not re.search(r"\benum\b", h) and "=" not in h.split(m.group(0))[0]:
            return "class", m.group(2)
        return "other", ""
    if re.search(r"\b(class|struct)\s+\w+[^(]*$", h.split("(")[0]) and not re.search(r"\btemplate\s*<[^>]*$", h):
        m = re.search(r"\b(class|struct)\s+(\w+)", h)
        return "class", m.group(2)
    # function: identifier (possibly qualified / operator) before the first top-level '('
    pre = h.split("(")[0]
    if re.search(r"\boperator\b", h):
        m = re.search(r"((?:\w+::)*operator\s*[^\s(]*)\s*$", pre)
        if m:
            return "func", m.group(1).replace(" ", "")
    m = re.search(r"((?:~?\w+(?:<[^<>]*>)?::)*~?\w+)\s*$", pre)
    if not m:
        return "other", ""
    name = re.sub(r"<[^<>]*>", "", m.group(1))
    short = name.split("::")[-1]
    if short in KEYWORDS or short.startswith("LLVM_") or short.isupper():
        return "other", ""
    if "=" in pre:
        return "other", ""
    return "func", name


def norm(s):
    return s.lower().replace("_", "")


def variants(short, qual):
    s = short.lstrip("~")
    out = {norm(s)}
    for suf in ("Instruction", "Inst", "Impl", "Intrinsic", "Instr", "Internal", "Helper", "Expr", "ExprImpl"):
        if s.endswith(suf) and len(s) > len(suf) + 3:
            out.add(norm(s[: -len(suf)]))
    parts = qual.split("::")
    if len(parts) >= 2:
        out.add(norm(parts[-2] + parts[-1]))
    return out


# Legacy-pass-manager wrappers and debug printing: no implementation needs them; left out of both sides.
NEUTRAL = re.compile(r"^(runOnFunction|runOnModule|runOnLoop|runOnSCC|getAnalysisUsage|create\w*Pass|"
                     r"create\w*LegacyPass|initialize\w*Pass|printPipeline|dump|print|"
                     r"operator<<|getPassName|releaseMemory|doInitialization|doFinalization)$")
MIN_IDS = 15       # ... and when the function calls enough distinct identifiers (not a table)
BIG = 100          # function lines from which the callee check applies
CALLEE_FULL = float(__import__("os").environ.get("CALLEE_FULL", "0.35"))  # callee share a complete port reaches (calibrated, see NOTES at the top)
TOK = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def impl_tokens(lang):
    src = REPO / "impl" / lang / "src"
    per_file = {}
    for f in sorted(src.rglob("*")):
        if not f.is_file() or f.suffix in (".o", ".a", ".bin"):
            continue
        try:
            t = f.read_text(errors="replace")
        except OSError:
            continue
        head = "\n".join(t.splitlines()[: pp.HEADER_LINES])
        refs = {m.group(1) for m in pp.REF.finditer(head)}
        refs |= {"base:" + m for m in re.findall(r"\b(\w+\.cpp)\b", head)}  # headers that name only the basename
        toks = set()
        for x in set(TOK.findall(t)):
            toks.add(norm(x))
            parts = [q for q in x.split("_") if q]
            # drop short private prefixes (sc_, ao_, icc_, ...) of snake_case names
            for k in (1, 2):
                if len(parts) > k and all(len(q) <= 4 for q in parts[:k]):
                    rest = "".join(parts[k:]).lower()
                    if len(rest) >= 8:
                        toks.add(rest)
        # intrinsic names written as strings ("llvm.x86.sse2.psrai.d", "sse2.psrai.d"): match Intrinsic::x86_...
        for x in re.findall(r'"(?:llvm\.)?([a-z0-9_]+(?:\.[a-z0-9_]+)+)', t):
            q = x.replace(".", "").replace("_", "")
            toks.add(q)
            toks.add("x86" + q)
        # "Class::method" in comments
        toks |= {norm(a + b) for a, b in re.findall(r"(\w+)::(\w+)", t)}
        per_file[f] = (refs, toks, sum(1 for l in t.splitlines() if l.strip() and not l.strip().startswith("//")))
    return per_file


def audit(lang, files, scope_all, want_missing):
    per_file = impl_tokens(lang)
    all_toks = set().union(*(t for _, t, _ in per_file.values()))
    # how many LLVM files define each short name
    defcount = defaultdict(int)
    fcache = {}
    for f in scope_all:
        fs = functions(LIB / f)
        fcache[f] = fs
        for s in {x[1] for x in fs}:  # noqa
            defcount[s] += 1
    rows = []
    for f in files:
        fs = fcache.get(f) or functions(LIB / f)
        base = "base:" + f.rsplit("/", 1)[-1]
        assoc = set().union(*[t for r, t, _ in per_file.values() if f in r or base in r] or [set()])
        # code lines of the impl files whose header names this file (a rough second signal)
        share = sum(nl for r, _, nl in per_file.values() if f in r or base in r)
        tot = got = 0
        missing, matched = [], []
        for qual, short, nl, ids in fs:
            if NEUTRAL.match(short):
                continue
            v = variants(short, qual)
            distinctive = len(short) >= 8 and defcount[short] <= 2
            ok = bool(v & assoc) or (distinctive and bool(v & all_toks))
            tot += nl
            if ok:
                w = 1.0
                if nl >= BIG and len(ids) >= MIN_IDS:
                    # a big function (often a switch over opcodes or intrinsics) may be ported only in part: scale
                    # by the share of the identifiers it calls that the implementation mentions, relative to
                    # the share a complete port reaches (CALLEE_FULL)
                    toks = assoc or all_toks
                    cov = sum(1 for x in ids if norm(x) in toks) / len(ids)
                    w = min(1.0, cov / CALLEE_FULL)
                got += nl * w
                matched.append((nl, qual, ("assoc" if v & assoc else "global") + (f" x{w:.2f}" if w < 1 else "")))
            else:
                missing.append((nl, qual))
        rows.append((f, pp.code_lines(LIB / f), tot, got, sorted(missing, reverse=True), share, sorted(matched, reverse=True)))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--impl", default="goose")
    ap.add_argument("--file", action="append")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--missing", action="store_true")
    ap.add_argument("--matched", action="store_true", help="list matched functions and where they matched")
    ap.add_argument("--funcs", action="store_true", help="list the extracted functions of --file")
    a = ap.parse_args()
    scopes = {k: pp.scope_files(v) for k, v in pp.SCOPES.items()}
    scope_all = {f: n for s in scopes.values() for f, n in s.items()}
    if a.funcs:
        for f in a.file:
            for q, s, nl, _ in functions(LIB / re.sub(r"^(llvm/)?lib/", "", f)):
                print(f"{nl:5d} {q}")
        return
    got = pp.ported(a.impl)
    manifest = REPO / "impl" / a.impl / "port-progress.txt"
    listed = set()
    if manifest.exists():
        for line in manifest.read_text().splitlines():
            line = line.split("#", 1)[0].split()
            if len(line) == 2:
                listed.add(re.sub(r"^(llvm/)?lib/", "", line[0]))
    if a.file:
        files = [re.sub(r"^(llvm/)?lib/", "", f) for f in a.file]
    else:
        files = [f for f in scope_all if got.get(f, 0) > 0 and (a.all or f not in listed)]
    files.sort(key=lambda f: -scope_all.get(f, 0))
    print("LLVM-lines  fraction  (matched/all function lines)  impl-lines-of-files-naming-it  file")
    for f, lines, tot, hit, missing, share, matched in audit(a.impl, files, scope_all, a.missing):
        frac = hit / tot if tot else 0.0
        print(f"{lines:6d}  {frac:5.2f}  ({hit:5.0f}/{tot:5d})  {share:6.0f}  lib/{f}")
        if a.missing:
            for nl, q in missing[:40]:
                print(f"            missing {nl:5d} {q}")
        if a.matched:
            for nl, q, where in matched[:40]:
                print(f"            matched {nl:5d} {q}  ({where})")


if __name__ == "__main__":
    sys.exit(main())
